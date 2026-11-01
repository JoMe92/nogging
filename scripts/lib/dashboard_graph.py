"""Pure graph scoping, layout and longest chain of `nogg dashboard`.

The server computes the layout, because a client-side one could not be tested here. The
client only draws what `graph_view` returns: `x` is the layer and `y` a row, both in
abstract units, so desktop and phone scale them to their own node sizes.

Only `blocks` edges count, oriented blocker to blocked. The steps follow design Decision
11: scope, cycle breaking by iterative DFS, longest-path layering, dummy nodes on long
edges, barycenter sweeps, priority-median coordinates, components stacked largest first.
Equal input gives equal output, whatever the input order or the hash seed: every
iteration over nodes or edges here goes through a sort.

A contracted group must not invent a cycle, so groups form per layer of the whole scope
and an edge survives contraction only when it still runs forward. That is why closed
Beads collapse after layering and not before it.
"""
from __future__ import annotations

import heapq, math, re, threading
from bisect import bisect_right, insort
from collections import OrderedDict
from statistics import median
from urllib.parse import parse_qs

import dashboard_model as model

MAX_NODES = 80
MAX_GROUPS = 20
MAX_SWEEPS = 4
COORDINATE_SWEEPS = 4
COMPONENT_GAP = 1
CACHE_ENTRIES = 32
MAX_QUERY_FIELDS = 8
CLOSED_MODES = ("show", "collapse")
DUMMY = "~"                     # no Bead ID or group ID starts with it
_CHANGE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
_LOC = re.compile(r"\[~\s*(\d+)\s*loc\b")
# Which non-closed Beads stay when a scope is still above the cap after collapsing.
_STATUS_RANK = {"in_progress": 0, "blocked": 1, "ready": 2, "open": 3, "deferred": 4}


def parse_query(query):
    """(scope, closed) of a /api/v1/graph query. Anything malformed is a ValueError."""
    fields = parse_qs(query, keep_blank_values=True, max_num_fields=MAX_QUERY_FIELDS)
    if any(len(values) > 1 for values in fields.values()):
        raise ValueError("repeated field")
    scope, closed = fields.get("scope", [""])[0], fields.get("closed", ["show"])[0]
    kind, _, value = scope.partition(":")
    known = (scope == "ready" or (kind == "change" and _CHANGE.fullmatch(value))
             or (kind == "bead" and model.BEAD_ID.fullmatch(value)))
    if not known or closed not in CLOSED_MODES:
        raise ValueError("unknown scope or mode")
    return scope, closed


# --- the subgraph -----------------------------------------------------------------

def _node(identifier, kind, bead, ready):
    bead = bead or {}
    status = bead.get("status")
    estimate = _LOC.search(bead.get("title") or "")
    return {"id": identifier, "kind": kind, "title": bead.get("title"), "count": None,
            "status": "ready" if status == "open" and identifier in ready else status,
            "priority": bead.get("priority"), "loc": int(estimate.group(1)) if estimate else 0}


def _change_scope(snapshot, change):
    """({id: node}, {(blocker, blocked)}) of a change. Its Beads, plus one step of ghosts:
    the Beads outside it that block one of them or are blocked by one of them."""
    beads = {bead["id"]: bead for bead in snapshot.get("beads") or ()}
    members = {identifier for identifier, bead in beads.items() if model.change_of(bead) == change}
    blocks = set()
    for bead in beads.values():
        for entry in bead.get("dependencies") or ():
            pair = entry["depends_on_id"], entry["issue_id"]
            if entry.get("type") == "blocks" and (pair[0] in members or pair[1] in members):
                blocks.add(pair)
    ready = set(snapshot.get("ready") or ())
    ghosts = {end for pair in blocks for end in pair} - members
    nodes = {identifier: _node(identifier, "bead", beads[identifier], ready) for identifier in sorted(members)}
    nodes.update((identifier, _node(identifier, "ghost", beads.get(identifier), ready)) for identifier in sorted(ghosts))
    return nodes, blocks


