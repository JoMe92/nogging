"""Loading arm files and checking that arms are comparable (design Decision 6).

An arm is loaded through the BEN-001 schema; a problem raises
:class:`~nogg_bench.records.RecordError` naming the file and field. Arms of one
batch must share the timebox, and arms of the same vendor must share model and
effort; :func:`comparability_problems` names the field that differs.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from nogg_bench.records import RecordError, load_yaml
from nogg_bench.schema import Problem, check_arm

# Which vendor's model an agent CLI runs. A nogging arm runs the vendor of the
# agent CLI that Nogging launches.
CLI_VENDORS = {"claude": "anthropic", "codex": "openai"}
KIND_VENDORS = {"claude-code": "anthropic", "codex": "openai"}


@dataclass(frozen=True)
class Arm:
    """One validated arm file with its prompt and provenance hashes."""

    data: dict
    path: Path
    prompt_text: str
    arm_file_hash: str
    prompt_hash: str

    @property
    def id(self) -> str:
        return self.data["id"]

    @property
    def kind(self) -> str:
        return self.data["kind"]

    @property
    def cli(self) -> str:
        return self.data["agent"]["cli"]

    @property
    def model(self) -> str:
        return self.data["model"]

    @property
    def effort(self) -> str:
        return self.data["effort"]

    @property
    def timebox_seconds(self) -> int:
        return int(self.data["timebox_minutes"]) * 60

    @property
    def vendor(self) -> str:
        if self.kind in KIND_VENDORS:
            return KIND_VENDORS[self.kind]
        return CLI_VENDORS.get(self.cli, self.cli)

    @property
    def credentials(self) -> dict:
        return self.data["credentials"]

    def render_prompt(self, issue_text: str) -> str:
        """The agent's only brief: the prompt template with the issue text filled in."""
        return self.prompt_text.replace("{issue}", issue_text.strip())


def sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def load_arm(path: Path) -> Arm:
    """Load and validate one arm file; raise RecordError naming the first problem."""
    data = load_yaml(path)
    problems = check_arm(data)
    if not problems and data["id"] != path.stem:
        problems = [Problem("", "id", f"must equal the file name {path.stem!r} (got {data['id']!r})")]
    if problems:
        raise RecordError(problems[0].at(str(path)))
    prompt_path = path.parent / data["prompt"]
    try:
        prompt_bytes = prompt_path.read_bytes()
    except OSError as exc:
        raise RecordError(Problem(str(path), "prompt", f"cannot read {data['prompt']}: {exc.strerror}")) from exc
    prompt_text = prompt_bytes.decode("utf-8")
    if "{issue}" not in prompt_text:
        raise RecordError(Problem(str(path), "prompt", f"{data['prompt']} has no {{issue}} placeholder"))
    return Arm(data, path, prompt_text, sha256(path.read_bytes()), sha256(prompt_bytes))


def find_arm(bench: Path, arm_id: str) -> Arm:
    return load_arm(bench / "arms" / f"{arm_id}.yaml")


def comparability_problems(arms: Iterable[Arm]) -> list[str]:
    """Why these arms cannot be compared, one message per differing field.

    Every arm must have the same timebox. Arms of the same vendor (every
    Claude-based arm, for instance) must also name the same model and effort.
    """
    arms = list(arms)
    out: list[str] = []
    for i, first in enumerate(arms):
        for second in arms[i + 1 :]:
            pair = f"arms {first.id} and {second.id}"
            if first.data["timebox_minutes"] != second.data["timebox_minutes"]:
                out.append(
                    f"{pair}: timebox_minutes differs ({first.data['timebox_minutes']} != "
                    f"{second.data['timebox_minutes']})"
                )
            if first.vendor == second.vendor:
                for field in ("model", "effort"):
                    if first.data[field] != second.data[field]:
                        out.append(
                            f"{pair}: {field} differs within vendor {first.vendor} "
                            f"({first.data[field]!r} != {second.data[field]!r})"
                        )
    return out
