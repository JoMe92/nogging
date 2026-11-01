#!/usr/bin/env python3
"""Small tests of the Git and token loaders: the data contract, gates and refusals, with
Git and Dolt faked at their process boundary. The behaviour against a real collection is
in scripts/dashboard-usage.test.sh."""
from __future__ import annotations

import datetime as dt, json, subprocess, sys, tempfile, unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_cache as cache
import dashboard_slow_sources as slow
import token_usage_report as report
import token_usage_report_test as fixtures
from token_usage_store import Store

ADDRESS = "someone" + "@" + "example.com"
NOW = dt.datetime(2026, 11, 1, 12, 0, tzinfo=dt.timezone.utc)
SHA_A, SHA_B, SHA_C = "a" * 40, "b" * 40, "c" * 40
LOG = "".join(f"{sha}\x1f{at}\x1f{subject}\n" for sha, at, subject in (
    (SHA_C, 1790000300, f"fix: tell {ADDRESS} [SPEC-aa1]"),
    (SHA_B, 1790000200, "chore: no token [wip]"),
    (SHA_A, 1790000100, "feat: first [SPEC-aa1] [SPEC-bb2]"),
))


def git_run(answers):
    """A fake `subprocess.run` for Git, keyed by the first Git word after the options."""
    def run(argv, **kwargs):
        word = argv[argv.index("-c") + 2]
        if word == "log" and "--numstat" in argv:
            answer = answers["numstat"]
        elif word == "log" and "--max-parents=0" in argv:
            answer = answers.get("roots", "1780000000\n")
        else:
            answer = answers[word]
        return SimpleNamespace(returncode=answer is None, stdout=answer or "", stderr="")
    return run


NUMSTAT = (f"\x1e{SHA_C}\n\n1\t1\tsrc/app.py\n3\t0\tsrc/app_test.py\n"
           f"\x1e{SHA_A}\n\n10\t0\tsrc/app.py\n")


class ReadGit(unittest.TestCase):
    def read(self, **changes):
        answers = {"for-each-ref": f"{SHA_C} refs/heads/develop\n", "log": LOG, "numstat": NUMSTAT, **changes}
        return slow.read_git("/repo", run=git_run(answers), numstat={})

    def test_the_snapshot_keeps_the_contract(self):
        snapshot = self.read()
        self.assertEqual(sorted(snapshot), ["commits", "floor", "root_commit_at", "tokenless_commits"])
        self.assertEqual([c["sha"] for c in snapshot["commits"]], [SHA_A, SHA_C], "oldest first")
        self.assertEqual(sorted(snapshot["commits"][0]), ["at", "beads", "production_lines", "sha", "subject", "test_lines"])
        self.assertEqual(snapshot["commits"][0]["beads"], ["SPEC-aa1", "SPEC-bb2"])
        self.assertEqual((snapshot["commits"][1]["production_lines"], snapshot["commits"][1]["test_lines"]), (2, 3))
        self.assertEqual(snapshot["tokenless_commits"], 1, "`[wip]` is not a Bead")
        self.assertEqual(snapshot["floor"], "2026-09-21T14:15:00Z")
        self.assertEqual(snapshot["root_commit_at"], "2026-05-28T20:26:40Z")

    def test_a_subject_is_scrubbed(self):
        text = json.dumps(self.read())
        self.assertNotIn(ADDRESS, text)
        self.assertIn("[address]", text)

    def test_the_earliest_of_several_roots_counts(self):
        self.assertEqual(self.read(roots="1780000900\n1780000000\n")["root_commit_at"], "2026-05-28T20:26:40Z")

    def test_no_token_means_no_floor_rather_than_a_zero(self):
        snapshot = self.read(log=f"{SHA_B}\x1f1790000200\x1fchore: none\n")
        self.assertEqual((snapshot["commits"], snapshot["floor"], snapshot["tokenless_commits"]), ([], None, 1))

    def test_a_repository_without_a_ref_is_absent(self):
        with self.assertRaises(cache.Absent):
            self.read(**{"for-each-ref": ""})

    def test_a_failing_git_is_a_source_error_and_keeps_no_text(self):
        for broken in ({"for-each-ref": None}, {"log": None}, {"numstat": None}, {"roots": None}):
            with self.subTest(broken), self.assertRaises(cache.SourceError) as caught:
                self.read(**broken)
            self.assertEqual(caught.exception.kind, "error")


