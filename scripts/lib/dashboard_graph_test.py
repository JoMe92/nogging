#!/usr/bin/env python3
"""Small tests of the graph layout. They assert properties, not coordinates: forward
edges, no overlap, determinism, termination on cycles and self-loops, the chain, the cap."""
from __future__ import annotations

import json, os, random, subprocess, sys, time, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_graph as graph

HERE = Path(__file__).resolve().parent
SCOPE = "change:demo"


def bead(identifier, *blockers, status="open", change="demo", title=None, priority=2, kinds=None):
    return {"id": identifier, "title": title or f"Title of {identifier}", "status": status, "priority": priority,
            "labels": [f"openspec:change:{change}"] if change else [],
            "dependencies": [{"issue_id": identifier, "depends_on_id": blocker, "type": (kinds or {}).get(blocker, "blocks"),
                              "created_at": None} for blocker in blockers]}


def view(beads, closed="show", ready=(), cycles=()):
    return graph.graph_view({"beads": beads, "ready": list(ready), "cycles": list(cycles)}, SCOPE, closed)


def ids(result, kind=None):
    return {node["id"] for node in result["nodes"] if kind is None or node["kind"] == kind}


def node(result, identifier):
    return next(item for item in result["nodes"] if item["id"] == identifier)


def edge(result, start, end):
    return next(item for item in result["edges"] if (item["from"], item["to"]) == (start, end))


def random_dag(size, edges, seed=7):
    rng = random.Random(seed)
    names = [f"N{index:03d}" for index in range(size)]
    blockers = {name: set() for name in names}
    for _ in range(edges):
        left, right = sorted(rng.sample(range(size), 2))
        blockers[names[right]].add(names[left])
    return [bead(name, *sorted(blockers[name])) for name in names]


class Layout(unittest.TestCase):
    def assert_no_overlap(self, result):
        seen = {}
        for item in result["nodes"]:
            for other in seen.get(item["x"], ()):
                self.assertGreaterEqual(abs(item["y"] - other), 1, item["id"])
            seen.setdefault(item["x"], []).append(item["y"])

    def assert_edges_go_right(self, result):
        for item in result["edges"]:
            self.assertGreater(node(result, item["to"])["x"], node(result, item["from"])["x"], item)
            xs = [point[0] for point in item["points"]]
            self.assertEqual(xs, list(range(xs[0], xs[-1] + 1)))
            self.assertEqual(item["points"][0], [node(result, item["from"])["x"], node(result, item["from"])["y"]])
            self.assertEqual(item["points"][-1], [node(result, item["to"])["x"], node(result, item["to"])["y"]])


class Geometry(Layout):
    def test_every_edge_goes_right_and_no_nodes_overlap(self):
        for seed in range(6):
            result = view(random_dag(40, 70, seed))
            self.assertFalse([item for item in result["edges"] if item["reversed"]])
            self.assert_edges_go_right(result)
            self.assert_no_overlap(result)
            self.assertEqual(ids(result), {f"N{index:03d}" for index in range(40)})

    def test_a_long_edge_runs_through_its_own_slot(self):
        result = view([bead("A"), bead("B", "A"), bead("C", "B"), bead("D", "A", "C")])
        long_edge = edge(result, "A", "D")
        self.assertEqual(len(long_edge["points"]), 4)
        for x, y in long_edge["points"][1:-1]:
            for item in result["nodes"]:
                if item["x"] == x:
                    self.assertGreaterEqual(abs(item["y"] - y), 1)

    def test_a_source_sits_next_to_its_nearest_successor(self):
        result = view([bead("A"), bead("B", "A"), bead("C", "B"), bead("D", "C"), bead("Z"), bead("E", "D", "Z")])
        self.assertEqual(node(result, "Z")["layer"], node(result, "E")["layer"] - 1)

    def test_only_blocks_edges_affect_layout(self):
        result = view([bead("A"), bead("B", "A", kinds={"A": "parent-child"})])
        self.assertEqual(result["edges"], [])

    def test_an_empty_scope_is_empty(self):
        result = view([bead("A", change="other")])
        self.assertEqual((result["nodes"], result["edges"], result["layers"], result["total"], result["hidden"]),
                         ([], [], 0, 0, 0))

    def test_no_data_yet_is_an_empty_scope(self):
        self.assertEqual(graph.graph_view({}, SCOPE)["nodes"], [])

    def test_the_contract_fields_are_all_there(self):
        result = view([bead("A"), bead("B", "A")])
        self.assertEqual(set(result), {"scope", "nodes", "edges", "layers", "total", "hidden", "cycles", "critical_path"})
        self.assertEqual(set(result["nodes"][0]), {"id", "kind", "title", "status", "x", "y", "layer", "lane", "critical", "count"})
        self.assertEqual(set(result["edges"][0]), {"from", "to", "points", "critical", "reversed"})


