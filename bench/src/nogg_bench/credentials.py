"""Credentials by reference, staged for one run and redacted everywhere (design Decision 8).

An arm names its credentials as an environment variable *name* (an API key)
or a credential *directory* (a subscription login). :class:`Credentials`
stages the value in a private temporary directory outside the results tree:
an env file of mode ``0600`` for ``docker exec --env-file``, or a ``0600``
copy of the directory for ``docker cp``. The directory is removed when the
context ends. No value is ever placed on a command line.

:class:`Redactor` knows the staged values and replaces them in every log line,
in the copied transcripts and in anything else the run writes.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
from pathlib import Path
from typing import Iterable, Mapping

REDACTED = "[REDACTED]"
MIN_SECRET_LENGTH = 8  # shorter strings in a credential file are not treated as secrets


class CredentialError(Exception):
    """A credential reference cannot be resolved. The message names the reference, never a value."""


class Redactor:
    def __init__(self, secrets: Iterable[str] = ()) -> None:
        self.secrets = sorted({s for s in secrets if len(s) >= MIN_SECRET_LENGTH}, key=len, reverse=True)

    def redact(self, text: str) -> str:
        for secret in self.secrets:
            text = text.replace(secret, REDACTED)
        return text

    def redact_bytes(self, data: bytes) -> bytes:
        for secret in self.secrets:
            data = data.replace(secret.encode("utf-8"), REDACTED.encode())
        return data

    def import_tree(self, source: Path, dest: Path) -> None:
        """Copy ``source`` (a file or directory) to ``dest`` redacted, dropping symlinks.

        Files copied out of the container land in a scratch directory first, so an
        unredacted byte never reaches the results tree.
        """
        if source.is_symlink() or not source.exists():
            return
        if source.is_file():
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(self.redact_bytes(source.read_bytes()))
            return
        for top, dirs, files in os.walk(source, followlinks=False):  # symlinked dirs are not entered
            dirs.sort()
            for name in sorted(files):
                path = Path(top) / name
                if path.is_symlink() or not path.is_file():
                    continue
                target = dest / path.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(self.redact_bytes(path.read_bytes()))

    def contains(self, text: str) -> bool:
        return any(secret in text for secret in self.secrets)



_SECRET_KEY = re.compile(r"token|key|secret|password|credential|auth", re.I)


def _secret_strings(text: str) -> list[str]:
    """The secrets of a credential file: its whole content and, for JSON, the string
    values under keys that name a token, key, secret, password or credential."""
    found = [text.strip()]
    try:
        data = json.loads(text)
    except ValueError:
        return found
    stack: list = [(None, data)]
    while stack:
        key, item = stack.pop()
        if isinstance(item, dict):
            stack.extend(item.items())
        elif isinstance(item, list):
            stack.extend((key, v) for v in item)
        elif isinstance(item, str) and isinstance(key, str) and _SECRET_KEY.search(key):
            found.append(item)
    return found


def _private_file(path: Path, content: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(content)


class Credentials:
    """Stage one arm's credentials for the length of a ``with`` block."""

    def __init__(self, ref: Mapping[str, str], environ: Mapping[str, str],
                 allowed_files: Iterable[str] = ()) -> None:
        self.ref = dict(ref)
        self.environ = environ
        self.allowed_files = tuple(allowed_files)
        self.root: Path | None = None
        self.env_file: Path | None = None
        self.staged_dir: Path | None = None
        self.files: list[str] = []  # names copied into the agent's configuration directory
        self.secrets: list[str] = []

    def __enter__(self) -> "Credentials":
        self.root = Path(tempfile.mkdtemp(prefix="nogg-bench-cred-"))
        os.chmod(self.root, 0o700)
        try:
            if "env" in self.ref:
                self._stage_env(self.ref["env"])
            else:
                self._stage_dir(Path(self.ref["dir"]).expanduser())
        except BaseException:
            self.close()
            raise
        return self

    def _stage_env(self, name: str) -> None:
        value = self.environ.get(name)
        if not value:
            raise CredentialError(f"credential variable {name} is not set")
        if "\n" in value or "\r" in value:
            raise CredentialError(f"credential variable {name} holds a line break; an env file cannot carry it")
        self.env_file = self.root / "agent.env"
        _private_file(self.env_file, f"{name}={value}\n".encode())
        self.secrets.append(value)

    def _stage_dir(self, source: Path) -> None:
        """Copy only the agent CLI's credential files; the rest of the directory (its
        transcripts and history, say) never enters the container."""
        if not source.is_dir():
            raise CredentialError(f"credential directory {source} does not exist")
        self.staged_dir = self.root / "dir"
        self.staged_dir.mkdir(mode=0o700)
        for name in self.allowed_files:
            path = source / name
            if path.is_symlink() or not path.is_file():
                continue
            content = path.read_bytes()
            _private_file(self.staged_dir / name, content)
            self.files.append(name)
            try:
                self.secrets.extend(_secret_strings(content.decode("utf-8")))
            except UnicodeDecodeError:
                pass
        if not self.files:
            wanted = ", ".join(self.allowed_files) or "(none for this agent)"
            raise CredentialError(f"credential directory {source} holds none of {wanted}")

    def redactor(self) -> Redactor:
        return Redactor(self.secrets)

    def close(self) -> None:
        if self.root is not None:
            shutil.rmtree(self.root, ignore_errors=True)
            self.root = None

    def __exit__(self, *exc) -> None:
        self.close()