# --- graph helpers ----------------------------------------------------------------

def _adjacent(ids, pairs):
    """({node: sorted successors}, {node: sorted predecessors}) within `ids`."""
    succ, pred = {node: [] for node in ids}, {node: [] for node in ids}
    for left, right in sorted(pairs):
        if left in succ and right in succ:
            succ[left].append(right)
            pred[right].append(left)
    return succ, pred


def _back_edges(ids, succ):
    """The back-edges of an iterative DFS in sorted order: a cycle cannot recurse us out."""
    state, back = {}, set()
    for root in ids:
        if root in state:
            continue
        state[root] = "open"
        stack = [(root, iter(succ[root]))]
        while stack:
            node, rest = stack[-1]
            for child in rest:
                seen = state.get(child)
                if seen == "open":
                    back.add((node, child))
                elif seen is None:
                    state[child] = "open"
                    stack.append((child, iter(succ[child])))
                    break
            else:
                state[node] = "done"
                stack.pop()
    return back


def _orient(ids, blocks):
    """{(left, right, turned)}: the layout direction of each `blocks` edge. `turned` marks
    a back-edge, which runs right to left when drawn, and a self-loop, left == right."""
    succ, _ = _adjacent(ids, {pair for pair in blocks if pair[0] != pair[1]})
    back = _back_edges(ids, succ)
    return {(right, left, True) if left == right or (left, right) in back else (left, right, False)
            for left, right in blocks}


def _topological(ids, succ):
    pending = {node: 0 for node in ids}
    for node in ids:
        for child in succ[node]:
            pending[child] += 1
    waiting = sorted(node for node, count in pending.items() if not count)
    order = []
    while waiting:
        node = heapq.heappop(waiting)
        order.append(node)
        for child in succ[node]:
            pending[child] -= 1
            if not pending[child]:
                heapq.heappush(waiting, child)
    return order


def _layers(order, succ, pred):
    """Longest-path layers, then each source moved next to its nearest successor."""
    layer = {}
    for node in order:
        layer[node] = 1 + max((layer[parent] for parent in pred[node]), default=-1)
    for node in order:
        if succ[node] and not pred[node]:
            layer[node] = min(layer[child] for child in succ[node]) - 1
    return layer


def _longest(order, pred, allowed, nodes):
    """The longest chain through `allowed` by node count, then by `[~N loc]` sum, then by
    ID. A prefix that wins stays ahead once extended, so keeping one per node is enough."""
    best = {}
    for node in order:
        if node in allowed:
            heads = [best[parent] for parent in pred[node] if parent in best]
            count, weight, path = min(heads) if heads else (0, 0, ())
            best[node] = (count - 1, weight - nodes[node]["loc"], path + (node,))
    return min(best.values())[2] if best else ()


def _critical(nodes, pairs):
    """The longest `blocks` chain over non-closed Beads, or over all Beads of a finished
    change. Ghosts and groups stay off it, and one Bead alone is no chain."""
    beads = [identifier for identifier, node in nodes.items() if node["kind"] == "bead"]
    allowed = {identifier for identifier in beads if nodes[identifier]["status"] != "closed"} or set(beads)
    ids = sorted(nodes)
    succ, pred = _adjacent(ids, pairs)
    chain = _longest(_topological(ids, succ), pred, allowed, nodes)
    return chain if len(chain) > 1 else ()


# --- the cap ----------------------------------------------------------------------

def _keep_rank(node):
    return (node["kind"] == "ghost", _STATUS_RANK.get(node["status"], len(_STATUS_RANK)),
            node["priority"] if node["priority"] is not None else 9, node["id"])


