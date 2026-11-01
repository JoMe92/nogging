## Context

Brief: `.nogging/state/incoming/dashboard-brief.md`, approved by the Product Owner on 2026-11-01.
Epic SPEC-6puu (GitHub #283). Epic SPEC-hg53 (Gantt and board) reuses the data layer later.

Measured on the delivery host, a Raspberry Pi 5, on 2026-11-01:

| Read | Time | Size |
|---|---|---|
| `bd list --all --json --limit 0` | 0.7 s | 1.75 MB, 673 Beads |
| `bd show <id> --json`, `bd dep cycles --json` | 0.3 s, 0.5 s | |
| `nogg test report --json` | 2 s | 3 KB |
| `token_usage_report.bead_git_lines` for all Beads | 11.6 s | 835 commits over 99 refs |
| `nogg token-usage report --group-by bead --json` | 21 s | 319 KB, 17,156 usage events |
| `scripts/nogg` start alone | 2.2 s | |

So a request cannot read its sources: a page view would take half a minute. The readers are
Python, and `scripts/nogg` injects them into pure modules already (`token_usage_command`).

Beads carry 386 `blocks`, 3 `discovered-from`, 1 `related` and 1 `parent-child` edges. 563 Beads
have exactly one `openspec:change:<id>` label and 110 have none. There are 5 epics but only one
`parent-child` edge, so "change or epic" in practice means the change label.

JavaScript has no test runner here: `scripts/test` runs bash and `*_test.py`, offline. Logic that
needs tests therefore belongs in Python, and the client stays a thin renderer.

## Goals / Non-Goals

**Goals:** statistics, Bead table and detail, scoped graph; desktop and phone; read-only; honest gaps;
fast on a Pi 5; a data layer that SPEC-hg53 can reuse.

**Non-goals:** any write action, TLS, Internet exposure, a service unit, multi-repository views,
historical data sync across hosts, Gantt and board.

## Decisions

### Decision 1: Test and execution discipline

Tests follow `docs/testing-policy.md`. Small tests cover pure logic: bind policy, token and cookie,
Host and Origin rules, redaction, metrics, layout. Medium tests start a real server on `127.0.0.1`
with port 0 and a stub `bd` that records argv and environment. No test sleeps: the cache takes an
injected clock, and tests wait on events with a bounded timeout. Tests need no Dolt and no real `bd`.

`scripts/test` only finds `*.test.sh`, so DSH-001 adds `scripts/dashboard.test.sh`, which runs every
`scripts/lib/dashboard_*_test.py` by glob and skips them in an installed copy, the pattern of
`scripts/session-wake-digest.test.sh`. A later Bead adds a `_test.py` file with no wiring.

JavaScript gets no unit tests: layout, metrics and redaction are server-side, so the client holds
little logic. Interaction is covered in the acceptance of TASK-DSH-011. One deliberate source-text
check exists: with no JS runner, a small test scans `scripts/dashboard/` for `innerHTML`-like sinks.

### Decision 2: A Python server inside `scripts/nogg dashboard`

The server runs in-process as a foreground `scripts/nogg dashboard`, on the standard library's
`ThreadingHTTPServer`. `dashboard_command(args)` in `scripts/nogg` passes a `readers` dict of
callables to `dashboard_server.serve()`, the same pattern as `token_usage_command`. Node was
rejected, because every reader is Python and a CLI subprocess costs 2.2 s per call.

| Module under `scripts/lib/` | Responsibility |
|---|---|
| `dashboard_security.py` | Pure: bind policy, token, cookie, Host and Origin rules, headers |
| `dashboard_server.py` | Handler, route table, static map, limits, lifecycle |
| `dashboard_cache.py` | Source cells and the refresher, with an injected clock |
| `dashboard_sources.py` | Effects: `bd`, session and test loaders |
| `dashboard_slow_sources.py` | Effects: Git and token loaders |
| `dashboard_model.py` | Pure: allow-lists, scrubbing, joins, Bead list and detail |
| `dashboard_metrics.py` | Pure: start-page statistics |
| `dashboard_graph.py` | Pure: scoping, layout, longest chain |

The server sets `sys.dont_write_bytecode` and reads the canonical checkout through
`canonical_repository_state`, not the worktree `ROOT`. Static files live in `scripts/dashboard/`.

### Decision 3: Bind policy

The check is pure, in `dashboard_security.check_bind(value)`:

1. Parse with `ipaddress.ip_address` (`%zone` split first). A hostname is refused, `localhost`
   included, because resolving one adds split-horizon and time-of-check cases.
2. Refuse `0.0.0.0` and `::` without expanding them: a wildcard covers future public interfaces.
3. Refuse IPv4-mapped addresses instead of unwrapping them.
4. Accept only membership in the explicit list of the spec.
5. Never use `is_private` or `is_global`: their meaning changed across patch releases and CGNAT is
   not `is_private`. The list also rejects 6to4, NAT64 and multicast with no special case.

`IPV6_V6ONLY=1` is set, and `bind()` itself proves the address is local. `--list-binds` parses
`ip -j addr` as a hint only, because the standard library cannot enumerate IPv6 addresses. A
`100.64.0.0/10` address on an interface not named `tailscale*` prints a warning, since it may be
carrier NAT. There are no `--bind tailscale` or `--bind lan` helpers: an explicit address is the
explicit act the brief asks for. The peer address is rechecked in `verify_request`, which catches
DNAT forwards that keep a public source address. It cannot see SNAT, `ssh -R` or a reverse proxy;
there the Host check and the token are the remaining defences, and the docs say so.

A non-loopback bind is refused inside a supervised session (`calling_session_record`): session logs
must not capture the link, and network exposure stays an operator act.

### Decision 4: Token and browser session

- **Secret:** `secrets.token_urlsafe(32)` in `<state>/dashboard/secret`, created with `O_EXCL`, mode
  `0600` in a `0700` directory. It persists, otherwise each restart logs the phone out.
- **Link:** `http://<addr>:<port>/#token=<secret>`. The fragment never reaches a server, a log or a
  `Referer`. `auth.js` reads it, calls `GET /api/v1/auth` with `Authorization: Bearer`, then removes
  it with `history.replaceState`. The API stays GET-only.
- **Cookie:** `nogg-dash-<port>`, value `<expiry>.<hmac>`, an HMAC under the secret, so the secret is
  not replayed and rotation invalidates all cookies. `HttpOnly; SameSite=Strict; Path=/;
  Max-Age=2592000`. `Secure` cannot be set on plain HTTP.
- **Comparison:** `hmac.compare_digest` on bytes, because non-ASCII `str` raises on Python 3.9.
- **Rate limit:** ten failures per minute globally, then 429. 256 bits make guessing impractical;
  this only reduces noise.
- **QR:** only when `qrencode` is on `PATH` and stdout is a terminal, with the link on stdin.

**No token on loopback**, as the brief decides. The cost: another user account on the same host can
read the dashboard on its loopback port. Nogging's supported hosts are single-operator. See *Decisions
for the Product Owner*.

### Decision 5: Request and response rules

As in the spec's Host, Origin, method, header and limit requirements. Notes on the mechanism:

- `verify_request` runs before a thread starts. A 16-slot semaphore answers a canned 503 when full.
- HTTP/1.0 keeps no idle thread. The socket timeout alone does not stop a slow client, so `rfile` is
  wrapped with a read deadline and a byte budget.
- Assets load into memory at start into a fixed map, so a request cannot name a path.
- The shell, the assets and the unauthorized page need no session and hold no data.
- Trusted Types in the CSP enforces the text-only rule where the browser supports it.
- Precomputed gzip uses `mtime=0`. BREACH does not apply, since no response reflects a secret.

### Decision 6: One refresher, immutable snapshots

One daemon thread runs the sources strictly in turn. Request threads read a snapshot and record
demand, so a request never starts a subprocess and ten phones cannot pile up `bd` calls.

| Source | Interval | Change gate |
|---|---|---|
| `beads` (with ready and cycles) | 30 s | none |
| `sessions` | 30 s | directory mtime |
| `tests` | 120 s | `runs.jsonl` size and mtime |
| `git` | 10 min | hash of `git for-each-ref`; numstat cached per immutable SHA |
| `tokens` | 15 min | `last_success_at` in `collector/status.json` |

Sources fill in that order after start. A source keeps one snapshot, swapped atomically, plus
precomputed JSON and gzip bytes. Raw token facts are dropped once reduced. The graph cache is an LRU
of 32 entries, reset per generation. Nothing is written to disk: a disk cache would copy notes out of
their present protection. After 5 minutes with no request the thread idles. The refresh order means
Beads can go stale for the length of the longest slow source; that bound is accepted.

The client polls `/api/v1/freshness` every 10 s while the tab is visible and refetches a view when
its sources' `generation` changes.

### Decision 7: The process adds no state

"Read-only" here means the dashboard adds no Beads, facts, commits or configuration. It does not
mean no file is touched: a `SELECT` on an embedded Dolt store can change `manifest` and `journal.idx`,
and the `dolt` CLI writes event files outside the repository. The requirement is worded accordingly.

`dashboard_command` forces `BEADS_DOLT_AUTO_START=0`, because a plain `bd` call can otherwise start
Dolt, plus `GIT_OPTIONAL_LOCKS=0` and `DOLT_DISABLE_EVENT_FLUSH=1`. Every `bd` call is
`bd --readonly --sandbox …` with a 30 s timeout. `doctor` is never called: it writes a sentinel.
`Collector` is not used, because `_dir()` creates directories.

A failure classifies as `dolt_unreachable`, `bd_absent` or `bd_error`, with stderr text used only to
classify and falling back to `bd_error`. The client shows "Dolt is unreachable. On the host, run
`bd dolt start`." There is never a control for it.

### Decision 8: The token read lease

On a scratch Dolt 2.3.1 repository, a running `SELECT` made a concurrent `INSERT` and `dolt add` fail
in 0.4 s with `cannot update manifest: database is read only`. `token_usage_collect.py:334-340`
quarantines a batch after three failures, so a periodic dashboard read would make losing a batch from
the pending set far more likely. The scratch repository is not the live 1.4 GB store, so the
mechanism below is a design that TASK-DSH-004 proves with a medium test.

`token_usage_store.read_lease()` is a new context manager: open `collector.lock` with `O_RDONLY`,
with no `mkdir`, `chmod` or `O_CREAT`; take `LOCK_SH | LOCK_NB`. If busy, keep the stale snapshot and
retry on the next tick. If missing, report `absent`. `Store.locked()` stays untouched. The change gate
cannot be `.dolt/noms/manifest`, because a read can touch it. A blocking `Store.locked()` now waits
for the lease, which delays `session stop` (`scripts/nogg:6865`) by about 9 s on this host, and the
whole read is capped at 45 s. The lease does not fix the same collision for a manual
`nogg token-usage report`.

### Decision 9: Data contracts

These contracts let the parallel Beads build against fixtures. A change after TASK-DSH-001 merges
needs a discovery note.

**Envelope.** Every API response is `{"schema": "nogg.dashboard.<name>/v1", "as_of": <iso>,
"sources": {<source>: {"state": <state>, "as_of": <iso|null>, "generation": <int>}}, "data": …}`.

**Routes.** All GET and HEAD. Unbuilt routes answer 501 until their owner lands.

| Route | Owner | `data` |
|---|---|---|
| `/`, `/assets/<fixed>` | DSH-001 | data-free shell and assets |
| `/api/v1/auth` | DSH-001 | `{}`, sets the cookie |
| `/api/v1/freshness` | DSH-003 | the `sources` block only |
| `/api/v1/beads` | DSH-003 | `dashboard_model.bead_list` |
| `/api/v1/changes` | DSH-003 | `dashboard_model.change_list` |
| `/api/v1/beads/<id>` | DSH-006 | `dashboard_model.bead_detail` |
| `/api/v1/summary` | DSH-007 | `dashboard_metrics.summary_view` |
| `/api/v1/graph?scope=change:<id>\|bead:<id>\|ready&depth=<n>&closed=show\|collapse` | DSH-009 | `dashboard_graph.graph_view` |

**Reader snapshots.** Readers return plain data, always with timestamps as UTC ISO strings:

- `beads`: `{"beads": [<allow-listed Bead>], "ready": [<id>], "cycles": [[<id>]]}`
- `sessions`: `{"sessions": [<allow-listed session>], "floor": <iso|null>}`
- `tests`: `{"records": [{"bead", "stage", "at", "seconds", "status"}], "stage_seconds": {<bead>: {<stage>: <s>}}, "floor": <iso|null>}`
- `git`: `{"commits": [{"sha", "at", "subject", "beads": [<id>], "production_lines", "test_lines"}], "root_commit_at": <iso>, "floor": <iso|null>, "tokenless_commits": <int>}`
- `tokens`: `{"by_bead": {<bead>: <work>}, "by_day": {<day>: {<runtime>: <work>}}, "by_model": {<model>: <work>}, "floors": {<runtime>: <iso>}, "partial": [<runtime>], "pending_batches": <int>}`

`<work>` is the existing `work` shape of `token_usage_report`, including `unknown_counters`.

**Allow-listed Bead.** `id, title, status, priority, issue_type, labels, description, notes,
close_reason, parent, created_at, started_at, closed_at, updated_at, dependency_count,
dependent_count, dependencies`, with entries limited to `issue_id, depends_on_id, type, created_at`.
The list form also omits `description`, `notes` and `close_reason`, and adds `change`, the value of
the `openspec:change:` label or null, and `ready`.

**Allow-listed session.** `name, agent, requested_model, reasoning_effort, selection_tier, role,
bead_id, planning_id, state, started_at, ended_at, exit_reason`.

Scrubbing is best effort, and the docs say so. 2 descriptions, 8 notes and 1 token-like string on this
host would match.

**Graph.** `{"scope", "nodes": [{"id", "kind": "bead"|"ghost"|"group", "title", "status", "x", "y",
"layer", "lane", "critical", "count"}], "edges": [{"from", "to", "points": [[x, y]], "critical",
"reversed"}], "layers": <int>, "total": <int>, "hidden": <int>, "cycles": [[<id>]], "critical_path":
[<id>]}`. Coordinates are in abstract units, so the client scales for desktop and phone node sizes.

### Decision 10: Metric definitions

| Metric | Definition | Honest gap |
|---|---|---|
| Cycle time, primary | `closed_at - started_at`, median and p90 | Excludes and counts Beads with no `started_at` (14 here) |
| Lead time | `closed_at - created_at` | Includes queue time; open Beads excluded |
| Reopened Beads | Latest close only | The list has no reopen history; the docs say so |
| Agent-hours | Sum of `ended - started` | Parallel sessions add up, so never called elapsed time |
| Orchestrator hours | Reported separately | 372 of 1,198 h here |
| Running sessions | Shown as "N running" | Excluded from the sum |
| Planning sessions | Count in agent-hours | `bead_id` is null, so in no Bead's detail |
| Project age | Root commit author date; first Bead `created_at` | |
| Closed per day or week | Raw `closed_at`, bucketed in the browser | 110 Beads read "no change" |
| Tokens, headline | `fresh_input + output`, "Known: …" | `+?` with unknown counters; never `provider_total_tokens`; no cost, no quota percent |
| Models | Sessions give requested model, usage gives observed model | Labelled apart; Pi and agy partial |
| Commits and lines | `bead_commit_map`: all refs, rebased copies once | May include unmerged work; commits with no Bead token shown as a count |
| Test cost | `stage_seconds`, `bead_test_changes` | Floor reads "records kept from", since rotation moves it |

The brief's "567 session records" counts differently from `session_records()` on the canonical
directory, which gives 391; the dashboard uses `session_records()` and states its own count.

Two extensions are needed. `report()` adds `work` only for `group_by=bead`
(`token_usage_report.py:507-508`), so day and model views need an additive pure function reusing
`Model`, `fresh_input` and `add_work`. `report()` needs an explicit whole-history window, since its
default is the current UTC day. `bead_git_lines` returns counts only, so `bead_commits()` is added and
`bead_git_lines` is derived from it, unchanged for its callers.

### Decision 11: Layout on the server

`dashboard_graph.py` is pure Python and cached per generation. The client only draws SVG and handles
pan, zoom and tap. A client-side layout could not be tested here.

1. **Scope.** Build the subgraph, with a hard cap of 80 visible nodes. Collapse closed Beads into
   `group` nodes first, then report `hidden`.
2. **Edges.** Only `blocks` affect layout, oriented blocker to blocked. Other types appear in detail.
3. **Cycles.** Iterative DFS in sorted ID order. Reverse back-edges, mark them, draw them dashed. The
   banner comes from `bd dep cycles`, so layout does not depend on it.
4. **Layers.** Longest-path layering, then move each source next to its nearest successor. Insert
   dummy nodes on long edges.
5. **Crossings.** Barycenter sweeps, at most 4 down-and-up pairs, keep the best, stop early when
   nothing improves, break ties by ID.
6. **Coordinates.** 2 to 4 priority-median sweeps, with dummies first. Brandes-Köpf adds hundreds of
   lines for little gain at this size.
7. **Components.** Lay out each weakly connected component alone and stack them, largest first.
   Isolated nodes form a compact final group.
8. **Longest chain and lanes.** The longest `blocks` chain by node count over non-closed Beads, or
   over all Beads when the change is finished. Ties break by `[~N loc]` sum, then ID. Only 17 Beads
   carry an estimate, so size cannot be the main weight. It is pinned to the top lane, and further
   lanes come from repeatedly taking the longest remaining chain.

Tests assert properties, not coordinates: forward edges, no overlap, determinism, termination on
cycles and self-loops, the chain, and an 80-node fixture.

### Decision 12: Static structure and ownership

Hash routes, so the server needs no fallback: `#/`, `#/beads?…`, `#/graph?scope=&id=`, and `bead=<ID>`
on any route opens the one detail component. `index.html` lists every script and stylesheet from the
start, so a later Bead never edits it.

| Owner | Files under `scripts/dashboard/` |
|---|---|
| DSH-001 | `index.html`, `auth.js`, `images/`, `fonts/` with `OFL.txt`, empty stubs of every other file |
| DSH-002 | `tokens.css`, `base.css`, `theme.js`, `dom.js`, `format.js`, `app.js` |
| DSH-005 | `table.js`, `views/beads.js`, `views/beads.css` |
| DSH-006 | `views/detail.js`, `views/detail.css` |
| DSH-007 | `charts.js`, `views/start.js`, `views/start.css` |
| DSH-008 | `views/start-usage.js` |
| DSH-009 | `graph/render.js`, `graph/graph.css` |
| DSH-010 | `graph/interact.js`, `graph/scope.js`, `graph/list.js` |

`app.js` defines `registerView(name, module)`, `openDetail(id)` and the panel state contract
(`loading`, `ready`, `gap`, `empty`, `error`). A view owner touches only its own files and does not
edit shared CSS. A new shared token goes through a discovery note.

### Decision 13: Conflict-free parallel work

- **`scripts/nogg`, `manifest.js`, `package.json`:** only DSH-001 edits them. It registers every
  module, creates docstring-only stubs so the manifest test passes, injects every reader and adds a
  route table with named functions. Unbuilt routes answer 501.
- **`docs/dashboard.md`:** DSH-001 creates it with fixed headings, and each Bead fills only its own.
- **`CHANGELOG.md`:** one entry in DSH-001, finalised in DSH-011.
- **Forced order:** DSH-001 before everything. An envelope change after it touches every view.

### Decision 14: Packaging and doctor

`{ from: 'scripts/dashboard', to: 'scripts/dashboard' }` joins `verbatimDirs`, and `scripts/dashboard`
joins `files`. `bin/lib/fsops.js` copies through Buffers, so woff2 stays intact. Fonts and logo are
copies from `docs/assets/`, since `docs/assets` is not packaged and Nogging has no build step. A small
drift check compares them, `OFL.txt` ships beside them, and `THIRD_PARTY_NOTICES.md` names them.

`doctor` stays silent when unused: no required tool, no config key, nothing in
`templates/nogging-config.json`, no port probe, no unit. Its single conditional check warns when the
secret exists with a mode wider than `0600`.

### Decision 15: Visual system

Tokens come from `docs/_sass/color_schemes/nogging*.scss`. Poppins is for headings and navigation, a
system font for body and a mono font for IDs and SHAs, as in the docs. Theme is System, Light or Dark
under `nogging-theme` in `localStorage`, set by a blocking external `theme.js`, because the CSP forbids
the docs' inline head script.

| Breakpoint | Width | Grid |
|---|---|---|
| Phone | under 600 | 1 column, 16 px gutter, bottom tab bar |
| Tablet | 600 to 959 | 2 columns, 24 px |
| Desktop | 960 to 1439 | 12 columns, 24 px, header tabs |
| Wide | 1440 and up | 12 columns, maximum 1600 px |

Spacing 4, 8, 12, 16, 24, 32, 48. Type 12, 14, 16, 20, 24, 32; body 16 on phone and 14 on desktop.

| Token | Light | Dark |
|---|---|---|
| `--bg` | #F6F6F4 | #141B13 |
| `--surface` | #EEF2EC | #1D261C |
| `--surface-2` | #E9EDE6 | #283527 |
| `--hover` | #E1E7DD | #313F2F |
| `--text` | #22301F | #E6EBE3 |
| `--text-2` | #4A5B4C | #B8C9B3 |
| `--link` | #3D5C3A | #A9C3A2 |
| `--accent`, `--focus` | #5E7D5E | #97B190 |
| `--control-border` | #5E7D5E | #7E9C7E |
| `--border` | #CCD6C8 | #33402F |
| `--btn` | #3D5C3A | #3D5C3A |
| `--selection` | #97B190 | #3D5C3A |
| `--warn-bg` | #FAF3E6 | #2A2215 |
| `--warn-border` | #E3CB98 | #5A4520 |
| `--warn-text` | #8C5A00 | #E8B45A |
| `--note-bg` | #EEF2EC | #1C2A1B |
| `--note-border` | #B9C9B4 | #3A4A37 |
| `--error-bg` | #FBEDEE | #2C1A1A |

| Status | Light | Dark | Shape |
|---|---|---|---|
| `open` | #1F5FA8 | #8DBBEA | Hollow circle, solid border |
| `ready`, derived | #3D5C3A | #A9C3A2 | Right-pointing triangle, solid border |
| `in_progress` | #8C5A00 | #E8B45A | Half-filled circle, thick border |
| `blocked` | #A40E26 | #FFA198 | Octagon with bar, thick border |
| `deferred` | #6A4A78 | #C9A8D6 | Diamond, dashed border |
| `closed` | #4A5B4C | #B8C9B3 | Check in square, thin border, faded |

| Agent series | Light | Dark | Pattern |
|---|---|---|---|
| Claude | #B85C00 | #F0A45D | Solid |
| Codex | #1F5FA8 | #8DBBEA | Diagonal hatch |
| Pi | #00796B | #5CCFBC | Dots |
| agy | #8E3F8E | #D9A0D9 | Crosshatch |
| Unknown | #4A5B4C | #B8C9B3 | Horizontal lines |

The stored agent `antigravity` displays as `agy`. Priority is text `P0` to `P4`: P0 a filled blocked
chip, P1 an outlined chip, P2 to P4 plain. A small test recomputes contrast from `tokens.css`, as
`scripts/docs-site.test.sh` does for the docs: 4.5:1 for text, 3:1 for controls and marks.

### Decision 16: The views

**Shell.** Desktop: 56 px header with mark, project name, three tabs, search, freshness chip, a
"Read-only" badge and the theme control. Phone: 48 px header, a freshness dot that opens a sheet, and
a fixed bottom tab bar of Overview, Beads and Graph with safe-area padding.

**Start page.** Range 7d, 30d, 90d, All (default 30d) and group Day or Week, both in the URL. Panels
in order: 1 Beads by status (tiles that link to the filtered table), 2 project age, 3 closed over time,
4 closed by change (top 10 plus Other), 5 cycle and lead time (histogram with median and p90), 6
activity timeline, 7 agent-hours, 8 agents, models and tiers, 9 token usage, 10 commits and changed
lines, 11 test cost. Panels 1 to 6 belong to DSH-007 and 7 to 11 to DSH-008. Each panel has a title,
freshness text and a Table toggle. A gap is a hatched band with "No data before {date}", never a zero
bar. A tap or hover selects a bucket and its values appear in a fixed readout below the chart. Chart
buckets are UTC days, labelled so; timestamps show in browser local time.

**Table.** Default filter is active Beads, sorted by priority, then updated. Desktop columns: ID,
status, priority, type, title (two-line clamp), change, updated, age. Phone: three-line cards and a
"Filters (n)" bottom sheet. Client-side paging at 50 rows; virtual scroll would complicate focus and
screen readers.

**Detail.** A 480 px focus-managed right panel on desktop, full screen on a phone. Order: header,
description, notes clamped to 12 lines with "Show all", dependencies by direction with "Open in graph",
labels, commits, sessions, tokens, test cost. Text uses `white-space: pre-wrap`. Linkifying builds
nodes with `createElement` and matches only known Bead IDs and SHAs of this Bead's commits, never a
URL. Null fields read "Not recorded". `assignee` is hidden everywhere.

**Graph.** Default scope is the ready frontier: small and actionable. Nodes are 200 by 64 on desktop
and 148 by 56 on a phone, with shape, mono ID and title, the `TASK-XXX-001: [tier]` prefix removed for
display only. Edges are 1.5 px with arrowheads, dotted when both ends are closed; the longest chain
3 px `--accent`. Closed nodes sit at 55 % opacity with a full-contrast label.

| Input | Behaviour |
|---|---|
| Mouse | Drag pans, click selects, wheel zooms at the cursor |
| Touch | One finger pans, pinch zooms, tap selects, double-tap zooms 2× |
| Keyboard | Arrows move between nodes, Shift+arrows pan, +/- zoom, 0 fits, Enter opens |
| Buttons, 44 px | Zoom in, zoom out, Fit |

Pointer Events. The route fills the viewport between header and tab bar, so `touch-action: none` on
the canvas cannot trap page scroll. In phone portrait the flow stays left to right: the first view
fits the height and frames the first layer with non-closed nodes, and a "Layer 2 of 7" stepper pans one
layer at a time. A Graph or List toggle shows an ordered list in topological order, each item with
status and "Blocked by: …".

**States.** `bd` unreachable: a full page with Retry, which refetches and starts nothing on the
server. A failed slow source: that panel only. No session: a static page, "Open the access link from
the host again. Run `nogg dashboard` there to get it." Server unreachable: a banner, "Server not
reachable. Showing data from 12:04." Data older than 5 minutes: "Data may be stale, last update 12:04".
Plain HTTP on a non-loopback address: "Unencrypted connection".

**Accessibility.** Landmarks, a skip link, real `<table>` with `aria-sort`, a polite live region for
freshness, keyboard with no traps, focus returned to the trigger, `prefers-reduced-motion`,
`prefers-color-scheme`, `prefers-reduced-data` (no Poppins, no auto-refresh), and usable at 200 % zoom
and 320 px.

## Risks / Trade-offs

- **Plain HTTP on a LAN.** The token keeps other devices out, but a sniffer on a shared Wi-Fi can read
  notes and replay the cookie for up to 30 days. That falls short of the brief's Wi-Fi goal. Tailscale
  encrypts the traffic and is the recommended phone path. A LAN bind prints a warning and the UI shows a
  notice. TLS would need certificates that a phone trusts, which is out of scope for step 1.
- **Lease delays `session stop`.** About 9 s here, 45 s at worst. Accepted: it is rare, and losing
  usage facts is worse.
- **Existing collision.** `MAX_ATTEMPTS` is commented "data-specific failures", yet it also counts
  outage-class errors and quarantines on the third. A manual `token-usage report` can already hit this.
  Out of scope here, and reported to the operator for a follow-up.
- **GIL.** JSON and aggregation on the refresher thread slow requests. Precomputed bytes limit this.
- **Contract drift.** Parallel Beads build on Decision 9, so a change needs a discovery note. TASK-DSH-011
  checks the real integration.
- **JavaScript is untested.** It holds little logic, and the acceptance covers interaction.
- **All line estimates are estimates**, including the 35 s first fill.

## Decisions for the Product Owner

Planning proceeds on these defaults. Each can change without replanning the Beads.

1. **Token on loopback.** Default: none, as the brief says. The architect recommends a token on every
   bind, because another local account could read loopback data. It is a small change in DSH-001.
2. **Plain HTTP on a LAN.** Default: accepted with a warning, as stated under Risks.
3. **Lease delay on `session stop`.** Default: accepted.

## Dependencies and parallel lanes

| Bead | Depends on |
|---|---|
| TASK-DSH-001 | none |
| TASK-DSH-002 | TASK-DSH-001 |
| TASK-DSH-003 | TASK-DSH-001 |
| TASK-DSH-004 | TASK-DSH-003 |
| TASK-DSH-005 | TASK-DSH-002, TASK-DSH-003 |
| TASK-DSH-006 | TASK-DSH-002, TASK-DSH-004 |
| TASK-DSH-007 | TASK-DSH-002, TASK-DSH-003 |
| TASK-DSH-008 | TASK-DSH-004, TASK-DSH-007 |
| TASK-DSH-009 | TASK-DSH-002, TASK-DSH-003 |
| TASK-DSH-010 | TASK-DSH-009 |
| TASK-DSH-011 | TASK-DSH-005, TASK-DSH-006, TASK-DSH-008, TASK-DSH-010 |

After TASK-DSH-001, TASK-DSH-002 and TASK-DSH-003 run at once. Once both are in, TASK-DSH-004, 005, 007
and 009 run at once, followed by TASK-DSH-006, 008 and 010, and TASK-DSH-011 last.
