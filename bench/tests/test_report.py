"""`nogg-bench report`: pairing, thresholds, exports and refusals, offline."""

from __future__ import annotations

import copy
import csv
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml
from conftest import BENCH, FIXTURES

from nogg_bench import prices as prices_mod
from nogg_bench import report
from nogg_bench.cli import main
from nogg_bench.schema import check_result

GOOD_HASH = "3f786850e387550fdab836ed7e6dc881de23001b"
MODEL = "claude-opus-5-5"
FOUR_DOLLARS = {MODEL: {"input": 1_000_000, "output": 0, "cache_read": 0, "cache_write": 0}}  # $4.00 at list price

# ------------------------------------------------------------------ builders


def make_record(arm, task, seed=1, passed=True, size="small", usage=None, status="completed", smoke=False,
                suspect=False, batch="b", prereg=GOOD_HASH, started="2026-11-20T10:00:00Z"):
    rec = json.loads((FIXTURES / "valid/results/fixture-batch.jsonl").read_text().splitlines()[0])
    rec.update(arm=arm, task=task, seed=seed, passed=passed, size_class=size, status=status,
               batch=batch, run_id=f"{batch}-{arm}-{task}-{seed}", contamination_suspect=suspect,
               started_at=started, ended_at="2026-11-20T23:00:00Z")
    rec["tests"] = {"fail_to_pass": {"t::a": passed}, "pass_to_pass": {"t::b": True}}
    rec["usage"] = copy.deepcopy(FOUR_DOLLARS if usage is None else usage)
    rec["provenance"].update(smoke=smoke, preregistration_hash=None if smoke else prereg)
    if status == "infra_error":
        rec.update(reason="container did not start", tests={"fail_to_pass": {}, "pass_to_pass": {}}, diff_stats=None, diff_path=None, usage={})
    assert check_result(rec) == [], rec
    return rec


def as_run(rec, prices=None, review=None):
    cost, missing = report.run_cost(rec["usage"], prices if prices is not None else report.load_prices(BENCH / "prices.yaml"))
    why = "smoke" if rec["provenance"]["smoke"] else "infra_error" if rec["status"] == "infra_error" else \
        "contamination_suspect" if rec["contamination_suspect"] else ""
    return report.Run(rec, cost, missing, review, why)


def make_review(rec, decision):
    return {"schema": 1, "pack": "p", "item": "xx", "run_id": rec["run_id"], "merge_decision": decision,
            "defects": {"critical": 0, "major": 0, "minor": 0}, "review_minutes": 5, "comment": "c",
            "reviewed_at": "2026-11-21T09:30:00Z"}


def make_bench(tmp_path, records, reviews=(), arms=("A", "B", "C")):
    """A bench directory in a temp folder: fixture preregistration and arms, prices, the given lines."""
    bench = tmp_path / "bench"
    (bench / "arms" / "prompts").mkdir(parents=True)
    (bench / "results" / "review").mkdir(parents=True)
    shutil.copy(FIXTURES / "valid/PREREGISTRATION.md", bench / "PREREGISTRATION.md")
    shutil.copy(BENCH / "prices.yaml", bench / "prices.yaml")
    shutil.copy(FIXTURES / "valid/arms/prompts/a.md", bench / "arms/prompts/a.md")
    for arm in arms:
        if arm == "B":
            data = yaml.safe_load((FIXTURES / "valid/arms/A.yaml").read_text())
            data.update(id="B", kind="codex", model="gpt-5.3-codex", agent={"cli": "codex", "version": "0.9.0"},
                        credentials={"env": "OPENAI_API_KEY"})
            (bench / "arms/B.yaml").write_text(yaml.safe_dump(data))
        else:
            shutil.copy(FIXTURES / f"valid/arms/{arm}.yaml", bench / f"arms/{arm}.yaml")
    by_batch: dict[str, list] = {}
    for rec in records:
        by_batch.setdefault(rec["batch"], []).append(rec)
    for batch, recs in by_batch.items():
        (bench / "results" / f"{batch}.jsonl").write_text("".join(json.dumps(r) + "\n" for r in recs))
    if reviews:
        (bench / "results/review/p.jsonl").write_text("".join(json.dumps(r) + "\n" for r in reviews))
    return bench