def _fit(nodes, edges, chain, collapse):
    """(visible nodes, their edges). Closed Beads collapse first, one group per layer of
    the scope, and then what still does not fit stays out: ghosts before Beads. The chain
    stays visible, so a finished change keeps it. An edge survives only when it still runs
    forward once contracted, which is what keeps the groups from inventing a cycle."""
    if not collapse and len(nodes) <= MAX_NODES:
        return nodes, edges
    ids = sorted(nodes)
    succ, pred = _adjacent(ids, {(left, right) for left, right, _ in edges if left != right})
    rank = _layers(_topological(ids, succ), succ, pred)
    closed = [identifier for identifier in ids if nodes[identifier]["kind"] == "bead"
              and nodes[identifier]["status"] == "closed" and identifier not in chain]
    floors = sorted({rank[identifier] for identifier in closed})
    span = max(1, math.ceil(len(floors) / MAX_GROUPS))
    first = {floor: floors[index - index % span] for index, floor in enumerate(floors)}
    into, groups = {}, {}
    for identifier in closed:
        into[identifier] = f"group:{first[rank[identifier]]}"
        rank[into[identifier]] = first[rank[identifier]]
        group = groups.setdefault(into[identifier], _node(into[identifier], "group", {"status": "closed"}, ()))
        group["count"] = (group["count"] or 0) + 1
    for group in groups.values():
        group["title"] = f"{group['count']} closed Bead{'' if group['count'] == 1 else 's'}"
    rest = sorted((nodes[identifier] for identifier in ids if identifier not in into and identifier not in chain),
                  key=_keep_rank)
    wanted = [*chain, *sorted(groups, key=rank.get), *(node["id"] for node in rest)][:MAX_NODES]
    visible = {identifier: nodes.get(identifier) or groups[identifier] for identifier in wanted}
    kept = set()
    for left, right, turned in edges:
        start, end = into.get(left, left), into.get(right, right)
        if start in visible and end in visible and (left == right or rank[start] < rank[end]):
            kept.add((start, end, turned))
    return visible, kept


# --- the layout -------------------------------------------------------------------

def _components(ids, pairs):
    """Weakly connected components, each a sorted list."""
    near = {node: [] for node in ids}
    for left, right in sorted(pairs):
        near[left].append(right)
        near[right].append(left)
    seen, parts = set(), []
    for root in ids:
        if root in seen:
            continue
        seen.add(root)
        part, stack = [], [root]
        while stack:
            node = stack.pop()
            part.append(node)
            fresh = [other for other in near[node] if other not in seen]
            seen.update(fresh)
            stack.extend(fresh)
        parts.append(sorted(part))
    return parts


def _lanes(order, pred, first, nodes):
    """{node: lane} and the lane count: `first` on the top lane, then repeatedly the
    longest chain of what remains. A lane holds at most one node per layer."""
    lanes, rest, chain, number = {}, set(order), first, 0
    while rest:
        chain = chain or _longest(order, pred, rest, nodes)
        lanes.update((node, number) for node in chain)
        rest.difference_update(chain)
        chain, number = (), number + 1
    return lanes, number


def _rows(part, pairs, layer, lanes):
    """The nodes per layer with dummies on long edges, and the unit segments between them.
    Returns (rows, up, down, {pair: nodes along it}). A dummy takes its source's lane."""
    rows = [[] for _ in range(max(layer[node] for node in part) + 1)]
    up, down, paths = {}, {}, {}
    for node in part:
        rows[layer[node]].append(node)
    for left, right in pairs:
        steps = [left]
        for at in range(layer[left] + 1, layer[right]):
            dummy = f"{DUMMY}{left}{DUMMY}{right}{DUMMY}{at}"
            rows[at].append(dummy)
            lanes[dummy] = lanes[left]
            steps.append(dummy)
        steps.append(right)
        paths[left, right] = steps
        for start, end in zip(steps, steps[1:]):
            down.setdefault(start, []).append(end)
            up.setdefault(end, []).append(start)
    return rows, up, down, paths


def _crossings(rows, down):
    """Edge crossings between neighbouring layers, by counting inversions."""
    total = 0
    for upper, lower in zip(rows, rows[1:]):
        at = {node: index for index, node in enumerate(lower)}
        seen = []
        for node in upper:
            ends = sorted(at[child] for child in down.get(node, ()))
            for end in ends:
                total += len(seen) - bisect_right(seen, end)
            for end in ends:
                insort(seen, end)
    return total


