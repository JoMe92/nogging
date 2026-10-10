# Antigravity core runtime acceptance — 2026-10-10

Unsigned execution evidence for TASK-AGR-008 (`SPEC-ry18`),
`support-antigravity-runtime`, and GitHub issue #54. This covers core runtime
behavior only. Quota acceptance remains pending TASK-AGR-005 (`SPEC-43k1`)
and its unintegrated GSU-006 prerequisite. Issue #54 remains open; this report
does not authorize release, archive, or human acceptance.

## Environment

Linux delivery host; agy 1.3.2, Node v22.23.2, Python 3.13.5,
tmux 3.5a, Beads 1.2.2. Implementation worktree:
`/home/jome/src/nogging-spec-ry18`, branch `chore/agy-acceptance`,
allocated at integrated AGR-007 baseline `1f0a750`.
The Main Worker is Codex; real Antigravity Lead and separate code-reviewer
sessions exercise the packed consumer. These are supervised probes, not a
claim of an independently autonomous Antigravity delivery run.

Every agy process disables auto-update. Runtime credentials stay in their
original location; none are copied into a scratch HOME or recorded here.

## Findings fixed during acceptance

The shipped `Stop` entry used a grouped `hooks` wrapper. Installed agy docs
require flat Stop handlers. Two real startups acknowledged readiness but never
recorded Stop or conversation IDs, leaving send waiting for startup readiness.
The investigation fixture also wraps raw stdin with its recorder's cwd; the
runtime itself sends direct fields. The validator incorrectly consumed that
recorder wrapper.

The template and preflight now require flat handlers; event ingestion accepts
raw stdin and still validates agent, exact workspace, UUID, fullyIdle and
executionNum, refusing ID changes. The lifecycle regression exercises the
actual shell hook with raw stdin, rejects recorder envelopes and malformed
fields, and retains concurrent single-kickoff checks. Both discoveries are
recorded on SPEC-ry18. Consumers need `nogg update` before launching the repaired
runtime; existing malformed installed hooks refuse preflight.

## Commands and observed results

Packed consumer commands (run with inherited Nogging session variables removed
for test isolation, and `npm_config_cache=/tmp/ry18-npm-cache`):

```bash
npm pack --json --pack-destination /tmp/ry18-consumer
tar -xzf /tmp/ry18-consumer/nogg-2.1.0.tgz -C /tmp/ry18-consumer
git init -q /tmp/ry18-consumer/repo
cd /tmp/ry18-consumer/repo
node ../package/bin/cli.js init --no-systemd --no-beads --no-hooks
node ../package/bin/cli.js update --no-systemd --no-hooks
node ../package/bin/cli.js update --no-systemd --no-hooks
```

Repacked and updated after both repairs. A valid unrelated `consumer-owned`
Stop handler survived repeated update. Installer tests additionally cover
ordered named-hook merge, helper modes, upgrade and managed-only removal.
The live removal check follows session shutdown and verifies that unrelated
hook and consumer marker files survive while managed entries disappear.

Live launches from the implementation checkout:

```bash
./scripts/nogg session launch --agent agy --role lead --bead SPEC-ry18 \
  --cwd /tmp/ry18-consumer/repo --profile trusted
./scripts/nogg session launch --agent agy --role specialist:code-reviewer \
  --bead SPEC-ry18 --cwd /tmp/ry18-consumer/repo --profile restricted
./scripts/nogg session send <name> '<acceptance probe>'
./scripts/nogg session stop <lead-name> --reason 'Exact resume acceptance'
./scripts/nogg session launch --agent agy --role lead --bead SPEC-ry18 \
  --cwd /tmp/ry18-consumer/repo --profile trusted --resume <captured-id>
```

| Check | Observed result |
| --- | --- |
| Missing source-worktree hook | Launch refused before starting agy; packed consumer supplied installed hooks |
| Bare launch | Acknowledged readiness; no claim or implementation began |
| Trust | Only selected consumer path added; global permission setting preserved |
| Startup/Stop | Corrected Lead and specialist captured real IDs and ready timestamps; turn_end events append |
| Trusted effect | `printf AGR_TRUSTED_OK > trusted-effect.txt` ran without permission prompt; exact file content verified |
| Restricted permission | `printf AGR_RESTRICTED_OK > restricted-effect.txt` displayed `Run this command?` with guard review reason; file absent before approval and exact content present after one-time approval |
| Command floor, both levels | `curl --version` denied by PreToolUse; agent reported hook denial and did not retry |
| Execution OpenSpec boundary | Disposable-consumer `printf SHOULD_BE_DENIED > openspec/acceptance-probe.txt` denied; target absent |
| Exact resume | New Lead record retained exactly the old captured conversation ID and captured a new Stop; recalled `AGR_RESUME_ry18` after restart without tools |
| Specialist boundary | Separate restricted code-reviewer returned structured results; no claim, status, close or commit action |
| Stop | Supervised sessions transitioned to stopped; no scratch agent remains running |

The live restricted prompt used the existing verified request-review setting;
no permanent command allowance or global permission-mode change was selected.
Always-proceed refusal, malformed trust/settings, missing guard, sandbox refusal
and scoped atomic trust preservation are covered by the launch/guard tests;
this run did not switch the operator's global mode to always-proceed.

## Real Bead and validation evidence

SPEC-ry18 is the real claimed Lead Bead for this run. Implementation and
validation happen in its allocated worktree. The Main Worker retains ownership
of the acceptance repair, evidence commit, closure and task-done broker tick;
Antigravity probes and the separate specialist neither claim nor close it.
Its native notes hold the final commit SHA and validation evidence. The mapped
TASK-AGR-008 tick is produced only by task-done after closure, never by hand.

`scripts/test` passed once with inherited session variables removed before the
repairs. The repaired suite also passed under the same isolation, with
`bash scripts/antigravity-lifecycle.test.sh` checking the final raw-payload
regression and `git diff --check` before commit. The first suite attempt retained
real session variables and failed fixture boundary checks; it is not counted as
passing evidence. Live launches retain their real session boundary.

## Limits and sign-off

No filesystem/network isolation or sandbox compatibility is claimed. Multi-edit
contracts remain unsupported. No quota was exhausted and no admission/reset
mapping or quota adapter is accepted here. AGR-005 and full issue #54 completion
remain pending. Headless SUCCESS/exit zero is never the sole execution oracle;
this run checks files, permission UI, hook denials and recorded lifecycle events.
Human acceptance remains unsigned.

Signed-off-by:
