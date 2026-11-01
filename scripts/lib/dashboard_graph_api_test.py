#!/usr/bin/env python3
"""Medium tests of /api/v1/graph: a real server on 127.0.0.1 port 0, the real loaders and
a stub `bd`. The layout itself is tested in dashboard_graph_test.py."""
from __future__ import annotations

import sys, unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_data_test as data
import dashboard_graph as graph

PATH = "/api/v1/graph?scope=change:demo"


def bead(identifier, *blockers, **extra):
    dependencies = [{"issue_id": identifier, "depends_on_id": blocker, "type": "blocks",
                     "created_at": "2026-10-01T10:00:00Z", "created_by": "Someone", "metadata": "{}"}
                    for blocker in blockers]
    return data.bead(identifier, dependencies=dependencies, **extra)


class Graph(data.Live):
    def loaded(self, beads, ready=(), cycles=()):
        self.answer("list", beads)
        self.answer("ready", [{"id": identifier} for identifier in ready])
        self.answer("cycles", list(cycles))
        refresher = self.start()
        self.load(refresher)
        return refresher

    def test_a_change_as_a_flow(self):
        self.loaded([bead("SPEC-aaaa"), bead("SPEC-bbbb", "SPEC-aaaa"), bead("SPEC-cccc", "SPEC-bbbb"),
                     bead("SPEC-dddd", "SPEC-aaaa"), bead("SPEC-eeee", labels=["openspec:change:other"])],
                    ready=["SPEC-aaaa"])
        status, doc = self.get(PATH)
        self.assertEqual((status, doc["schema"]), (200, "nogg.dashboard.graph/v1"))
        self.assertEqual(doc["sources"]["beads"]["state"], "fresh")
        result = doc["data"]
        places = {node["id"]: node for node in result["nodes"]}
        self.assertEqual(set(places), {"SPEC-aaaa", "SPEC-bbbb", "SPEC-cccc", "SPEC-dddd"})
        self.assertEqual(result["critical_path"], ["SPEC-aaaa", "SPEC-bbbb", "SPEC-cccc"])
        self.assertLess(places["SPEC-aaaa"]["x"], places["SPEC-bbbb"]["x"])
        self.assertNotEqual(places["SPEC-bbbb"]["lane"], places["SPEC-dddd"]["lane"])
        self.assertEqual(places["SPEC-aaaa"]["status"], "ready")

    def test_a_cycle_exists(self):
        self.loaded([bead("SPEC-aaaa", "SPEC-bbbb"), bead("SPEC-bbbb", "SPEC-aaaa")],
                    cycles=[[{"id": "SPEC-aaaa"}, {"id": "SPEC-bbbb"}]])
        status, doc = self.get(PATH)
        self.assertEqual(status, 200)
        self.assertEqual(doc["data"]["cycles"], [["SPEC-aaaa", "SPEC-bbbb"]])
        self.assertEqual(doc["data"]["critical_path"], [])
        self.assertEqual(len(doc["data"]["nodes"]), 2)
        self.assertEqual(sum(edge["reversed"] for edge in doc["data"]["edges"]), 1)

    def test_no_private_field_reaches_the_graph(self):
        self.loaded([bead("SPEC-aaaa", title=f"ask {data.ADDRESS}")])
        status, doc = self.get(PATH)
        self.assertEqual(status, 200)
        self.assertNotIn(data.ADDRESS, str(doc))
        self.assertNotIn("Nogging Orchestrator", str(doc))

    def test_loading_shows_an_empty_graph_and_its_state(self):
        self.start()
        status, doc = self.get(PATH)
        self.assertEqual((status, doc["data"]["nodes"], doc["sources"]["beads"]["state"]), (200, [], "loading"))

    def test_a_neighbourhood_through_the_api(self):
        self.loaded([bead("SPEC-aaaa"), bead("SPEC-bbbb", "SPEC-aaaa"), bead("SPEC-cccc", "SPEC-bbbb"),
                     bead("SPEC-dddd", "SPEC-cccc"), bead("SPEC-eeee", labels=["openspec:change:other"])],
                    ready=["SPEC-aaaa"])
        one = self.get("/api/v1/graph?scope=bead:SPEC-bbbb")
        two = self.get("/api/v1/graph?scope=bead:SPEC-bbbb&depth=2")
        names = lambda doc: {node["id"] for node in doc[1]["data"]["nodes"]}
        self.assertEqual((one[0], two[0]), (200, 200))
        self.assertEqual(names(one), {"SPEC-aaaa", "SPEC-bbbb", "SPEC-cccc"})
        self.assertEqual(names(two), {"SPEC-aaaa", "SPEC-bbbb", "SPEC-cccc", "SPEC-dddd"})
        self.assertEqual((one[1]["data"]["scope"], one[1]["schema"]), ("bead:SPEC-bbbb", "nogg.dashboard.graph/v1"))
        self.assertEqual(self.get("/api/v1/graph?scope=bead:SPEC-nope")[1]["data"]["nodes"], [])

    def test_the_ready_frontier_through_the_api(self):
        self.loaded([bead("SPEC-aaaa"), bead("SPEC-bbbb", "SPEC-aaaa"), bead("SPEC-cccc", status="in_progress"),
                     bead("SPEC-dddd", labels=["openspec:change:other"])], ready=["SPEC-aaaa", "SPEC-dddd"])
        status, doc = self.get("/api/v1/graph?scope=ready")
        self.assertEqual(status, 200)
        self.assertEqual({node["id"]: node["status"] for node in doc["data"]["nodes"]},
                         {"SPEC-aaaa": "ready", "SPEC-dddd": "ready"})
        self.assertEqual(doc["data"]["total"], 2)

    def test_the_depth_is_part_of_the_cache_key_for_a_neighbourhood_only(self):
        self.loaded([bead("SPEC-aaaa"), bead("SPEC-bbbb", "SPEC-aaaa"), bead("SPEC-cccc", "SPEC-bbbb")])
        with mock.patch.object(graph, "graph_view", wraps=graph.graph_view) as view:
            for path in ("scope=bead:SPEC-aaaa&depth=1", "scope=bead:SPEC-aaaa&depth=2", "scope=bead:SPEC-aaaa&depth=2",
                         "scope=ready", "scope=ready&depth=3", PATH[len("/api/v1/graph?"):], PATH[len("/api/v1/graph?"):] + "&depth=4"):
                self.assertEqual(self.get("/api/v1/graph?" + path)[0], 200)
            self.assertEqual(view.call_count, 4)      # depth 1, depth 2, ready, the change

    def test_a_malformed_query_is_refused_and_says_nothing_back(self):
        self.loaded([bead("SPEC-aaaa")])
        for query in ("", "?scope=", "?scope=change:%2e%2e%2fetc", "?scope=change:demo&closed=maybe",
                      "?scope=bead:", "?scope=bead:a/b", "?scope=bead:SPEC-aaaa&depth=0", "?scope=bead:SPEC-aaaa&depth=x"):
            status, doc = self.get(f"/api/v1/graph{query}")
            self.assertEqual((status, doc["data"]), (400, {"error": "bad_request"}), query)

    def test_each_scope_and_mode_gets_its_own_answer(self):
        self.loaded([bead("SPEC-aaaa", status="closed"), bead("SPEC-bbbb", "SPEC-aaaa"),
                     bead("SPEC-cccc", labels=["openspec:change:other"])])
        kinds = lambda path: sorted(node["kind"] for node in self.get(path)[1]["data"]["nodes"])
        self.assertEqual(kinds(PATH), ["bead", "bead"])
        self.assertEqual(kinds(PATH + "&closed=collapse"), ["bead", "group"])
        self.assertEqual(kinds("/api/v1/graph?scope=change:other"), ["bead"])

    def test_a_layout_is_built_once_per_generation_and_follows_a_change(self):
        refresher = self.loaded([bead("SPEC-aaaa"), bead("SPEC-bbbb", "SPEC-aaaa")])
        with mock.patch.object(graph, "graph_view", wraps=graph.graph_view) as view:
            first = self.get(PATH)[1]
            refresher.cells["beads"].due = 0.0            # the same data read again
            self.load(refresher)
            self.assertEqual(self.get(PATH)[1]["sources"]["beads"]["generation"],
                             first["sources"]["beads"]["generation"])
            self.assertEqual(view.call_count, 1)
            self.answer("list", [bead("SPEC-aaaa")])
            refresher.cells["beads"].due = 0.0
            self.load(refresher)
            self.assertEqual(self.get(PATH)[1]["data"]["edges"], [])
            self.assertEqual(view.call_count, 2)

    def test_a_graph_request_spawns_nothing(self):
        self.loaded([bead("SPEC-aaaa")])
        before = len(self.calls())
        self.get(PATH)
        self.assertEqual(len(self.calls()), before)


if __name__ == "__main__":
    unittest.main()