def _reorder(row, beside, near, pinned):
    """Sort one layer by the barycenter of its neighbours. A pinned node stays on top, a
    node with no neighbour keeps its place, and a tie breaks by ID."""
    at = {node: index for index, node in enumerate(beside)}
    place = {node: index for index, node in enumerate(row)}

    def key(node):
        ends = [at[other] for other in near.get(node, ())]
        return (node not in pinned, sum(ends) / len(ends) if ends else place[node], node)
    row.sort(key=key)


def _untangle(rows, up, down, pinned):
    """At most MAX_SWEEPS down-and-up pairs. Keep the best order, stop when none improves."""
    best, fewest = [list(row) for row in rows], _crossings(rows, down)
    for _ in range(MAX_SWEEPS):
        if not fewest:
            break
        for index in range(1, len(rows)):
            _reorder(rows[index], rows[index - 1], up, pinned)
        for index in range(len(rows) - 2, -1, -1):
            _reorder(rows[index], rows[index + 1], down, pinned)
        count = _crossings(rows, down)
        if count >= fewest:
            break
        best, fewest = [list(row) for row in rows], count
    return best


def _settle(row, y, near, pinned):
    """Move each node of a layer towards the median of its neighbours, most important
    first: the chain, then dummies, then by degree. A node is bounded by those already
    placed with room for the nodes between, so the order holds and no two come within one
    unit. The floor of a node is its index, so nothing rises above the pinned top. A wish
    snaps to a half unit, so rows stay exact and rounding can never break that distance."""
    index = {node: position for position, node in enumerate(row)}
    ranked = sorted(row, key=lambda node: (node not in pinned, not node.startswith(DUMMY),
                                           -len(near.get(node, ())), node))
    placed = {}
    for node in ranked:
        here = index[node]
        low = max((value + here - position for position, value in placed.items() if position < here), default=here)
        high = min((value + here - position for position, value in placed.items() if position > here), default=math.inf)
        wish = round(2 * median(y[other] for other in near[node])) / 2 if near.get(node) else y[node]
        y[node] = 0.0 if node in pinned else min(max(wish, low), high)
        placed[here] = y[node]


def _coordinates(rows, up, down, pinned):
    """Row positions: start from the order, then priority-median sweeps down and up."""
    y = {node: float(index) for row in rows for index, node in enumerate(row)}
    for sweep in range(COORDINATE_SWEEPS):
        near = up if sweep % 2 == 0 else down
        for row in rows if sweep % 2 == 0 else reversed(rows):
            _settle(row, y, near, pinned)
    return y


def _lay_component(part, inside, chain, nodes):
    """One component with two or more nodes and its sorted edges. Returns (place, routes,
    height, lane count)."""
    succ, pred = _adjacent(part, inside)
    order = _topological(part, succ)
    layer = _layers(order, succ, pred)
    top = chain if chain and chain[0] in part else _longest(order, pred, set(part), nodes)
    lanes, count = _lanes(order, pred, top, nodes)
    rows, up, down, paths = _rows(part, inside, layer, lanes)
    pinned = set(top)
    for start, end in zip(top, top[1:]):
        pinned.update(paths[start, end])
    for row in rows:
        row.sort(key=lambda node: (node not in pinned, lanes[node], node))
    rows = _untangle(rows, up, down, pinned)
    y = _coordinates(rows, up, down, pinned)
    place = {node: {"x": layer[node], "y": y[node], "layer": layer[node], "lane": lanes[node]} for node in part}
    routes = {pair: [(layer[pair[0]] + step, y[node]) for step, node in enumerate(steps)]
              for pair, steps in paths.items()}
    return place, routes, max(y.values()) + 1, count


