#!/usr/bin/env python3
"""Tests of the Bead table's server side (TASK-DSH-005): the facets of /api/v1/beads.
Small tests run on the model; the medium test reads the route of a real server on 127.0.0.1
with a stub `bd`, so it needs no Dolt and no sleep."""
from __future__ import annotations

import sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_model as model
from dashboard_data_test import Live, bead


def listed(id, **extra):
    return model.allow_bead(bead(id, **extra))


def values(facet):
    return [(entry["value"], entry["count"]) for entry in facet]


class Facets(unittest.TestCase):
    def beads(self):
        return [listed(id="SPEC-aaaa", priority=1, labels=["openspec:change:demo", "openspec:task:T-1"]),
                listed(id="SPEC-bbbb", status="closed", priority=2, labels=["openspec:change:demo", "discovery"]),
                listed(id="SPEC-cccc", status="in_progress", priority=1, issue_type="bug", labels=["discovery"]),
                listed(id="SPEC-dddd", status="blocked", priority=0, labels=["openspec:change:other"])]

    def test_a_filter_by_change_has_its_count_and_the_beads_without_a_change(self):
        facets = model.bead_facets(self.beads())
        self.assertEqual(values(facets["change"]), [("demo", 2), ("other", 1), (None, 1)])
        rows = model.bead_list({"beads": self.beads()})["beads"]
        self.assertEqual([row["id"] for row in rows if row["change"] == "demo"], ["SPEC-aaaa", "SPEC-bbbb"])
        self.assertEqual([row["id"] for row in rows if row["change"] is None], ["SPEC-cccc"])

    def test_status_comes_in_workflow_order_and_unknown_ones_follow(self):
        beads = self.beads() + [listed(id="SPEC-eeee", status="pinned")]
        self.assertEqual(values(model.bead_facets(beads)["status"]),
                         [("open", 1), ("in_progress", 1), ("blocked", 1), ("closed", 1), ("pinned", 1)])

    def test_type_and_priority_are_counted_and_sorted(self):
        facets = model.bead_facets(self.beads())
        self.assertEqual(values(facets["type"]), [("bug", 1), ("task", 3)])
        self.assertEqual(values(facets["priority"]), [(0, 1), (1, 2), (2, 1)])

    def test_a_label_class_counts_the_beads_that_carry_it(self):
        facets = model.bead_facets(self.beads())
        self.assertEqual(values(facets["label"]), [("openspec:task", 1), ("discovery", 2)])
        self.assertEqual(model.label_classes({"labels": ["openspec:task:T-1", "discovery", "openspec:taskforce"]}),
                         ["openspec:task", "discovery"])
        self.assertEqual(model.label_classes({"labels": ["openspec:change:demo"]}), [])

    def test_the_facets_count_all_beads_whatever_the_list_shows(self):
        data = model.bead_list({"beads": self.beads(), "ready": []})
        self.assertEqual(sum(entry["count"] for entry in data["facets"]["status"]), len(data["beads"]))

    def test_a_bead_with_missing_fields_does_not_break_the_facets(self):
        odd = model.allow_bead({"id": "SPEC-zzzz", "labels": "not a list", "priority": "high"})
        facets = model.bead_facets([odd])
        self.assertEqual(values(facets["status"]), [(None, 1)])
        self.assertEqual(values(facets["priority"]), [(None, 1)])
        self.assertEqual(values(facets["change"]), [(None, 1)])


class Route(Live):
    def test_the_beads_route_returns_every_facet(self):
        self.answer("list", [bead("SPEC-aaaa", priority=1), bead("SPEC-bbbb", status="closed", labels=[]),
                             bead("SPEC-cccc", labels=["discovery"], status="blocked", issue_type="bug"),
                             bead("SPEC-dddd", labels=["openspec:change:other", "openspec:task:T-4"])])
        self.load(self.start())
        status, doc = self.get("/api/v1/beads")
        self.assertEqual(status, 200)
        data = doc["data"]
        self.assertEqual(sorted(data), ["beads", "facets"])
        self.assertEqual(sorted(data["facets"]), ["change", "label", "priority", "status", "type"])
        facets = data["facets"]
        self.assertEqual(values(facets["status"]), [("open", 2), ("blocked", 1), ("closed", 1)])
        self.assertEqual(values(facets["type"]), [("bug", 1), ("task", 3)])
        self.assertEqual(values(facets["priority"]), [(1, 1), (2, 3)])
        self.assertEqual(values(facets["change"]), [("demo", 1), ("other", 1), (None, 2)])
        self.assertEqual(values(facets["label"]), [("openspec:task", 1), ("discovery", 1)])
        self.assertEqual(len(data["beads"]), 4)

    def test_the_facets_leak_no_long_text(self):
        self.load(self.start())
        _, doc = self.get("/api/v1/beads")
        text = str(doc["data"]["facets"])
        self.assertNotIn("long description", text)
        self.assertNotIn("example.com", text)


if __name__ == "__main__":
    unittest.main()
