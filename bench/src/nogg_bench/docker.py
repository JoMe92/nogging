"""The ``docker`` command line, as the run uses it (design Decision 7).

Every call is an argv list (never a shell string on the host), goes through
the run log, and is refused before it starts when it would carry a credential
value. Tests replace ``docker`` with a stub on ``PATH`` that records argv.
"""

from __future__ import annotations

import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path

from nogg_bench.credentials import Redactor


# Design Decision 20: every arm's container gets exactly these, so arms differ only in
# their agent. They are what `unshare --user --mount` (Nogging's scripts/openspec-sandbox)
# needs: Docker's default seccomp profile refuses unshare, mount and clone-with-namespaces
# to a process without CAP_SYS_ADMIN, and its default AppArmor profile denies mount. No
# capability is added, no device, no host namespace, and never --privileged: a new
# option goes in only when a smoke run proves it necessary.
# systempaths=unconfined lifts Docker's masked /proc paths: the sandbox's full call ends
# in `--pid --fork --mount-proc`, and a real run (python:3.13-slim, user nobody,
# 2026-11-21) fails with "mount /proc failed: Operation not permitted" without it.
SECURITY_OPTIONS = ("seccomp=unconfined", "apparmor=unconfined", "systempaths=unconfined")


def container_options() -> list[str]:
    """The ``docker run`` options of every arm; recorded in the result line's provenance."""
    return [word for option in SECURITY_OPTIONS for word in ("--security-opt", option)]


class DockerError(Exception):
    """A docker call failed; the message is safe to record."""


@dataclass(frozen=True)
class Done:
    returncode: int | None  # None: the host-side timeout expired
    stdout: str
    stderr: str


class RunLog:
    """Append-only run log; every line is redacted before it is written."""

    def __init__(self, path: Path, redactor: Redactor) -> None:
        self.path = path
        self.redactor = redactor

    def write(self, text: str) -> None:
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(self.redactor.redact(text.rstrip("\n")) + "\n")


class Docker:
    def __init__(self, log: RunLog, binary: str = "docker") -> None:
        self.log = log
        self.binary = binary

    def call(self, args: list[str], *, timeout: float | None = None) -> Done:
        argv = [self.binary, *args]
        if self.log.redactor.contains("\0".join(argv)):
            raise DockerError("refused a docker call that would carry a credential value on its command line")
        if any(a == "--privileged" or a.startswith("--cap-add") for a in args):
            raise DockerError("refused a docker call that would start a privileged container")
        self.log.write("$ " + shlex.join(argv))
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        except FileNotFoundError as exc:
            raise DockerError(f"{self.binary} not found") from exc
        except subprocess.TimeoutExpired as exc:
            self.log.write(f"  timed out after {timeout:.0f}s")
            return Done(None, _text(exc.stdout), _text(exc.stderr))
        self.log.write(f"  exit {done.returncode}")
        if done.returncode and done.stderr.strip():
            self.log.write("  " + done.stderr.strip().splitlines()[-1])
        return Done(done.returncode, done.stdout, done.stderr)

    def checked(self, args: list[str], what: str, *, timeout: float | None = None) -> Done:
        done = self.call(args, timeout=timeout)
        if done.returncode != 0:
            last = (done.stderr.strip().splitlines() or ["timed out" if done.returncode is None else ""])[-1]
            raise DockerError(f"{what} failed: {self.log.redactor.redact(last)}".rstrip(": "))
        return done

    def image_digest(self, image: str) -> str:
        """The local image ID of ``image``, pulling it first when it is not present."""
        inspect = ["image", "inspect", "--format", "{{.Id}}", image]
        done = self.call(inspect)
        if done.returncode != 0:
            self.checked(["pull", "--quiet", image], f"pulling image {image}", timeout=1800)
            done = self.checked(inspect, f"inspecting image {image}")
        return done.stdout.strip()

    def start(self, name: str, image: str) -> None:
        """A fresh container that idles until the run removes it. Nothing is mounted, and
        the options are the same for every arm (:func:`container_options`)."""
        self.checked(
            ["run", "--detach", "--init", *container_options(), "--name", name, "--workdir", "/work",
             "--entrypoint", "sleep", image, "infinity"],
            "starting the container",
            timeout=300,
        )

    def exec(
        self, name: str, script: str, *, workdir: str = "/work/repo", env_file: Path | None = None,
        timeout: float | None = None, user: str | None = None,
    ) -> Done:
        args = ["exec", "--workdir", workdir]
        if user is not None:
            args += ["--user", user]
        if env_file is not None:
            args += ["--env-file", str(env_file)]
        return self.call([*args, name, "sh", "-c", script], timeout=timeout)

    def copy_in(self, name: str, source: Path | str, dest: str) -> None:
        self.checked(["cp", str(source), f"{name}:{dest}"], f"copying {dest} into the container", timeout=600)

    def copy_out(self, name: str, source: str, dest: Path) -> bool:
        """Copy ``source`` out of the container; False when it does not exist there."""
        return self.call(["cp", f"{name}:{source}", str(dest)], timeout=600).returncode == 0

    def restart(self, name: str) -> None:
        """Kill every process in the container at once and keep its file system."""
        self.checked(["restart", "--time", "0", name], "stopping the agent's processes", timeout=300)

    def remove(self, name: str) -> None:
        self.call(["rm", "--force", "--volumes", name], timeout=120)


def _text(value: bytes | str | None) -> str:
    if value is None:
        return ""
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else value