class Cycles(Layout):
    def test_a_cycle_terminates_marks_the_reversed_edge_and_no_chain(self):
        result = view([bead("A", "C"), bead("B", "A"), bead("C", "B"), bead("D", "C")])
        turned = [item for item in result["edges"] if item["reversed"]]
        self.assertEqual([(item["from"], item["to"]) for item in turned], [("C", "A")])
        self.assertEqual(result["critical_path"], [])
        self.assertFalse([item for item in result["nodes"] if item["critical"]])
        self.assertFalse([item for item in result["edges"] if item["critical"]])
        self.assert_no_overlap(result)

    def test_a_reversed_edge_keeps_its_true_direction_and_runs_right_to_left(self):
        result = view([bead("A", "B"), bead("B", "A")])
        turned = next(item for item in result["edges"] if item["reversed"])
        self.assertGreater(turned["points"][0][0], turned["points"][-1][0])
        self.assertEqual({(item["from"], item["to"]) for item in result["edges"]}, {("A", "B"), ("B", "A")})

    def test_a_self_loop_terminates_and_marks_no_chain(self):
        result = view([bead("A", "A"), bead("B", "A"), bead("C", "B")])
        loop = edge(result, "A", "A")
        self.assertTrue(loop["reversed"])
        self.assertEqual(loop["points"], [[node(result, "A")["x"], node(result, "A")["y"]]])
        self.assertEqual(result["critical_path"], [])

    def test_a_lone_self_loop_is_laid_out(self):
        result = view([bead("A", "A")])
        self.assertEqual((ids(result), result["critical_path"]), ({"A"}, []))

    def test_a_cycle_through_a_ghost_counts(self):
        result = view([bead("A", "G"), bead("G", "A", change="other")])
        self.assertTrue([item for item in result["edges"] if item["reversed"]])
        self.assertEqual(result["critical_path"], [])

    def test_the_output_of_bd_dep_cycles_is_reported_whatever_the_scope(self):
        result = view([bead("A")], cycles=[["X", "Y"]])
        self.assertEqual(result["cycles"], [["X", "Y"]])

    def test_a_deep_cycle_does_not_recurse(self):
        size = 3000
        beads = [bead(f"N{index:04d}", f"N{(index - 1) % size:04d}", status="closed") for index in range(size)]
        result = view(beads)
        self.assertEqual(result["total"], size)
        self.assertLessEqual(len(result["nodes"]), graph.MAX_NODES)


class Determinism(unittest.TestCase):
    def test_the_same_input_in_a_different_order_gives_the_same_result(self):
        beads = random_dag(40, 60)
        first = view(beads)
        rng = random.Random(3)
        for _ in range(5):
            mixed = [dict(item, dependencies=rng.sample(item["dependencies"], len(item["dependencies"]))) for item in beads]
            rng.shuffle(mixed)
            self.assertEqual(json.dumps(view(mixed), sort_keys=True), json.dumps(first, sort_keys=True))

    def test_the_hash_seed_does_not_change_the_result(self):
        snapshot = {"beads": random_dag(30, 45), "ready": [], "cycles": []}
        code = ("import json, sys; sys.path.insert(0, sys.argv[1]); import dashboard_graph as graph;"
                "print(json.dumps(graph.graph_view(json.load(sys.stdin), 'change:demo'), sort_keys=True))")
        answers = {subprocess.run([sys.executable, "-c", code, str(HERE)], input=json.dumps(snapshot), text=True,
                                  capture_output=True, check=True, env={**os.environ, "PYTHONHASHSEED": seed}).stdout
                   for seed in ("1", "2", "3")}
        self.assertEqual(len(answers), 1)