def run_report(bench, out, *batches, extra=()):
    return main(["report", "--bench-dir", str(bench), "--batch", *batches, "--out", str(out), *extra])


def read_csv(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def paired_records(tasks, a_passes, c_passes, size="small", batch="b"):
    recs = []
    for i in range(tasks):
        task = f"t{size}{i:02d}"
        recs.append(make_record("A", task, passed=i < a_passes, size=size, batch=batch))
        recs.append(make_record("C", task, passed=i < c_passes, size=size, batch=batch))
    return recs


# ------------------------------------------------------------ the CLI wiring


def test_report_is_available_as_a_subcommand(capsys):
    with pytest.raises(SystemExit) as exc:
        main(["report", "--help"])
    assert exc.value.code == 0
    assert "--batch" in capsys.readouterr().out


# ------------------------------------------------------------- the statistics


def test_discordant_pairs_decide(tmp_path):
    # A passes 9 tickets C fails, C passes 2 that A fails, 3 both pass, 1 neither: 15 tickets.
    recs = []
    for i in range(9):
        recs += [make_record("A", f"ta{i}", passed=True), make_record("C", f"ta{i}", passed=False)]
    for i in range(2):
        recs += [make_record("A", f"tc{i}", passed=False), make_record("C", f"tc{i}", passed=True)]
    for i in range(3):
        recs += [make_record("A", f"tb{i}", passed=True), make_record("C", f"tb{i}", passed=True)]
    recs += [make_record("A", "tn", passed=False), make_record("C", "tn", passed=False)]
    bench = make_bench(tmp_path, recs)
    assert run_report(bench, tmp_path / "out", "b") == 0
    text = (tmp_path / "out/report.md").read_text()
    assert "11 discordant pairs (2 only C passed, 9 only A passed), exact p = 0.0654" in text


def test_a_ticket_takes_the_majority_pass_and_the_median_cost_across_seeds():
    costs = {1: 1_000_000, 2: 2_000_000, 3: 9_000_000}  # $4, $8, $36
    a = [as_run(make_record("A", "t1", seed=s, passed=s != 3, usage={MODEL: {"input": n, "output": 0, "cache_read": 0, "cache_write": 0}}))
         for s, n in costs.items()]
    c = [as_run(make_record("C", "t1", passed=False))]
    cmp = report.compare(a + c, "A", "C", "all")
    assert [t.task for t in cmp.tickets] == ["t1"]
    assert cmp.pass_t == 1 and cmp.pass_c == 0 and cmp.only_t == 1  # two of three seeds passed
    assert report._ticket_cost(cmp.tickets[0].t_runs) == pytest.approx(8.0)  # the median, not the mean


def test_the_spread_between_seeds_is_shown(tmp_path):
    recs = [make_record("A", "t1", seed=s, passed=s < 3) for s in (1, 2, 3)] + [make_record("C", "t1")]
    bench = make_bench(tmp_path, recs)
    run_report(bench, tmp_path / "out", "b")
    text = (tmp_path / "out/report.md").read_text()
    assert "## Spread between seeds" in text
    assert "| A | t1 | small | 3 | 2 / 3 |" in text


def test_an_even_split_of_seeds_does_not_pass_the_ticket():
    a = [as_run(make_record("A", "t1", seed=s, passed=s == 1)) for s in (1, 2)]
    cmp = report.compare(a + [as_run(make_record("C", "t1", passed=False))], "A", "C", "all")
    assert cmp.pass_t == 0


def test_the_cost_sign_test_drops_ties():
    cheap = {MODEL: {"input": 1_000_000, "output": 0, "cache_read": 0, "cache_write": 0}}
    dear = {MODEL: {"input": 2_000_000, "output": 0, "cache_read": 0, "cache_write": 0}}
    runs = []
    for task, (ua, uc) in {"t1": (cheap, dear), "t2": (cheap, dear), "t3": (cheap, cheap), "t4": (dear, cheap)}.items():
        runs += [as_run(make_record("A", task, usage=ua)), as_run(make_record("C", task, usage=uc))]
    cmp = report.compare(runs, "A", "C", "all")
    assert (cmp.cost_t_cheaper, cmp.cost_c_cheaper, cmp.cost_ties) == (2, 1, 1)
    assert cmp.cost_p == 2 * (1 + 3) / 8  # three untied pairs, P(X <= 1)


def test_cost_per_accepted_ticket_under_both_definitions():
    runs, reviews = [], {}
    for task, decision in {"t1": "merge", "t2": "merge", "t3": "merge-after-changes"}.items():
        for arm in ("A", "C"):
            rec = make_record(arm, task)  # all pass, $4 each
            runs.append(as_run(rec, review=make_review(rec, decision)))
    runs.append(as_run(make_record("A", "t4", passed=False)))  # an unaccepted ticket still costs money
    runs.append(as_run(make_record("C", "t4", passed=False)))
    cmp = report.compare(runs, "A", "C", "all")
    assert cmp.cost_per_accepted("tests_pass") == pytest.approx((16 / 3, 16 / 3))
    assert cmp.cost_per_accepted("tests_pass_and_review_merge") == pytest.approx((8.0, 8.0))  # 16 / 2
    assert cmp.cost_ratio("tests_pass") == (pytest.approx(1.0), "")


def test_a_missing_price_stays_visible(tmp_path):
    odd = {"mystery-model": {"input": 5, "output": 5, "cache_read": 0, "cache_write": 0}}
    recs = [make_record("A", "t1"), make_record("C", "t1", usage=odd), make_record("A", "t2"), make_record("C", "t2")]
    bench = make_bench(tmp_path, recs)
    assert run_report(bench, tmp_path / "out", "b") == 0
    text = (tmp_path / "out/report.md").read_text()
    assert "no price in `bench/prices.yaml` for `mystery-model`" in text
    assert "unknown / unknown" in text and "$0.0000" not in text
    row = next(r for r in read_csv(tmp_path / "out/runs.csv") if r["arm"] == "C" and r["task"] == "t1")
    assert row["cost_usd"] == "" and row["models_without_price"] == "mystery-model"
    cost_row = next(l for l in text.splitlines() if "c-vs-a-cost" in l)
    assert "unknown" in cost_row and "mystery-model" in cost_row


def test_costs_follow_the_list_prices():
    prices = report.load_prices(BENCH / "prices.yaml")
    usage = {MODEL: {"input": 1_000_000, "output": 1_000_000, "cache_read": 1_000_000, "cache_write": 1_000_000}}
    cost, missing = report.run_cost(usage, prices)
    assert missing == [] and cost == pytest.approx(4 + 20 + 0.2 + 5)
    assert report.run_cost({}, prices) == (0.0, [])  # a run that used nothing costs nothing


# ------------------------------------------------------------ the thresholds


@pytest.mark.parametrize(
    ("deviation", "verdict"),
    [(5, "met"), (4.99, "tie"), (0, "tie"), (-4.99, "tie"), (-5, "not met")],
)
def test_the_verdict_at_the_tie_boundary(deviation, verdict):
    assert report._verdict(deviation, 5) == verdict


@pytest.mark.parametrize(("a_passes", "verdict"), [(8, "met"), (9, "tie"), (11, "not met")])
def test_a_lead_threshold_is_judged_against_its_margin(a_passes, verdict, thresholds):
    # 20 medium tickets: C passes 12. Lead of 15 points needed, minimum effect 5.
    # A with 8 passes: lead 20 (5 beyond the margin, met); 9: lead 15 (tie); 11: lead 5 (not met).
    runs = [as_run(r) for r in paired_records(20, a_passes, 12, size="medium")]
    th = next(t for t in thresholds["thresholds"] if t["id"] == "c-vs-a-tests-medium-large")
    cmp = report.compare(runs, "C", "A", "medium")
    assert report.evaluate_threshold(th, cmp, thresholds).verdict == verdict


def test_a_cost_threshold_uses_the_ratio_and_the_minimum_effect(thresholds):
    th = next(t for t in thresholds["thresholds"] if t["id"] == "c-vs-a-cost")
    a_cost = {MODEL: {"input": 1_000_000, "output": 0, "cache_read": 0, "cache_write": 0}}  # $4

    def verdict(c_input):
        usage = {MODEL: {"input": c_input, "output": 0, "cache_read": 0, "cache_write": 0}}
        runs = [as_run(make_record("A", "t1", usage=a_cost)), as_run(make_record("C", "t1", usage=usage))]
        return report.evaluate_threshold(th, report.compare(runs, "C", "A", "all"), thresholds)

    # Unreviewed runs are not accepted under tests_pass_and_review_merge: nothing to divide by.
    assert verdict(1_000_000).verdict == "unknown"
    thresholds["accepted_ticket"] = "tests_pass"
    assert verdict(500_000).verdict == "met"  # half the cost
    assert verdict(1_050_000).verdict == "tie"  # 5 percent dearer, under the 1.1 ratio
    assert verdict(1_100_000).verdict == "not met"  # exactly the minimum ratio counts as an effect


# ------------------------------------------------------------- failed runs


def test_failed_runs_are_exported(tmp_path):
    recs = [
        make_record("A", "t1"), make_record("C", "t1"),
        make_record("A", "t2", status="timeout", passed=False),
        make_record("C", "t2", status="infra_error", passed=False, usage={}),
        make_record("A", "t3", smoke=True), make_record("A", "t4", suspect=True),
    ]
    bench = make_bench(tmp_path, recs)
    assert run_report(bench, tmp_path / "out", "b") == 0
    rows = {r["run_id"]: r for r in read_csv(tmp_path / "out/runs.csv")}
    assert len(rows) == 6
    assert rows["b-A-t2-1"]["status"] == "timeout" and rows["b-A-t2-1"]["counted_in_tables"] == "true"
    assert rows["b-C-t2-1"]["status"] == "infra_error" and rows["b-C-t2-1"]["excluded_because"] == "infra_error"
    assert rows["b-A-t3-1"]["smoke"] == "true" and rows["b-A-t3-1"]["counted_in_tables"] == "false"
    text = (tmp_path / "out/report.md").read_text()
    assert "`b-C-t2-1`" in text and "container did not start" in text  # listed apart
    assert "`b-A-t4-1`" in text  # the contamination suspect is listed apart too
    assert "b-A-t3-1" not in text  # a smoke run is in no table


def test_a_smoke_run_counts_in_no_table(tmp_path):
    recs = [make_record("A", "t1"), make_record("C", "t1", passed=False), make_record("A", "t2", smoke=True), make_record("C", "t2", smoke=True, passed=False)]
    bench = make_bench(tmp_path, recs)
    run_report(bench, tmp_path / "out", "b")
    text = (tmp_path / "out/report.md").read_text()
    assert "2 smoke (left out of every table)" in text
    assert "| all | 1 |" in text  # one paired ticket, not two


# ---------------------------------------------------------------- refusals


def test_mixed_preregistrations_are_refused(tmp_path, capsys):
    other = "a" * 40
    recs = [make_record("A", "t1", batch="b1"), make_record("C", "t1", batch="b2", prereg=other)]
    bench = make_bench(tmp_path, recs)
    assert run_report(bench, tmp_path / "out", "b1", "b2") == 1
    err = capsys.readouterr().err
    assert GOOD_HASH in err and other in err and "preregistration" in err
    assert not (tmp_path / "out").exists()  # nothing is written on a refusal
    assert run_report(bench, tmp_path / "out", "b1", "b2", extra=("--allow-mixed-preregistration",)) == 0


def test_mismatched_timeboxes_are_refused(tmp_path, capsys):
    bench = make_bench(tmp_path, [make_record("A", "t1"), make_record("C", "t1")])
    arm = yaml.safe_load((bench / "arms/C.yaml").read_text())
    arm["timebox_minutes"] = 90
    (bench / "arms/C.yaml").write_text(yaml.safe_dump(arm))
    assert run_report(bench, tmp_path / "out", "b") == 1
    err = capsys.readouterr().err
    assert "arms C and A" in err or "arms A and C" in err
    assert "timebox_minutes" in err and "90" in err and "60" in err


@pytest.mark.parametrize("field", ["model", "effort"])
def test_same_vendor_arms_must_match(tmp_path, capsys, field):
    bench = make_bench(tmp_path, [make_record("A", "t1"), make_record("C", "t1")])
    arm = yaml.safe_load((bench / "arms/C.yaml").read_text())
    arm[field] = "other"
    (bench / "arms/C.yaml").write_text(yaml.safe_dump(arm))
    assert run_report(bench, tmp_path / "out", "b") == 1
    assert field in capsys.readouterr().err


def test_arms_of_different_vendors_may_differ_in_model(tmp_path):
    bench = make_bench(tmp_path, [make_record("A", "t1"), make_record("C", "t1"), make_record("B", "t1")])
    assert run_report(bench, tmp_path / "out", "b") == 0  # B is a Codex arm on another model


def test_a_comparison_needs_its_arm_files(tmp_path, capsys):
    bench = make_bench(tmp_path, [make_record("A", "t1"), make_record("C", "t1")], arms=("A", "C"))
    assert run_report(bench, tmp_path / "out", "b") == 1
    assert "arm B has no arm file" in capsys.readouterr().err


def test_an_invalid_result_line_is_refused_with_its_place(tmp_path, capsys):
    bench = make_bench(tmp_path, [make_record("A", "t1"), make_record("C", "t1")])
    rec = make_record("A", "t2")
    del rec["task"]
    with open(bench / "results/b.jsonl", "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    assert run_report(bench, tmp_path / "out", "b") == 1
    err = capsys.readouterr().err
    assert "b.jsonl:3" in err and "task" in err


def test_a_missing_batch_and_a_missing_preregistration_are_refused(tmp_path, capsys):
    bench = make_bench(tmp_path, [make_record("A", "t1")])
    assert run_report(bench, tmp_path / "out", "nope") == 1
    assert "batch nope has no result file" in capsys.readouterr().err
    (bench / "PREREGISTRATION.md").unlink()
    assert run_report(bench, tmp_path / "out", "b") == 1
    assert "PREREGISTRATION.md" in capsys.readouterr().err


# ------------------------------------------------------------- a full report


def test_a_full_report_from_the_fixtures(tmp_path):
    bench = make_bench(tmp_path, [])
    shutil.copytree(FIXTURES / "valid/results", bench / "results", dirs_exist_ok=True)
    out = tmp_path / "reports" / "fixture"
    assert run_report(bench, out, "fixture-batch") == 0
    assert sorted(p.name for p in out.iterdir()) == ["metadata.json", "report.md", "runs.csv"]

    text = (out / "report.md").read_text()
    assert report.DEVIATION_NOTE in text  # the deviation from real use is stated
    assert "1 infrastructure-failed" in text and "1 contamination-suspect" in text

    meta = json.loads((out / "metadata.json").read_text())
    assert sorted(meta["arms"]) == ["A", "B", "C"]
    for arm_id, entry in meta["arms"].items():
        arm_file = bench / entry["file"]
        assert entry["sha256"] == "sha256:" + hashlib.sha256(arm_file.read_bytes()).hexdigest()
        prompt = bench / entry["prompt"]["file"]
        assert entry["prompt"]["sha256"] == "sha256:" + hashlib.sha256(prompt.read_bytes()).hexdigest()
        assert entry["settings"]["model"] and entry["settings"]["effort"] and entry["settings"]["agent"]["version"]
    assert meta["arms"]["C"]["agents_md"]["ref"] == "v3.6.0"
    assert meta["models"] == [MODEL]
    assert meta["bench_commits_in_runs"] == ["0123456789abcdef0123456789abcdef01234567"]
    assert meta["image_digests"] and meta["usage_collectors"]
    assert meta["preregistration"]["hashes_in_runs"] == [GOOD_HASH]
    assert MODEL in meta["prices"]

    rows = read_csv(out / "runs.csv")
    assert [r["status"] for r in rows] == ["completed", "timeout", "infra_error", "completed"]  # by task, arm, seed: A1, A2, B1, C1
    assert list(rows[0]) == list(report.CSV_COLUMNS)


def test_the_report_is_deterministic(tmp_path):
    bench = make_bench(tmp_path, paired_records(4, 3, 2))
    run_report(bench, tmp_path / "one" / "same", "b")
    run_report(bench, tmp_path / "two" / "same", "b")
    for name in ("report.md", "runs.csv", "metadata.json"):
        assert (tmp_path / "one/same" / name).read_text() == (tmp_path / "two/same" / name).read_text()


def test_reviews_reach_the_csv_and_the_cost_metric(tmp_path):
    recs = [make_record("A", "t1"), make_record("C", "t1")]
    bench = make_bench(tmp_path, recs, reviews=[make_review(recs[0], "merge")])
    run_report(bench, tmp_path / "out", "b")
    row = next(r for r in read_csv(tmp_path / "out/runs.csv") if r["arm"] == "A")
    assert row["review_decision"] == "merge" and row["review_minutes"] == "5"
    assert "counted passing runs have no review record" in (tmp_path / "out/report.md").read_text()  # arm C's run


def test_the_repository_history_adds_the_agents_file_and_the_preregistration_date(tmp_path):
    recs = [make_record("A", "t1"), make_record("C", "t1")]
    bench = make_bench(tmp_path, recs)
    git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-C", str(tmp_path)]
    env = {"GIT_AUTHOR_DATE": "2026-12-01T00:00:00+00:00", "GIT_COMMITTER_DATE": "2026-12-01T00:00:00+00:00", "PATH": __import__("os").environ["PATH"]}
    (tmp_path / "AGENTS.md").write_text("agent rules at v3.6.0\n")
    subprocess.run([*git, "init", "-q"], check=True)
    subprocess.run([*git, "add", "AGENTS.md"], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "agents"], check=True, env=env)
    subprocess.run([*git, "tag", "v3.6.0"], check=True)
    subprocess.run([*git, "add", "bench/PREREGISTRATION.md"], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "prereg"], check=True, env=env)
    assert run_report(bench, tmp_path / "out", "b") == 0
    meta = json.loads((tmp_path / "out/metadata.json").read_text())
    assert meta["arms"]["C"]["agents_md"]["text"] == "agent rules at v3.6.0\n"
    assert meta["bench_commit"] and len(meta["bench_commit"]) == 40
    text = (tmp_path / "out/report.md").read_text()
    assert "started before the preregistration's first commit" in text  # fixture runs are from 2026-11-20
    assert "`b-A-t1-1`" in text


# ------------------------------------------------------------------- prices


def test_the_committed_price_table_is_valid_and_lists_the_claude_model():
    table = prices_mod.load_prices(BENCH / "prices.yaml")
    assert MODEL in table and table[MODEL].source.startswith("https://") and table[MODEL].date


def test_a_price_row_needs_its_numbers_source_and_date():
    problems = prices_mod.check_prices({"schema": 1, "prices": {"m": {"input": 1, "output": "x"}}})
    got = {p.field for p in problems}
    assert {"prices.m.output", "prices.m.cache_read", "prices.m.cache_write", "prices.m.source", "prices.m.date"} <= got
    assert prices_mod.check_prices({"schema": 1, "prices": {}})[0].field == "prices"
