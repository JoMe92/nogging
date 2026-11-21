"""``nogg-bench report``: the paired report over result lines (design Decision 13).

Reads the result lines of the named batches, the review records, ``prices.yaml``
and the preregistered thresholds block, and writes ``report.md``, ``runs.csv``
and ``metadata.json`` into the output directory. Nothing is written when the
inputs are refused.

What a table counts. A run is *counted* when it is not a smoke run, did not
end in ``infra_error`` and is not flagged ``contamination_suspect``. Smoke and
infrastructure-failed runs are no evidence about the arms, and a contamination
suspect may have looked the answer up, so the last two are listed apart and
the first is only counted in the CSV. Every run, counted or not, is in
``runs.csv``. Tickets are paired when both arms of a comparison have at least
one counted run on them. An arm's value on a ticket is the majority pass
(strictly more than half of its runs; an even split fails) and the median cost
over its runs; a ticket whose cost is unknown for any run of either arm stays
out of the cost tests and the cost per accepted ticket is then unknown.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from nogg_bench import stats
from nogg_bench.prices import Price, load_prices, run_cost
from nogg_bench.records import RecordError, load_thresholds, load_yaml, read_jsonl
from nogg_bench.schema import ACCEPTED_TICKET_DEFINITIONS, SIZE_CLASSES, Problem, check_arm, check_result, check_review
from nogg_bench.validate import find_bench_dir

SCOPES = ("all", *SIZE_CLASSES)
DEVIATION_NOTE = (
    "Nogging arms plan and execute without human approval: the issue text is the planning brief and "
    "no human approves the plan or the change. Real use has a human at those points, so these "
    "results show what Nogging does unattended, not what a supervised team gets."
)
_REF = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._/-]*$")


class ReportRefused(Exception):
    """The inputs cannot be reported; ``problems`` are printed one per line."""

    def __init__(self, problems: list[str]) -> None:
        super().__init__("; ".join(problems))
        self.problems = problems


# ------------------------------------------------------------------ inputs


@dataclass
class Run:
    record: dict
    cost: float | None
    missing_prices: list[str]
    review: dict | None
    exclusion: str  # "" when counted, else smoke / infra_error / contamination_suspect

    @property
    def arm(self) -> str:
        return self.record["arm"]

    @property
    def task(self) -> str:
        return self.record["task"]

    @property
    def counted(self) -> bool:
        return not self.exclusion

    @property
    def passed(self) -> bool:
        return bool(self.record["passed"])

    def accepted(self, definition: str) -> bool:
        if not self.passed:
            return False
        if definition == "tests_pass":
            return True
        return bool(self.review) and self.review["merge_decision"] == "merge"


@dataclass
class Inputs:
    bench: Path
    batches: list[str]
    runs: list[Run]
    thresholds: dict
    arms: dict[str, dict]
    arm_files: dict[str, Path]
    prices: dict[str, Price]
    prereg_path: Path
    recorded_hashes: list[str] = field(default_factory=list)


def sha256_of(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def blob_hash(path: Path) -> str:
    """The git blob hash of a file, computed without git."""
    data = path.read_bytes()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def _git(cwd: Path, *args: str) -> str | None:
    try:
        done = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def _load_arm(bench: Path, arm_id: str, problems: list[str]) -> tuple[dict | None, Path]:
    path = bench / "arms" / f"{arm_id}.yaml"
    if not path.is_file():
        problems.append(f"{path}: (file): arm {arm_id} has no arm file")
        return None, path
    try:
        data = load_yaml(path)
    except RecordError as exc:
        problems.append(str(exc.problem))
        return None, path
    bad = check_arm(data)
    if bad:
        problems.extend(str(p.at(str(path))) for p in bad)
        return None, path
    if data["id"] != arm_id:
        problems.append(f"{path}: id: is {data['id']}, expected {arm_id}")
        return None, path
    return data, path


def check_pairable(a: dict, b: dict) -> list[str]:
    """Why two arms may not be paired: a different timebox, or a different model or effort in one vendor."""
    out = []
    if a["timebox_minutes"] != b["timebox_minutes"]:
        out.append(
            f"cannot pair arms {a['id']} and {b['id']}: timebox_minutes differs "
            f"({a['id']}: {a['timebox_minutes']}, {b['id']}: {b['timebox_minutes']})"
        )
    if a["agent"]["cli"] == b["agent"]["cli"]:
        for key in ("model", "effort"):
            if a[key] != b[key]:
                out.append(
                    f"cannot pair arms {a['id']} and {b['id']}: both run the {a['agent']['cli']} agent but "
                    f"{key} differs ({a['id']}: {a[key]}, {b['id']}: {b[key]})"
                )
    return out


def load_inputs(bench: Path, batches: list[str], *, allow_mixed_preregistration: bool = False) -> Inputs:
    problems: list[str] = []
    prereg = bench / "PREREGISTRATION.md"
    thresholds: dict = {}
    try:
        thresholds = load_thresholds(prereg)
    except RecordError as exc:
        problems.append(str(exc.problem))
    prices: dict[str, Price] = {}
    try:
        prices = load_prices(bench / "prices.yaml")
    except RecordError as exc:
        problems.append(str(exc.problem))

    records: list[dict] = []
    for batch in batches:
        path = bench / "results" / f"{batch}.jsonl"
        if not path.is_file():
            problems.append(f"{path}: (file): batch {batch} has no result file")
            continue
        try:
            for number, rec in read_jsonl(path):
                bad = check_result(rec)
                problems.extend(str(p.at(f"{path}:{number}")) for p in bad)
                if not bad:
                    records.append(rec)
        except RecordError as exc:
            problems.append(str(exc.problem))
    seen: set[str] = set()
    for rec in records:
        if rec["run_id"] in seen:
            problems.append(f"run_id {rec['run_id']} appears twice in the given batches")
        seen.add(rec["run_id"])

    reviews: dict[str, dict] = {}
    for path in sorted((bench / "results" / "review").glob("*.jsonl")):
        try:
            for number, rec in read_jsonl(path):
                bad = check_review(rec)
                problems.extend(str(p.at(f"{path}:{number}")) for p in bad)
                if not bad and (rec["run_id"] not in reviews or rec["reviewed_at"] >= reviews[rec["run_id"]]["reviewed_at"]):
                    reviews[rec["run_id"]] = rec  # the latest review of a run wins
        except RecordError as exc:
            problems.append(str(exc.problem))

    hashes = sorted({r["provenance"]["preregistration_hash"] for r in records if not r["provenance"]["smoke"]})
    if len(hashes) > 1 and not allow_mixed_preregistration:
        problems.append(
            "the batches carry different preregistration hashes: " + " and ".join(hashes)
            + " (pass --allow-mixed-preregistration to report them together anyway)"
        )

    arms: dict[str, dict] = {}
    arm_files: dict[str, Path] = {}
    wanted = {a for c in thresholds.get("primary_comparisons", []) for a in (c["treatment"], c["control"])}
    for arm_id in sorted(wanted):
        data, path = _load_arm(bench, arm_id, problems)
        arm_files[arm_id] = path
        if data:
            arms[arm_id] = data
    for comp in thresholds.get("primary_comparisons", []):
        t, c = comp["treatment"], comp["control"]
        if t in arms and c in arms:
            problems.extend(check_pairable(arms[t], arms[c]))
    for arm_id in sorted({r["arm"] for r in records} - wanted):  # arms outside the comparisons: metadata only
        data, path = _load_arm(bench, arm_id, [])
        if data:
            arms[arm_id], arm_files[arm_id] = data, path

    if problems:
        raise ReportRefused(problems)

    runs = []
    for rec in records:
        cost, missing = run_cost(rec["usage"], prices)
        if rec["provenance"]["smoke"]:
            why = "smoke"
        elif rec["status"] == "infra_error":
            why = "infra_error"
        elif rec["contamination_suspect"]:
            why = "contamination_suspect"
        else:
            why = ""
        runs.append(Run(rec, cost, missing, reviews.get(rec["run_id"]), why))
    return Inputs(bench, batches, runs, thresholds, arms, arm_files, prices, prereg, hashes)


# ---------------------------------------------------------------- analysis


@dataclass
class Ticket:
    task: str
    size_class: str
    t_runs: list[Run]
    c_runs: list[Run]


def _ticket_cost(runs: list[Run]) -> float | None:
    costs = [r.cost for r in runs]
    return None if any(c is None for c in costs) else stats.median_of([c for c in costs if c is not None])


def _ticket_accepted(runs: list[Run], definition: str) -> bool:
    return 2 * sum(1 for r in runs if r.accepted(definition)) > len(runs)


@dataclass
class Comparison:
    treatment: str
    control: str
    scope: str
    tickets: list[Ticket]
    both: int = 0
    only_t: int = 0
    only_c: int = 0
    neither: int = 0
    pass_t: int = 0
    pass_c: int = 0
    mcnemar_p: float = 1.0
    cost_t_cheaper: int = 0
    cost_c_cheaper: int = 0
    cost_ties: int = 0
    cost_p: float = 1.0
    cost_tickets_unknown: int = 0
    unknown_models: list[str] = field(default_factory=list)
    # definition -> (accepted tickets treatment, control, total cost treatment, control or None)
    accepted: dict[str, tuple[int, int, float | None, float | None]] = field(default_factory=dict)

    @property
    def n(self) -> int:
        return len(self.tickets)

    def rate(self, passes: int) -> float | None:
        return 100.0 * passes / self.n if self.n else None

    @property
    def diff_points(self) -> float | None:
        return None if not self.n else self.rate(self.pass_t) - self.rate(self.pass_c)  # type: ignore[operator]

    def cost_per_accepted(self, definition: str) -> tuple[float | None, float | None]:
        acc_t, acc_c, cost_t, cost_c = self.accepted[definition]
        return (cost_t / acc_t if cost_t is not None and acc_t else None,
                cost_c / acc_c if cost_c is not None and acc_c else None)

    def cost_ratio(self, definition: str) -> tuple[float | None, str]:
        """Treatment over control cost per accepted ticket, or ``None`` and why."""
        t, c = self.cost_per_accepted(definition)
        if self.unknown_models:
            return None, "unknown cost: no price for " + ", ".join(self.unknown_models)
        if not self.n:
            return None, "no paired tickets"
        if t is None or c is None:
            return None, "an arm has no accepted ticket"
        if c == 0:
            return None, "control cost is zero"
        return t / c, ""


def compare(runs: list[Run], treatment: str, control: str, scope: str) -> Comparison:
    by: dict[tuple[str, str], list[Run]] = {}
    for run in runs:
        if run.counted and run.arm in (treatment, control):
            by.setdefault((run.task, run.arm), []).append(run)
    tickets = []
    for task in sorted({t for t, _ in by}):
        t_runs, c_runs = by.get((task, treatment)), by.get((task, control))
        if not t_runs or not c_runs:
            continue
        size = t_runs[0].record["size_class"]
        if scope == "all" or size == scope:
            tickets.append(Ticket(task, size, t_runs, c_runs))
    cmp = Comparison(treatment, control, scope, tickets)
    t_costs, c_costs, models = [], [], set()
    for tk in tickets:
        pt, pc = stats.majority_pass([r.passed for r in tk.t_runs]), stats.majority_pass([r.passed for r in tk.c_runs])
        cmp.pass_t += pt
        cmp.pass_c += pc
        cmp.both += pt and pc
        cmp.only_t += pt and not pc
        cmp.only_c += pc and not pt
        cmp.neither += not pt and not pc
        ct, cc = _ticket_cost(tk.t_runs), _ticket_cost(tk.c_runs)
        if ct is None or cc is None:
            cmp.cost_tickets_unknown += 1
            models.update(m for r in tk.t_runs + tk.c_runs for m in r.missing_prices)
        else:
            t_costs.append(ct)
            c_costs.append(cc)
    cmp.unknown_models = sorted(models)
    cmp.mcnemar_p = stats.mcnemar_exact(cmp.only_t, cmp.only_c)
    cmp.cost_t_cheaper, cmp.cost_c_cheaper, cmp.cost_ties, cmp.cost_p = stats.sign_test(t_costs, c_costs)
    for definition in ACCEPTED_TICKET_DEFINITIONS:
        acc_t = sum(_ticket_accepted(tk.t_runs, definition) for tk in tickets)
        acc_c = sum(_ticket_accepted(tk.c_runs, definition) for tk in tickets)
        costs_t = [_ticket_cost(tk.t_runs) for tk in tickets]
        costs_c = [_ticket_cost(tk.c_runs) for tk in tickets]
        total_t = None if any(c is None for c in costs_t) else sum(costs_t)  # type: ignore[arg-type]
        total_c = None if any(c is None for c in costs_c) else sum(costs_c)  # type: ignore[arg-type]
        cmp.accepted[definition] = (acc_t, acc_c, total_t, total_c)
    return cmp


def _verdict(deviation: float, minimum: float) -> str:
    """met at +minimum or more from the target, not met at -minimum or less, else tie."""
    if deviation >= minimum:
        return "met"
    if deviation <= -minimum:
        return "not met"
    return "tie"


@dataclass
class Verdict:
    threshold: dict
    verdict: str  # met / not met / tie / unknown
    observed: str
    note: str = ""


def evaluate_threshold(th: dict, cmp: Comparison, block: dict) -> Verdict:
    """Evaluate one preregistered threshold.

    Pass rate: the target is no difference (``not_worse``) or a lead of
    ``margin`` points (``lead_by``). Cost per accepted ticket: the target is a
    ratio of 1. The verdict is *met* when the observation is at least the
    minimum effect beyond the target, *not met* when it is at least the minimum
    effect short of it, and *tie* in between; a difference of exactly the
    minimum effect counts as an effect. The significance level annotates the
    p-value and does not change the verdict. A threshold with nothing to
    evaluate (no paired ticket, unknown cost) is *unknown* and says why.
    """
    minimum = block["minimum_effect"]
    alpha = block["significance_level"]
    if th["metric"] == "hidden_tests_passed":
        if not cmp.n:
            return Verdict(th, "unknown", "no paired tickets")
        target = th.get("margin", 0) if th["requirement"] == "lead_by" else 0
        diff = cmp.diff_points
        sig = "significant" if cmp.mcnemar_p < alpha else "not significant"
        return Verdict(
            th, _verdict(diff - target, minimum["pass_rate_points"]),
            f"{diff:+.1f} points on {cmp.n} tickets ({cmp.only_t} vs {cmp.only_c} discordant), McNemar p={cmp.mcnemar_p:.4f}, {sig} at {alpha}",
        )
    ratio, why = cmp.cost_ratio(block["accepted_ticket"])
    if ratio is None:
        return Verdict(th, "unknown", why)
    r = minimum["cost_ratio"]
    # Cost is better when lower: met at ratio <= 1/r, not met at ratio >= r.
    verdict = "met" if ratio <= 1 / r else "not met" if ratio >= r else "tie"
    sig = "significant" if cmp.cost_p < alpha else "not significant"
    return Verdict(
        th, verdict,
        f"cost ratio {ratio:.3f} (treatment / control, per accepted ticket) on {cmp.n} tickets, sign test p={cmp.cost_p:.4f}, {sig} at {alpha}",
    )


@dataclass
class Reproducibility:
    arm: str
    tickets: int  # tickets with two or more counted runs
    pass_agreement: float | None  # share of run pairs of one ticket that agree on pass/fail
    wide_cost: int  # tickets whose costs differ by more than max_cost_ratio
    unknown_cost: int


def reproducibility(runs: list[Run], block: dict) -> list[Reproducibility]:
    by: dict[tuple[str, str], list[Run]] = {}
    for run in runs:
        if run.counted:
            by.setdefault((run.arm, run.task), []).append(run)
    out = []
    for arm in sorted({a for a, _ in by}):
        agree = pairs = tickets = wide = unknown = 0
        for (a, _task), group in sorted(by.items()):
            if a != arm or len(group) < 2:
                continue
            tickets += 1
            for i in range(len(group)):
                for j in range(i + 1, len(group)):
                    pairs += 1
                    agree += group[i].passed == group[j].passed
            costs = [r.cost for r in group]
            if any(c is None for c in costs):
                unknown += 1
            elif min(costs) == 0 or max(costs) / min(costs) > block["reproducibility"]["max_cost_ratio"]:  # type: ignore[type-var]
                wide += 1
        out.append(Reproducibility(arm, tickets, agree / pairs if pairs else None, wide, unknown))
    return out


# ------------------------------------------------------------------ output


def _usd(value: float | None) -> str:
    return "unknown" if value is None else f"${value:,.4f}"


def _pct(value: float | None) -> str:
    return "-" if value is None else f"{value:.1f}%"


def _table(header: list[str], rows: list[list[str]]) -> list[str]:
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join(" --- " for _ in header) + "|"]
    lines += ["| " + " | ".join(row) + " |" for row in rows]
    return lines


def _first_commit_time(inputs: Inputs) -> datetime | None:
    out = _git(inputs.bench, "log", "--diff-filter=A", "--format=%aI", "--", "PREREGISTRATION.md")
    lines = [ln for ln in (out or "").splitlines() if ln.strip()]
    return datetime.fromisoformat(lines[-1]) if lines else None


def _as_utc(text: str) -> datetime:
    when = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def runs_before_preregistration(inputs: Inputs) -> list[Run]:
    first = _first_commit_time(inputs)
    if first is None:
        return []
    return [r for r in inputs.runs if not r.record["provenance"]["smoke"] and _as_utc(r.record["started_at"]) < first]


def render_markdown(inputs: Inputs, name: str) -> str:
    block = inputs.thresholds
    definitions = ACCEPTED_TICKET_DEFINITIONS
    runs = inputs.runs
    counted = [r for r in runs if r.counted]
    out: list[str] = [f"# Benchmark report: {name}", ""]
    out += [
        f"- Batches: {', '.join(inputs.batches)}",
        f"- Runs: {len(runs)} in total, {len(counted)} counted, "
        f"{sum(r.exclusion == 'smoke' for r in runs)} smoke (left out of every table), "
        f"{sum(r.exclusion == 'infra_error' for r in runs)} infrastructure-failed, "
        f"{sum(r.exclusion == 'contamination_suspect' for r in runs)} contamination-suspect",
        f"- Preregistration hash in the runs: {', '.join(inputs.recorded_hashes) or 'none (smoke runs only)'}; "
        f"`PREREGISTRATION.md` now: {blob_hash(inputs.prereg_path)}",
        f"- Accepted ticket for the cost metric: `{block['accepted_ticket']}`; "
        f"minimum effect: {block['minimum_effect']['pass_rate_points']} points, cost ratio {block['minimum_effect']['cost_ratio']}; "
        f"significance level: {block['significance_level']}",
        "",
        "## Deviation from real use",
        "",
        DEVIATION_NOTE,
        "",
    ]

    comparisons = {
        (c["treatment"], c["control"], scope): compare(runs, c["treatment"], c["control"], scope)
        for c in block["primary_comparisons"]
        for scope in SCOPES
    }

    out += ["## Thresholds", "", "A threshold is *met* when the result is at least the minimum effect beyond its target, "
            "*not met* when it is at least the minimum effect short of it, and a *tie* in between; *unknown* means there was "
            "nothing to evaluate. The target is no difference (`not_worse`), a lead of `margin` points (`lead_by`), or equal cost.", ""]
    rows = []
    for th in block["thresholds"]:
        cmp = comparisons[(th["comparison"]["treatment"], th["comparison"]["control"], th["size_class"])]
        v = evaluate_threshold(th, cmp, block)
        req = th["requirement"] + (f" {th['margin']} points" if th["requirement"] == "lead_by" else "")
        rows.append([f"`{th['id']}`", f"{th['comparison']['treatment']} vs {th['comparison']['control']}", th["metric"],
                     th["size_class"], req, f"**{v.verdict}**", v.observed])
    out += _table(["Threshold", "Comparison", "Metric", "Size class", "Requirement", "Verdict", "Observed"], rows) + [""]

    out += ["## Paired comparisons", "",
            "Pass rates are over the paired tickets (majority pass across seeds). The cost sign test drops ties and tickets with an unknown cost.", ""]
    for c in block["primary_comparisons"]:
        t, ctl = c["treatment"], c["control"]
        out += [f"### {t} against {ctl}", ""]
        rows = []
        for scope in SCOPES:
            cmp = comparisons[(t, ctl, scope)]
            cells = [scope, str(cmp.n), _pct(cmp.rate(cmp.pass_t)), _pct(cmp.rate(cmp.pass_c)),
                     f"{cmp.only_t} / {cmp.only_c}", f"{cmp.mcnemar_p:.4f}",
                     f"{cmp.cost_t_cheaper} / {cmp.cost_c_cheaper} / {cmp.cost_ties}", f"{cmp.cost_p:.4f}"]
            for d in definitions:
                ct, cc = cmp.cost_per_accepted(d)
                cells.append(f"{_usd(ct)} / {_usd(cc)}" if not cmp.unknown_models else "unknown / unknown")
            rows.append(cells)
        out += _table(
            ["Size class", "Tickets", f"{t} pass", f"{ctl} pass", f"Only {t} / only {ctl} passed", "McNemar p",
             f"Cost: {t} cheaper / {ctl} cheaper / tie", "Sign test p",
             f"Cost per accepted ticket, tests pass ({t} / {ctl})", f"Cost per accepted ticket, tests pass and review merge ({t} / {ctl})"],
            rows) + [""]
        overall = comparisons[(t, ctl, "all")]
        out += [f"McNemar (all sizes): {overall.only_t + overall.only_c} discordant pairs "
                f"({overall.only_t} only {t} passed, {overall.only_c} only {ctl} passed), exact p = {overall.mcnemar_p:.4f}.", ""]
        unknown = overall.unknown_models
        if unknown:
            out += [f"Cost is unknown for {overall.cost_tickets_unknown} tickets: no price in `bench/prices.yaml` for "
                    + ", ".join(f"`{m}`" for m in unknown) + ".", ""]

    # per-arm spread between seeds
    by: dict[tuple[str, str], list[Run]] = {}
    for r in counted:
        by.setdefault((r.arm, r.task), []).append(r)
    repeated = [(k, v) for k, v in sorted(by.items()) if len(v) > 1]
    out += ["## Spread between seeds", ""]
    if repeated:
        rows = []
        for (arm, task), group in repeated:
            costs = [r.cost for r in group]
            span = "unknown" if any(c is None for c in costs) else f"{_usd(min(costs))} to {_usd(max(costs))}"  # type: ignore[type-var]
            rows.append([arm, task, group[0].record["size_class"], str(len(group)),
                         f"{sum(r.passed for r in group)} / {len(group)}", span])
        out += _table(["Arm", "Ticket", "Size class", "Runs", "Passed", "Cost range"], rows) + [""]
        rows = []
        for rep in reproducibility(runs, block):
            if not rep.tickets:
                continue
            need = block["reproducibility"]["min_pass_agreement"]
            ok = rep.pass_agreement is not None and rep.pass_agreement >= need
            rows.append([rep.arm, str(rep.tickets), _pct(None if rep.pass_agreement is None else 100 * rep.pass_agreement),
                         f"{'met' if ok else 'not met'} (needs {100 * need:.0f}%)",
                         f"{rep.wide_cost} above {block['reproducibility']['max_cost_ratio']}x, {rep.unknown_cost} unknown"])
        out += ["Reproducibility (two runs of one arm on one ticket):", ""]
        out += _table(["Arm", "Tickets with repeats", "Pass agreement", "Criterion", "Tickets by cost ratio"], rows) + [""]
    else:
        out += ["No arm has more than one counted run on a ticket.", ""]

    out += ["## Runs left out of the tables", ""]
    for label, why in (("Contamination-suspect runs", "contamination_suspect"), ("Infrastructure-failed runs", "infra_error")):
        listed = [r for r in runs if r.exclusion == why]
        out += [f"### {label}", ""]
        if listed:
            out += [f"- `{r.record['run_id']}` ({r.arm}, {r.task}, seed {r.record['seed']}, status {r.record['status']}"
                    + (f", {r.record['reason']}" if r.record.get("reason") else "") + ")" for r in listed]
        else:
            out += ["None."]
        out += [""]
    before = runs_before_preregistration(inputs)
    if before:
        out += ["### Measured runs started before the preregistration's first commit", ""]
        out += [f"- `{r.record['run_id']}` started {r.record['started_at']}" for r in before] + [""]
    missing_reviews = [r for r in counted if r.passed and r.review is None]
    if missing_reviews:
        out += ["### Passing runs without a review record", "",
                f"{len(missing_reviews)} counted passing runs have no review record; under `tests_pass_and_review_merge` they are not accepted.", ""]
    out += ["Every run, left out or not, is in `runs.csv`.", ""]
    return "\n".join(out)


CSV_COLUMNS = (
    "run_id", "batch", "arm", "task", "seed", "size_class", "source", "status", "reason", "passed", "smoke",
    "contamination_suspect", "counted_in_tables", "excluded_because", "started_at", "ended_at", "wall_clock_seconds",
    "hidden_paths_overwritten", "files_changed", "insertions", "deletions", "markdown_lines", "pr_count",
    "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "cost_usd", "models_without_price",
    "review_decision", "review_critical", "review_major", "review_minor", "review_minutes",
    "preregistration_hash", "bench_commit", "image_digest",
)


def render_csv(inputs: Inputs) -> str:
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")
    writer.writerow(CSV_COLUMNS)
    for run in sorted(inputs.runs, key=lambda r: (r.record["batch"], r.task, r.arm, r.record["seed"], r.record["run_id"])):
        rec, prov, stats_ = run.record, run.record["provenance"], run.record["diff_stats"] or {}
        tokens = {k: sum(u.get(k, 0) for u in rec["usage"].values()) for k in ("input", "output", "cache_read", "cache_write")}
        rev = run.review or {}
        defects = rev.get("defects", {})
        writer.writerow([
            rec["run_id"], rec["batch"], rec["arm"], rec["task"], rec["seed"], rec["size_class"], rec["source"],
            rec["status"], rec.get("reason", ""), str(rec["passed"]).lower(), str(prov["smoke"]).lower(),
            str(rec["contamination_suspect"]).lower(), str(run.counted).lower(), run.exclusion, rec["started_at"],
            rec["ended_at"], rec["wall_clock_seconds"], ";".join(rec["hidden_paths_overwritten"]),
            stats_.get("files_changed", ""), stats_.get("insertions", ""), stats_.get("deletions", ""),
            rec["markdown_lines"], rec["pr_count"], tokens["input"], tokens["output"], tokens["cache_read"],
            tokens["cache_write"], "" if run.cost is None else f"{run.cost:.6f}", ";".join(run.missing_prices),
            rev.get("merge_decision", ""), defects.get("critical", ""), defects.get("major", ""),
            defects.get("minor", ""), rev.get("review_minutes", ""), prov["preregistration_hash"] or "",
            prov["bench_commit"], prov["image_digest"],
        ])
    return buf.getvalue()


def build_metadata(inputs: Inputs, name: str) -> dict[str, Any]:
    prov = [r.record["provenance"] for r in inputs.runs]
    arms: dict[str, Any] = {}
    for arm_id, data in sorted(inputs.arms.items()):
        path = inputs.arm_files[arm_id]
        prompt = path.parent / data["prompt"]
        recorded = [r.record["provenance"] for r in inputs.runs if r.arm == arm_id]
        entry: dict[str, Any] = {
            "file": f"arms/{path.name}",
            "sha256": sha256_of(path),
            "recorded_arm_file_hashes": sorted({p["arm_file_hash"] for p in recorded}),
            "settings": data,
            "prompt": {
                "file": f"arms/{data['prompt']}",
                "sha256": sha256_of(prompt) if prompt.is_file() else None,
                "text": prompt.read_text(encoding="utf-8") if prompt.is_file() else None,
                "recorded_prompt_hashes": sorted({p["prompt_hash"] for p in recorded}),
            },
        }
        if data["kind"] == "nogging":
            entry["agents_md"] = _agents_md(inputs.bench, data["nogging_ref"])
        arms[arm_id] = entry
    return {
        "schema": 1,
        "report": name,
        "batches": inputs.batches,
        "bench_commit": (_git(inputs.bench, "rev-parse", "HEAD") or "").strip() or None,
        "bench_commits_in_runs": sorted({p["bench_commit"] for p in prov}),
        "preregistration": {
            "file": "PREREGISTRATION.md",
            "blob_hash": blob_hash(inputs.prereg_path),
            "hashes_in_runs": inputs.recorded_hashes,
        },
        "arms": arms,
        "models": sorted({m for r in inputs.runs for m in r.record["usage"]}),
        "efforts": {a: d["effort"] for a, d in sorted(inputs.arms.items())},
        "agent_versions": {a: d["agent"]["version"] for a, d in sorted(inputs.arms.items())},
        "agent_versions_in_runs": sorted({p["agent_cli_version"] for p in prov}),
        "image_digests": sorted({p["image_digest"] for p in prov}),
        # Decision 20: one entry when every run's container had the same options.
        "container_options_in_runs": [list(o) for o in sorted({tuple(p["container_options"]) for p in prov if "container_options" in p})],
        "usage_collectors": sorted({(r.record["usage_collector"]["helper_version"], r.record["usage_collector"]["nogging_commit"]) for r in inputs.runs}),
        "prices": {m: vars(p) for m, p in sorted(inputs.prices.items())},
        "runs": {"total": len(inputs.runs), "counted": sum(r.counted for r in inputs.runs)},
    }


def _agents_md(bench: Path, ref: str) -> dict[str, Any]:
    if not _REF.match(ref):
        return {"ref": ref, "unavailable": "the ref is not a plain git ref"}
    text = _git(bench, "show", f"{ref}:AGENTS.md")
    if text is None:
        return {"ref": ref, "unavailable": "AGENTS.md could not be read at that ref in this repository"}
    return {"ref": ref, "sha256": "sha256:" + hashlib.sha256(text.encode()).hexdigest(), "text": text}


def write_report(inputs: Inputs, out_dir: Path) -> list[Path]:
    name = out_dir.name
    out_dir.mkdir(parents=True, exist_ok=True)
    files = {
        "report.md": render_markdown(inputs, name),
        "runs.csv": render_csv(inputs),
        "metadata.json": json.dumps(build_metadata(inputs, name), indent=2, sort_keys=True) + "\n",
    }
    for filename, text in files.items():
        (out_dir / filename).write_text(text, encoding="utf-8")
    return [out_dir / f for f in files]


# --------------------------------------------------------------------- CLI


def _command(args: argparse.Namespace) -> int:
    bench = Path(args.bench_dir).resolve() if args.bench_dir else find_bench_dir()
    try:
        inputs = load_inputs(bench, args.batch, allow_mixed_preregistration=args.allow_mixed_preregistration)
    except ReportRefused as exc:
        for problem in exc.problems:
            print(f"report: refused: {problem}", file=sys.stderr)
        return 1
    for path in write_report(inputs, Path(args.out)):
        print(f"report: wrote {path}")
    return 0


def add_parser(subparsers: Any) -> None:
    parser = subparsers.add_parser(
        "report",
        help="pair runs per ticket, evaluate the preregistered thresholds and export every run",
        description="Write report.md, runs.csv and metadata.json for the named batches.",
    )
    parser.add_argument("--batch", nargs="+", required=True, metavar="BATCH", help="result batches (bench/results/<batch>.jsonl)")
    parser.add_argument("--out", required=True, help="output directory, normally bench/reports/<name>/")
    parser.add_argument("--bench-dir", help="the bench directory (default: found from the working directory)")
    parser.add_argument("--allow-mixed-preregistration", action="store_true",
                        help="report batches that carry different preregistration hashes together")
    parser.set_defaults(handler=_command)