class LongestChain(unittest.TestCase):
    def test_the_longest_chain_is_marked_on_the_top_lane(self):
        result = view([bead("A"), bead("B", "A"), bead("C", "B"), bead("X", "A"), bead("Y", "X", "Q"), bead("Q")])
        self.assertEqual(result["critical_path"], ["A", "B", "C"])
        for name in "ABC":
            self.assertTrue(node(result, name)["critical"])
            self.assertEqual((node(result, name)["lane"], node(result, name)["y"]), (0, 0))
        self.assertTrue(edge(result, "A", "B")["critical"])
        self.assertFalse(edge(result, "A", "X")["critical"])
        self.assertFalse(node(result, "X")["critical"])

    def test_parallel_work_gets_its_own_lanes(self):
        result = view([bead("A"), bead("B", "A"), bead("C", "B"), bead("X", "A"), bead("Y", "X"), bead("P", "A")])
        self.assertEqual(node(result, "X")["lane"], node(result, "Y")["lane"])
        self.assertEqual(len({node(result, name)["lane"] for name in "BXP"}), 3)

    def test_two_equal_chains_break_by_the_loc_sum(self):
        result = view([bead("A", title="T [~10 loc]"), bead("B", "A", title="T [~20 loc]"),
                       bead("X", title="T [~200 loc: long note]"), bead("Y", "X", title="T")])
        self.assertEqual(result["critical_path"], ["X", "Y"])

    def test_two_equal_chains_with_equal_sums_break_by_id(self):
        beads = [bead("X"), bead("Y", "X"), bead("A"), bead("B", "A")]
        self.assertEqual(view(beads)["critical_path"], ["A", "B"])
        self.assertEqual(view(list(reversed(beads)))["critical_path"], ["A", "B"])

    def test_a_tie_inside_one_component_is_stable(self):
        result = view([bead("S"), bead("Q", "S"), bead("P", "S"), bead("T", "P", "Q")])
        self.assertEqual(result["critical_path"], ["S", "P", "T"])

    def test_closed_beads_are_off_the_chain_while_work_remains(self):
        result = view([bead("A", status="closed"), bead("B", "A", status="closed"), bead("C", "B", status="closed"),
                       bead("D", "C"), bead("E", "D")])
        self.assertEqual(result["critical_path"], ["D", "E"])

    def test_a_closed_bead_splits_a_chain(self):
        result = view([bead("A"), bead("B", "A", status="closed"), bead("C", "B"), bead("D", "C")])
        self.assertEqual(result["critical_path"], ["C", "D"])

    def test_a_finished_change_uses_all_beads(self):
        result = view([bead("A", status="closed"), bead("B", "A", status="closed"), bead("C", "B", status="closed")])
        self.assertEqual(result["critical_path"], ["A", "B", "C"])

    def test_ghosts_are_off_the_chain(self):
        result = view([bead("G", change="other"), bead("A", "G"), bead("B", "A"), bead("Z", "B", change="other")])
        self.assertEqual(result["critical_path"], ["A", "B"])

    def test_one_bead_alone_is_no_chain(self):
        self.assertEqual(view([bead("A"), bead("B")])["critical_path"], [])


class Components(Layout):
    def test_components_stack_largest_first_and_isolated_nodes_last(self):
        result = view([bead("A"), bead("B", "A"), bead("X"), bead("Y", "X"), bead("Z", "Y"), bead("L1"), bead("L2")])
        bottom = max(node(result, name)["y"] for name in "XYZ")
        self.assertGreater(min(node(result, name)["y"] for name in "AB"), bottom)
        self.assertGreater(min(node(result, name)["y"] for name in ("L1", "L2")), node(result, "A")["y"])
        self.assert_no_overlap(result)

    def test_many_isolated_nodes_form_a_compact_group(self):
        result = view([bead(f"I{index:02d}") for index in range(36)])
        self.assertLessEqual(result["layers"], 6)
        self.assert_no_overlap(result)
        self.assertEqual(result["edges"], [])

    def test_the_chain_stays_on_top_of_a_component_that_is_not_the_largest(self):
        result = view([bead("A", status="closed"), bead("B", "A", status="closed"), bead("C", "A", status="closed"),
                       bead("D", "A", status="closed"), bead("X"), bead("Y", "X")])
        self.assertEqual(result["critical_path"], ["X", "Y"])
        self.assertGreater(node(result, "X")["y"], node(result, "A")["y"])
        self.assertEqual(node(result, "X")["y"], node(result, "Y")["y"])