def _layout(nodes, pairs, chain):
    """({id: place}, {pair: points}): components largest first, a tie broken for the one
    holding the chain and then by ID, and the isolated nodes in a compact final grid."""
    ids = sorted(nodes)
    parts = _components(ids, pairs)
    linked = sorted((part for part in parts if len(part) > 1),
                    key=lambda part: (-len(part), not (chain and chain[0] in part), part[0]))
    lonely = [part[0] for part in parts if len(part) == 1]
    place, routes, top, lane = {}, {}, 0, 0
    for part in linked:
        members = set(part)
        inside = sorted(pair for pair in pairs if pair[0] in members)
        spot, drawn, height, count = _lay_component(part, inside, chain, nodes)
        for item in spot.values():
            item["y"] += top
            item["lane"] += lane
        place.update(spot)
        routes.update((pair, [(x, y + top) for x, y in points]) for pair, points in drawn.items())
        top, lane = top + height + COMPONENT_GAP, lane + count
    width = max([1 + item["x"] for item in place.values()] + [math.ceil(math.sqrt(len(lonely)))])
    for index, node in enumerate(lonely):
        row, column = divmod(index, width)
        place[node] = {"x": column, "y": top + row, "layer": column, "lane": lane + row}
    return place, routes


# --- the view ---------------------------------------------------------------------

def _edge(left, right, turned, routes, place, on_chain):
    """One drawn edge, its points running from `from` to `to`. A self-loop has one point."""
    points = routes.get((left, right)) or [(place[left]["x"], place[left]["y"])]
    points = [[x, y] for x, y in (reversed(points) if turned else points)]
    start, end = (right, left) if turned else (left, right)
    return {"from": start, "to": end, "points": points, "reversed": turned,
            "critical": not turned and (left, right) in on_chain}


def graph_view(snapshot, scope, closed="show"):
    """`data` of /api/v1/graph (design Decision 9). `total` counts the scope's Beads and
    ghosts, `hidden` those not drawn as their own node, whether grouped or left out."""
    nodes, blocks = _change_scope(snapshot, scope.partition(":")[2])
    ids = sorted(nodes)
    edges = _orient(ids, blocks)
    cyclic = any(turned for _, _, turned in edges)
    chain = () if cyclic else _critical(nodes, {(left, right) for left, right, _ in edges})
    visible, kept = _fit(nodes, edges, chain, closed == "collapse")
    chain = tuple(node for node in chain if node in visible)
    pairs = {(left, right) for left, right, _ in kept if left != right}
    place, routes = _layout(visible, pairs, chain)
    on_chain = set(zip(chain, chain[1:]))
    marked = set(chain)
    return {"scope": scope,
            "nodes": [{"id": identifier, "kind": node["kind"], "title": node["title"], "status": node["status"],
                       "x": place[identifier]["x"], "y": place[identifier]["y"],
                       "layer": place[identifier]["layer"], "lane": place[identifier]["lane"],
                       "critical": identifier in marked, "count": node["count"]}
                      for identifier, node in sorted(visible.items())],
            "edges": sorted((_edge(*edge, routes, place, on_chain) for edge in kept),
                            key=lambda edge: (edge["from"], edge["to"], edge["reversed"])),
            "layers": 1 + max((item["x"] for item in place.values()), default=-1),
            "total": len(nodes),
            "hidden": len(nodes) - sum(node["kind"] != "group" for node in visible.values()),
            "cycles": [list(cycle) for cycle in snapshot.get("cycles") or ()],
            "critical_path": list(chain)}


class GraphCache:
    """The layouts of one Beads generation: an LRU of 32, reset when the generation moves.
    A reload that changes nothing keeps the generation, so it costs no layout."""

    def __init__(self, entries=CACHE_ENTRIES):
        self.entries = entries
        self._lock, self._generation, self._views = threading.Lock(), None, OrderedDict()

    def view(self, generation, key, build):
        with self._lock:
            if generation != self._generation:
                self._generation = generation
                self._views.clear()
            elif key in self._views:
                self._views.move_to_end(key)
                return self._views[key]
        value = build()
        with self._lock:
            if generation == self._generation:
                self._views[key] = value
                while len(self._views) > self.entries:
                    self._views.popitem(last=False)
        return value
