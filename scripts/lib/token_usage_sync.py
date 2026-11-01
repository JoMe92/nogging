"""Explicit multi-device usage sync over an independently configured Dolt remote.

Never run by init/collect/report and independent of Beads multi_machine.
Serialized against collection (collector pass lock) and store writes (store
lock). Fetch, validate the remote schema/project before merging, merge, and
push; a rejected push retries at most `attempts` times; conflicts and
constraint violations abort the merge with local history intact. Never force
pushes and never resolves with ours/theirs. Remote URLs are reported without
credentials; Dolt diagnostics are classified, never echoed.
"""
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import urllib.parse

from token_usage_store import IDENTITY_VERSION, SCHEMA_VERSION, StoreError

AUTHOR = 'Nogging Usage <usage@nogging.bot>'


class SyncRefused(RuntimeError):
    pass


def redact_url(url):
    try:
        parts = urllib.parse.urlsplit(url)
        netloc = parts.hostname or ''
        if parts.port:
            netloc += f':{parts.port}'
    except ValueError:
        return '<unparseable remote>'
    return urllib.parse.urlunsplit((parts.scheme, netloc, parts.path, '', ''))


class Sync:
    NETWORK_TIMEOUT = 60   # seconds per fetch/push; both locks are held meanwhile

    def __init__(self, store, collector, remote='origin', attempts=3, run=None):
        self.store, self.collector = store, collector
        self.remote, self.attempts = remote, attempts
        self._run = run or self._default_run
        self.status_path = Path(store.root) / 'sync-status.json'

    def _default_run(self, *args):
        try:
            network = args and args[0] in ('fetch', 'push')
            result = subprocess.run(['dolt', *args], cwd=self.store.database, text=True,
                                    capture_output=True, timeout=self.NETWORK_TIMEOUT if network else 120)
        except (OSError, subprocess.TimeoutExpired):
            return 127, '', 'dolt could not run'
        return result.returncode, result.stdout, result.stderr

    def dolt(self, *args):
        return self._run(*args)

    def rows(self, sql):
        code, out, _ = self.dolt('sql', '-r', 'json', '-q', sql)
        if code:
            return None
        try:
            return json.loads(out or '{}').get('rows', [])
        except ValueError:
            return None

    def previous(self):
        try:
            value = json.loads(self.status_path.read_text())
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def record(self, state, now, **extra):
        status = self.previous()
        status.update(state=state, last_attempt_at=now, **extra)
        if state == 'synchronized':
            status['last_success_at'] = now
            status['last_error'] = None
        status['local_only'] = not status.get('last_success_at')
        temp = self.status_path.with_name(f'.sync-status.{os.getpid()}.tmp')
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(status, output, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, self.status_path)
        return status

    def remote_url(self):
        code, out, _ = self.dolt('remote', '-v')
        if code:
            return None
        for line in out.splitlines():
            fields = line.split()
            if len(fields) >= 2 and fields[0] == self.remote:
                return fields[1]
        return None

    def ensure_identity(self):
        """Merges need a committer; keep it local to the usage database."""
        for key, value in (('user.name', 'Nogging Usage'), ('user.email', 'usage@nogging.bot')):
            code, out, _ = self.dolt('config', '--local', '--get', key)
            if code or not out.strip():
                if self.dolt('config', '--local', '--add', key, value)[0]:
                    raise StoreError('could not set the usage database committer identity')

    def conflicts(self):
        details = []
        for table, column in (('dolt_conflicts', 'num_conflicts'), ('dolt_constraint_violations', 'num_violations')):
            for row in self.rows(f'SELECT * FROM {table}') or []:
                kind = 'conflict' if table == 'dolt_conflicts' else 'constraint_violation'
                details.append({'kind': kind, 'table': row.get('table'), 'count': row.get(column)})
        return details

    def abort_merge(self):
        """Abort and verify; True only when no merge remains in progress."""
        self.dolt('merge', '--abort')
        state = self.rows('SELECT is_merging FROM dolt_merge_status')
        return bool(state) and str(state[0].get('is_merging')).lower() in ('false', '0')

    def run(self, now=None, drain_budget=20.0, lock_timeout=30.0):
        now = (now or dt.datetime.now(dt.timezone.utc)).isoformat(timespec='seconds').replace('+00:00', 'Z')
        try:
            return self._run_locked(now, drain_budget, lock_timeout)
        except StoreError as exc:
            # Local store problems (e.g. unsupported local schema) stay visible.
            self.record('refused', now, last_error=f'local usage store: {exc}')
            raise

    def _run_locked(self, now, drain_budget, lock_timeout):
        if not (self.store.database / '.dolt').exists():
            raise SyncRefused('no local usage store yet: collect first, or clone the usage remote with '
                              '`dolt clone <url> .nogging/state/token-usage/database` on a new device')
        with self.collector.locked(lock_timeout):
            # Commit pending local facts first so sync never strands them.
            _, drain_error = self.collector.drain(drain_budget)
            if drain_error:
                return self.record('pending', now, last_error=drain_error)
            with self.store.locked():
                meta = self.store.check_schema()
                url = self.remote_url()
                if url is None:
                    return self.record('not_configured', now, remote=None, last_error=(
                        f'no usage remote named {self.remote!r}; configure one with `dolt remote add '
                        f'{self.remote} <url>` in the usage database (credentials via Dolt, never argv)'))
                shown = redact_url(url)
                self.ensure_identity()
                if self.rows('SELECT * FROM dolt_status'):
                    self.dolt('add', '.')
                    self.dolt('commit', '--author', AUTHOR, '-m', 'Commit pending usage facts')
                branch = (self.rows('SELECT active_branch() AS b') or [{}])[0].get('b') or 'main'
                tracking = f'{self.remote}/{branch}'
                for attempt in range(1, self.attempts + 1):
                    if self.dolt('fetch', self.remote)[0]:
                        return self.record('pending', now, remote=shown, attempts=attempt,
                                           last_error='usage remote unreachable; local facts retained, retry later')
                    code, branches, _ = self.dolt('branch', '-r')
                    remote_exists = not code and f'remotes/{tracking}' in branches.split()
                    remote_meta = self.rows(f"SELECT * FROM store_meta AS OF '{tracking}'") if remote_exists else None
                    if remote_exists and not remote_meta:
                        return self.record('refused', now, remote=shown, attempts=attempt, last_error=(
                            f'remote branch {tracking} has no readable usage store metadata; refusing before merge '
                            '(is this remote a Nogging usage store?)'))
                    if remote_meta:
                        theirs = remote_meta[0]
                        if (theirs.get('schema_version'), theirs.get('identity_version')) != (SCHEMA_VERSION, IDENTITY_VERSION):
                            return self.record('refused', now, remote=shown, attempts=attempt, last_error=(
                                f"remote usage schema {theirs.get('schema_version')}/{theirs.get('identity_version')} "
                                f"is not the supported {SCHEMA_VERSION}/{IDENTITY_VERSION}; refusing before merge "
                                "(update Nogging on this device; local facts are intact)"))
                        if theirs.get('project_id') != meta['project_id']:
                            return self.record('refused', now, remote=shown, attempts=attempt, last_error=(
                                'remote belongs to a different usage project; refusing to merge identities '
                                '(export local facts, clone the remote, then import them)'))
                        code, _, _ = self.dolt('merge', '--author', AUTHOR, '-m',
                                               f'Merge usage facts from {tracking}', tracking)
                        if code:
                            details = self.conflicts()
                            if not self.abort_merge():
                                return self.record('conflict', now, remote=shown, attempts=attempt,
                                                   conflicts=details, last_error=(
                                    'merge could not be aborted automatically; local facts are intact in history. '
                                    'Run `dolt merge --abort` in .nogging/state/token-usage/database before collecting'))
                            if details:
                                return self.record('conflict', now, remote=shown, attempts=attempt,
                                                   conflicts=details, last_error=(
                                    'remote facts conflict with local facts (same identity, different content, '
                                    'competing ownership or ordinal); merge aborted, both histories retained; '
                                    'export both sides and review with the owner'))
                            return self.record('pending', now, remote=shown, attempts=attempt,
                                               last_error='merge failed without conflicts; local facts retained')
                        merged = self.store.check_schema()
                        if merged['project_id'] != meta['project_id']:
                            raise StoreError('merged usage project identity changed; restore from the prior commit')
                    code, _, err = self.dolt('push', self.remote, branch)
                    if not code:
                        return self.record('synchronized', now, remote=shown, attempts=attempt, conflicts=[])
                    if 'non-fast-forward' not in err and 'rejected' not in err:
                        return self.record('pending', now, remote=shown, attempts=attempt,
                                           last_error='push failed (remote unreachable or refused); local facts retained')
                return self.record('pending', now, remote=shown, attempts=self.attempts,
                                   last_error=f'remote kept moving: push rejected {self.attempts} times; retry later')