class Ghosts(unittest.TestCase):
    def test_a_bead_outside_the_change_appears_only_one_step_out(self):
        result = view([bead("FAR", change="other"), bead("G1", "FAR", change="other"), bead("A", "G1"), bead("B", "A"),
                       bead("G2", "B", change="other"), bead("FAR2", "G2", change="other"), bead("U", change="other")])
        self.assertEqual(ids(result, "bead"), {"A", "B"})
        self.assertEqual(ids(result, "ghost"), {"G1", "G2"})

    def test_edges_between_ghosts_are_left_out(self):
        result = view([bead("G1", change="other"), bead("G2", "G1", change="other"), bead("A", "G1", "G2")])
        self.assertEqual({(item["from"], item["to"]) for item in result["edges"]}, {("G1", "A"), ("G2", "A")})

    def test_a_blocker_missing_from_the_data_is_a_ghost_without_a_title(self):
        result = view([bead("A", "GONE")])
        self.assertEqual((node(result, "GONE")["kind"], node(result, "GONE")["title"], node(result, "GONE")["status"]),
                         ("ghost", None, None))

    def test_a_bead_without_a_change_is_a_ghost_of_one_that_has_it(self):
        result = view([bead("N", change=None), bead("A", "N")])
        self.assertEqual(ids(result, "ghost"), {"N"})


class Status(unittest.TestCase):
    def test_an_open_bead_that_bd_calls_ready_reads_ready(self):
        result = view([bead("A"), bead("B", "A"), bead("C", status="in_progress")], ready=["A", "C"])
        self.assertEqual([node(result, name)["status"] for name in "ABC"], ["ready", "open", "in_progress"])


class Cap(Layout):
    def scope(self, closed_count, open_count):
        rng = random.Random(11)
        names = [f"N{index:03d}" for index in range(closed_count + open_count)]
        beads = []
        for index, name in enumerate(names):
            blockers = sorted(set(rng.sample(names[:index], min(index, 2))))
            beads.append(bead(name, *blockers, status="closed" if index < closed_count else "open"))
        return beads, names

    def test_a_scope_above_the_cap_collapses_closed_beads_first(self):
        beads, names = self.scope(200, 100)
        result = view(beads)
        self.assertLessEqual(len(result["nodes"]), graph.MAX_NODES)
        self.assertEqual(result["total"], 300)
        drawn = ids(result, "bead")
        self.assertFalse(drawn & set(names[:200]))
        self.assertEqual(result["hidden"], 300 - len(drawn))
        groups = [item for item in result["nodes"] if item["kind"] == "group"]
        self.assertEqual(sum(item["count"] for item in groups), 200)
        self.assertLessEqual(len(groups), graph.MAX_GROUPS)
        self.assertFalse([item for item in result["edges"] if item["reversed"]])
        self.assert_edges_go_right(result)
        self.assert_no_overlap(result)

    def test_a_scope_at_the_cap_keeps_every_node(self):
        beads, _ = self.scope(40, 40)
        result = view(beads)
        self.assertEqual((len(ids(result, "bead")), result["hidden"]), (80, 0))

    def test_a_scope_of_open_beads_above_the_cap_reports_the_rest(self):
        beads, _ = self.scope(0, 300)
        result = view(beads)
        self.assertEqual((len(result["nodes"]), result["hidden"]), (80, 220))

    def test_active_work_outranks_waiting_work_above_the_cap(self):
        beads = [bead(f"O{index:03d}") for index in range(90)] + [bead("Z999", status="in_progress")]
        self.assertIn("Z999", ids(view(beads)))

    def test_the_longest_chain_survives_the_cap(self):
        beads = [bead(f"O{index:03d}", priority=0) for index in range(90)]
        beads += [bead("Z1", priority=4), bead("Z2", "Z1", priority=4), bead("Z3", "Z2", priority=4)]
        result = view(beads)
        self.assertEqual(result["critical_path"], ["Z1", "Z2", "Z3"])
        self.assertLessEqual(len(result["nodes"]), graph.MAX_NODES)

    def test_ghosts_leave_before_beads(self):
        beads = [bead(f"O{index:03d}", f"G{index:03d}") for index in range(70)]
        beads += [bead(f"G{index:03d}", change="other") for index in range(70)]
        result = view(beads)
        self.assertEqual(len(ids(result, "bead")), 70)
        self.assertEqual(len(ids(result, "ghost")), 10)
        self.assertEqual((result["total"], result["hidden"]), (140, 60))

    def test_a_very_long_closed_chain_stays_under_the_cap_without_a_false_cycle(self):
        beads = [bead(f"N{index:03d}", *([f"N{index - 1:03d}"] if index else []), status="closed") for index in range(300)]
        beads.append(bead("OPEN", "N299"))
        result = view(beads)
        self.assertLessEqual(len(result["nodes"]), graph.MAX_NODES)
        self.assertFalse([item for item in result["edges"] if item["reversed"]])
        self.assertIn("OPEN", ids(result))

    def test_merging_layers_invents_no_cycle(self):
        # Open work between two closed Beads of one merged group must not read as a cycle.
        beads = [bead(f"C{index:03d}", *([f"C{index - 1:03d}"] if index else []), status="closed") for index in range(60)]
        beads += [bead("OPEN", "C010"), bead("C900", "OPEN", status="closed")]
        result = view(beads, closed="collapse")
        self.assertFalse([item for item in result["edges"] if item["reversed"]])
        self.assert_edges_go_right(result)

    def test_collapse_on_request_groups_the_closed_beads(self):
        result = view([bead("A", status="closed"), bead("B", status="closed"), bead("C", "A", "B"), bead("D", "C")], closed="collapse")
        group = next(item for item in result["nodes"] if item["kind"] == "group")
        self.assertEqual((group["count"], group["status"], group["title"]), (2, "closed", "2 closed Beads"))
        self.assertEqual(ids(result, "bead"), {"C", "D"})
        self.assertEqual(result["hidden"], 2)
        self.assertTrue(edge(result, group["id"], "C"))

    def test_a_finished_change_keeps_its_chain_when_collapsed(self):
        result = view([bead("A", status="closed"), bead("B", "A", status="closed"), bead("Z", status="closed")], closed="collapse")
        self.assertEqual(result["critical_path"], ["A", "B"])
        self.assertEqual(ids(result, "bead"), {"A", "B"})

    def test_a_closed_self_loop_stays_visible_on_its_group(self):
        result = view([bead("A", "A", status="closed"), bead("B")], closed="collapse")
        self.assertEqual([item["reversed"] for item in result["edges"]], [True])

    def test_an_80_node_fixture_is_laid_out_under_one_second(self):
        beads = random_dag(80, 160)
        started = time.perf_counter()
        result = view(beads)
        self.assertLess(time.perf_counter() - started, 1.0)
        self.assertEqual(len(result["nodes"]), 80)
        self.assert_no_overlap(result)


