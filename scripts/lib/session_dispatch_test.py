"""Decision 7, row by row, as pure decide() cases with an injected clock."""
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import session_dispatch as d

T0 = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)
HEAD = "a" * 40


def lead(**fields):
    fact = {"session": "s1", "role": "lead", "agent": "claude", "bead": "B1", "state": "idle",
            "nudgeable": True, "head": HEAD, "gaps": [], "bead_status": "in_progress", "checks": None}
    fact.update(fields)
    return fact


def checks(status="passing", **fields):
    obs = {"status": status, "pr_number": 7, "pr_state": "OPEN", "head_sha": HEAD, "mergeable": "MERGEABLE",
           "fingerprint": "fp1", "failed": [], "pending": [], "total": 3, "additions": 10, "deletions": 2}
    obs.update(fields)
    return obs


class Pass:
    """Passes over one session, applying `record` the way a real pass does."""

    def __init__(self, policy=None):
        self.policy = d.policy_from({"enabled": True, **(policy or {})})
        self.memory = {}
        self.now = T0

    def run(self, fact, advance=0, apply=True, hold=None):
        self.now += timedelta(seconds=advance)
        policy = dict(self.policy, hold_sends=True) if hold else self.policy
        actions, self.memory = d.decide([fact], self.memory, policy, self.now)
        if apply:
            for action in actions:
                d.record(self.memory, action, self.now)
        return actions

    def settled(self, fact):
        """First sight, then a pass past the 60 s settle."""
        self.run(fact)
        return self.run(fact, advance=61)


def kinds(actions):
    return [a["item"]["kind"] if a["type"] == "queue" else a["type"] for a in actions]


class Config(unittest.TestCase):
    def test_absent_blocks_are_fine_and_the_defaults_are_off(self):
        self.assertEqual(d.config_errors({}), [])
        policy = d.policy_from(None)
        self.assertEqual((policy["enabled"], policy["retire_merged"]), (False, False))
        self.assertEqual((policy["max_nudges"], policy["stall_after"], policy["ci_timeout"]), (2, 900, 3600))

    def test_the_full_block_of_decision_13_is_accepted(self):
        block = {"enabled": False, "max_nudges": 2, "max_ci_nudges": 2, "stall_after": "15m", "ci_timeout": "60m",
                 "retire_merged": False, "precompact_after": "50m", "precompact_min_tokens": 100000,
                 "wake": {"urgent_quiet": "90s", "normal_quiet": "300s", "max_hold": "900s", "min_gap": "300s",
                          "max_wakes_per_hour": 4, "remind_after": "4h", "hold_above_percent": 85,
                          "keep_warm": True, "keep_warm_after": "50m", "quiet_hours": ["22:00-07:00"]}}
        context = {"auto_compact_window": 200000, "idle_compact_min_tokens": 100000}
        self.assertEqual(d.config_errors({"session_dispatch": block, "orchestrator_context": context}), [])

    def test_an_unknown_key_is_refused_by_name(self):
        self.assertEqual(d.config_errors({"session_dispatch": {"max_nudge": 2}}),
                         ["session_dispatch: unknown key 'max_nudge'"])
        self.assertEqual(d.config_errors({"session_dispatch": {"wake": {"quiet": "1m"}}}),
                         ["session_dispatch.wake: unknown key 'quiet'"])
        self.assertEqual(d.config_errors({"orchestrator_context": {"window": 1}}),
                         ["orchestrator_context: unknown key 'window'"])

    def test_a_bad_value_is_refused(self):
        for block in ({"enabled": "yes"}, {"max_nudges": -1}, {"max_nudges": True}, {"stall_after": "soon"},
                      {"stall_after": 0}, {"wake": []}, {"wake": {"quiet_hours": ["25:00-07:00"]}},
                      {"wake": {"hold_above_percent": 101}}):
            self.assertTrue(d.config_errors({"session_dispatch": block}), block)
        self.assertTrue(d.config_errors({"session_dispatch": []}))


if __name__ == "__main__":
    unittest.main()