class GitGate(unittest.TestCase):
    def test_it_moves_with_the_walked_refs_only(self):
        listing = {"for-each-ref": f"{SHA_A} refs/heads/develop\n"}
        gate = slow.git_gate("/repo", run=git_run(listing))
        first = gate()
        self.assertEqual(gate(), first)
        listing["for-each-ref"] = f"{SHA_B} refs/heads/develop\n"
        self.assertNotEqual(gate(), first)

    def test_it_asks_for_branches_remotes_and_tags_only(self):
        seen = []
        def run(argv, **kwargs):
            seen.append(argv)
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        slow.git_gate("/repo", run=run)()
        self.assertEqual(seen[0][-3:], ["refs/heads", "refs/remotes", "refs/tags"])

    def test_no_answer_is_none(self):
        self.assertIsNone(slow.git_gate("/repo", run=git_run({"for-each-ref": None}))())


class Tokens(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="nogg dashboard usage ")
        self.addCleanup(temp.cleanup)
        self.state = Path(temp.name)
        self.store = Store(self.state, lambda _: {"state_dir": str(self.state)})
        self.collect_store = lambda: self.store

    def read(self, **options):
        return slow.read_tokens(self.collect_store, lambda: report, **options)

    def tree(self):
        return sorted(str(path.relative_to(self.state)) for path in self.state.rglob("*"))

    def present(self):
        """A store on disk that only a real `dolt` call could read."""
        with self.store.locked():
            (self.store.database / ".dolt").mkdir(parents=True)

    def test_no_store_is_absent_and_creates_nothing(self):
        with self.assertRaises(cache.Absent):
            self.read()
        self.assertEqual(self.tree(), [])

    def test_a_store_without_a_lock_is_absent(self):
        (self.store.database / ".dolt").mkdir(parents=True)
        before = self.tree()
        with self.assertRaises(cache.Absent):
            self.read()
        self.assertEqual(self.tree(), before)

    def test_the_cap_covers_the_whole_read_not_each_call(self):
        self.present()
        ticks = iter((100.0, 100.0, 146.0))    # the start, the first call, the second call
        calls = []
        def load_facts(store, timeout):
            calls.append(timeout())
            calls.append(timeout())
        fake = SimpleNamespace(load_facts=load_facts, StoreTimeout=report.StoreTimeout, LeaseAbsent=report.LeaseAbsent,
                               LeaseBusy=report.LeaseBusy)
        with self.assertRaises(report.StoreTimeout):
            slow.read_tokens(self.collect_store, lambda: fake, clock=lambda: next(ticks))
        self.assertEqual(calls, [45.0])

    def test_the_gate_reads_last_success_and_tolerates_anything_else(self):
        gate = slow.tokens_gate(self.collect_store)
        self.assertIsNone(gate())
        self.assertEqual(self.tree(), [])
        status = self.state / "token-usage/collector/status.json"
        status.parent.mkdir(parents=True)
        for text, wanted in (("{broken", None), ("[]", None), ('{"last_success_at": "t1"}', "t1")):
            status.write_text(text)
            self.assertEqual(gate(), wanted, text)


class Reduction(unittest.TestCase):
    def test_the_snapshot_holds_reductions_and_no_identity(self):
        facts = fixtures.bead_facts()
        snapshot = slow.reduce_tokens(report, facts.tables, fixtures.META, NOW)
        self.assertEqual(sorted(snapshot), ["by_bead", "by_day", "by_model", "floors", "partial"])
        self.assertEqual(sorted(snapshot["by_bead"]), ["SPEC-a", "SPEC-b"], "the unattributed group is no Bead")
        self.assertEqual(sorted(snapshot["by_bead"]["SPEC-a"]), ["tokens", "unknown_counters"])
        self.assertEqual(snapshot["by_bead"]["SPEC-a"]["tokens"]["output_tokens"], 140)
        self.assertEqual(snapshot["by_bead"]["SPEC-a"]["unknown_counters"]["cache_write_tokens"], 1)
        text = json.dumps(snapshot)
        for secret in ("dev-1", "lead-sess", "nogg-session", fixtures.META["project_id"]):
            self.assertNotIn(secret, text)

    def test_a_bead_with_runtime_but_no_usage_is_a_gap_not_a_zero(self):
        facts = fixtures.Facts().segment("q", "quiet", start=fixtures.at(1), end=fixtures.at(2))
        facts.boundary("q", 0, fixtures.at(1), bead="SPEC-q")
        self.assertEqual(slow.reduce_tokens(report, facts.tables, fixtures.META, NOW)["by_bead"], {})


if __name__ == "__main__":
    unittest.main()