class Query(unittest.TestCase):
    def test_a_good_query(self):
        self.assertEqual(graph.parse_query("scope=change:beads-dashboard"), ("change:beads-dashboard", "show"))
        self.assertEqual(graph.parse_query("scope=change%3Ademo&closed=collapse"), ("change:demo", "collapse"))
        self.assertEqual(graph.parse_query("scope=ready"), ("ready", "show"))
        self.assertEqual(graph.parse_query("scope=bead:SPEC-abcd&depth=2"), ("bead:SPEC-abcd", "show"))

    def test_a_bad_query_is_refused(self):
        for query in ("", "scope=", "scope=change:", "scope=nothing", "scope=change:a/b", "scope=change:..%2f",
                      "scope=bead:", "scope=bead:a%20b", "scope=ready&closed=maybe", "scope=ready&closed=",
                      "scope=ready&scope=change:a", "scope=change:" + "a" * 129, "&".join(f"x{n}=1" for n in range(9))):
            with self.assertRaises(ValueError, msg=query):
                graph.parse_query(query)


class Cache(unittest.TestCase):
    def test_a_layout_is_built_once_per_generation(self):
        cache, builds = graph.GraphCache(), []
        for _ in range(3):
            self.assertEqual(cache.view(1, "a", lambda: builds.append(1) or "one"), "one")
        self.assertEqual(len(builds), 1)
        self.assertEqual(cache.view(2, "a", lambda: "two"), "two")
        self.assertEqual(cache.view(2, "a", lambda: "three"), "two")

    def test_the_cache_is_an_lru_of_32(self):
        cache = graph.GraphCache()
        for number in range(32):
            cache.view(1, number, lambda: number)
        cache.view(1, 0, lambda: "rebuilt")          # touch the oldest, so 1 is evicted next
        cache.view(1, 99, lambda: 99)
        self.assertEqual(cache.view(1, 0, lambda: "rebuilt"), 0)
        self.assertEqual(cache.view(1, 1, lambda: "rebuilt"), "rebuilt")


if __name__ == "__main__":
    unittest.main()
