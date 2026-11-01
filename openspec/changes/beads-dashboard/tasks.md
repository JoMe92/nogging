# Tasks: read-only Beads dashboard, step 1

Dependencies are wired explicitly in Beads per the design's *Dependencies and parallel lanes*, not by
this order. Every task reads design Decision 1 and Decision 9. No Check here runs the whole suite: name
the suites in the task, and leave the rest to CI. Python tests go in `scripts/lib/dashboard_*_test.py`,
which `scripts/dashboard.test.sh` runs by glob. Medium tests use a stub `bd` and a real server on
`127.0.0.1` with port 0, with no sleeps and no Dolt. Only TASK-DSH-001 edits `scripts/nogg`,
`bin/lib/manifest.js` and `package.json`. Each task fills only its own heading in `docs/dashboard.md`.

## 1. Foundation

- [ ] TASK-DSH-001 [complex] [security] [~900 loc] `nogg dashboard` serves a secured, data-free shell on a private address.
  Per design Decisions 2 to 5, 7, 13 and 14 and the requirements on the foreground command, private
  bind, access token, one-time link, request checks, response policy, resource bounds and packaging.
  Add pure scripts/lib/dashboard_security.py and scripts/lib/dashboard_server.py. Wire a `dashboard`
  subparser into scripts/nogg with `--bind`, `--port`, `--allow-host`, `--list-binds` and
  `--rotate-token`, and `dashboard_command` that forces the process environment and injects every reader
  named in Decision 9. The route table names every route of Decision 9, answering 501 until its owner
  lands. Add scripts/dashboard/index.html listing every planned script and stylesheet, auth.js, the
  logo and fonts copied from docs/assets with OFL.txt, and empty stubs for every other file of
  Decision 12. Register all eight dashboard_*.py modules (docstring-only stubs for the others) and
  scripts/dashboard in bin/lib/manifest.js and package.json. Add the doctor secret-mode check,
  scripts/dashboard.test.sh, the skeleton of docs/dashboard.md with one heading per task and its
  Start and Access sections, the docs/security-model.md section with the plain-HTTP residual risk, a
  docs/commands.md entry, THIRD_PARTY_NOTICES.md, and a CHANGELOG entry under [Unreleased].
  Tests: small "A public address is refused", "The wildcard is refused", "A mapped or borderline
  address is refused", "A hostname is refused", "A link-local IPv6 address has no zone", the cookie
  sign, verify and expiry, constant-time compare on non-ASCII, Host and Origin decisions, "Too many
  failures"; medium "The operator starts it with defaults", "The port is taken", "A stop leaves nothing
  behind", "A request has no token on a network bind", "A wrong token is sent", "The secret is too
  open", "The token is rotated", "A loopback client", "The phone opens the link" server side, "The
  token never reaches a server log", "Output is not a terminal", "A write is attempted", "DNS
  rebinding", "A cross-site page calls the API", "Path traversal", "A slow client", "An oversized
  header", "Many clients at once", "Headers on an API response", "A supervised session asks for a
  network bind", "A forwarded public peer" with an injected peer, "Doctor on an unused install",
  "Doctor with an open secret"; small "No external reference ships".
  Check: scripts/dashboard.test.sh, new scripts/dashboard-server.test.sh, scripts/package-manifest.test.sh,
  scripts/docs-site.test.sh. Branch feat/.

## 2. Shell and data

- [ ] TASK-DSH-002 [standard] [~900 loc] The app opens with navigation, themes and live freshness on desktop and phone.
  Per design Decisions 12, 15 and 16 (Shell, States, Accessibility) and the interface requirement.
  Fill scripts/dashboard/tokens.css, base.css, theme.js, dom.js, format.js and app.js: the hash router
  with `registerView` and `openDetail`, the panel state contract, the fetch store, the 10 s freshness
  poll while visible, header, bottom tab bar, search, freshness chip and sheet, Read-only badge, theme
  control, the unencrypted notice, and the full-page and banner states. Views stay empty placeholders
  until their owners land. Text enters the DOM only as text nodes. Fill the Interface heading of
  docs/dashboard.md.
  Tests: small the contrast check parsing tokens.css for every text and status pair in both themes;
  small "Colour-blind reading" as a table check that each status has a shape class; small the scan of
  scripts/dashboard/ for `innerHTML`-like sinks of design Decision 1; medium the shell,
  assets and fonts are served with correct types by a real server. "Theme choice" and the phone layout
  are covered in the acceptance of TASK-DSH-011.
  Check: scripts/dashboard.test.sh, scripts/dashboard-server.test.sh. Branch feat/.

- [ ] TASK-DSH-003 [standard] [security] [~850 loc] Live Bead, session and test data reach the API through one refresher, with allow-lists.
  Per design Decisions 6, 7, 9 and 10 and the requirements on adding no state, the refresher, gaps,
  allow-listed fields and text. Add scripts/lib/dashboard_cache.py (source cells, interval and change
  gates, backoff, demand and idle, generation, precomputed gzip, injected clock),
  scripts/lib/dashboard_sources.py (`bd --readonly --sandbox` list, ready and cycles with a 30 s
  timeout and failure classes, session_records, read_records) and scripts/lib/dashboard_model.py
  (allow-lists, scrubber, `exit_reason` reduction, `bead_list`, `change_list`). Serve
  `/api/v1/freshness`, `/api/v1/beads` and `/api/v1/changes`. Fill the Data heading of docs/dashboard.md.
  Tests: small "One source fails", "No clients", "Nothing changed", the backoff and generation against
  an injected clock; small "An owner address", "An address in notes", "A session record", "A long exit
  reason", "A source error", "The list payload", "A Bead without a change"; medium "The first page
  load", "Many clients", "Beads are read only", "Dolt is down", "A request spawns nothing", "No
  snapshot on disk", "A repository without bd", "It runs from a linked worktree", all with a stub `bd`.
  Check: scripts/dashboard.test.sh, new scripts/dashboard-data.test.sh. Branch feat/.

- [ ] TASK-DSH-004 [complex] [~700 loc] Git attribution and token data arrive in the background without disturbing collection.
  Per design Decisions 8 and 10 and the token-read requirement. Add `read_lease()` to
  scripts/lib/token_usage_store.py, leaving `Store.locked()` untouched. Add `bead_commits()` to
  scripts/lib/token_usage_report.py and derive `bead_git_lines` from it, unchanged for its callers,
  plus an additive day and model view reusing `Model`, `fresh_input` and `add_work`. Add
  scripts/lib/dashboard_slow_sources.py with the `git` and `tokens` loaders of Decision 9: for-each-ref
  gate, numstat cached per SHA, explicit whole-history window, the 45 s cap, raw facts dropped once
  reduced, floors per runtime, `pending_batches` read without `Collector`. Fill the Usage data heading
  of docs/dashboard.md. Prove the lease on a scratch store: if a shared lease turns out not to protect
  a concurrent collection, record a blocking discovery instead of shipping a periodic read.
  Tests: small the commit dedup of rebased copies, the additive view against `report()` totals, "A
  partial runtime"; medium "A collection is running", "A collection starts during a read", "A
  repository without a store" with no directory or lock created, "Pending usage stays pending",
  "Nothing changed" on the for-each-ref gate.
  Check: scripts/dashboard.test.sh, new scripts/dashboard-usage.test.sh, scripts/token-usage.test.sh,
  scripts/packed-token-usage.test.sh, scripts/lib/token_usage_report_test.py,
  scripts/lib/token_usage_store_test.py. Branch feat/.

## 3. Views

- [ ] TASK-DSH-005 [standard] [~850 loc] The Bead table filters, sorts and searches on desktop and phone.
  Per design Decision 16 (Table) and the table requirement. Fill scripts/dashboard/table.js,
  views/beads.js and views/beads.css: columns, `aria-sort`, multi-select filters, the debounced search,
  "Include closed", URL state, paging at 50 rows, phone cards and the filter sheet. Add server-side
  shaping to `bead_list` that the view needs, such as change and label class facets. Fill the Beads
  heading of docs/dashboard.md.
  Tests: small "A filter by change" and the facet counts on the model; medium `/api/v1/beads` with a
  stub `bd` returns every facet. "The table on a phone" is covered in the acceptance of TASK-DSH-011.
  Check: scripts/dashboard.test.sh, scripts/dashboard-data.test.sh. Branch feat/.

- [ ] TASK-DSH-006 [standard] [~750 loc] Clicking a Bead shows its full evidence in one detail view.
  Per design Decision 16 (Detail) and the detail and text requirements. Add `bead_detail` in
  scripts/lib/dashboard_model.py joining the Bead with both dependency directions, commits, lines,
  sessions, tokens and test cost, each block with its own source state, and serve
  `/api/v1/beads/<id>` from the snapshots. Fill views/detail.js and views/detail.css: the right panel
  and full-screen forms, focus handling, clamped notes, session table and cards, safe linkifying. Fill
  the Detail heading of docs/dashboard.md.
  Tests: small "A Bead with commits", "A Bead without sessions", "Both directions", per-block source
  state when the token source is stale; medium "An unknown Bead" and the raw JSON of "A note contains
  markup". Its rendering is covered in the acceptance of TASK-DSH-011.
  Check: scripts/dashboard.test.sh, scripts/dashboard-data.test.sh. Branch feat/.

- [ ] TASK-DSH-007 [standard] [~950 loc] The start page shows Bead progress, project age and activity with honest gaps.
  Per design Decisions 10 and 16 (Start page) and the start-page and gaps requirements, panels 1 to 6.
  Add scripts/lib/dashboard_metrics.py with `summary_view`, status counts, closed by change, cycle and
  lead time with median and p90, project age and the activity series, taking every source snapshot
  and treating a missing one as `absent`. Serve `/api/v1/summary`. Fill scripts/dashboard/charts.js
  (bars, stacks, histogram, the fixed readout, gap bands), views/start.js and views/start.css, the
  range and group controls, panel states and Table toggles. Fill the Overview heading of
  docs/dashboard.md.
  Tests: small "Beads by status", "Lead time with a missing start", "Project age", "Tokens start
  later than Beads" as gap output, median and p90 edge cases, empty input; medium `/api/v1/summary`
  with only the Beads source present returns `absent` for the others and no zero.
  Check: scripts/dashboard.test.sh, scripts/dashboard-data.test.sh. Branch feat/.

- [ ] TASK-DSH-008 [standard] [~650 loc] The start page shows agents, tokens, commits and test cost.
  Per design Decisions 10 and 16 (Start page) and the start-page and gaps requirements, panels 7 to 11.
  Extend scripts/lib/dashboard_metrics.py with agent-hours, orchestrator hours, running sessions,
  agents with models and tiers, tokens, commits and lines, and test cost, in functions beside
  `summary_view`. Fill scripts/dashboard/views/start-usage.js, reusing charts.js with the agent series
  and patterns. Requested and observed models are labelled apart. Tokens read "Known:" and carry no
  cost or quota percent. Fill the Usage heading of docs/dashboard.md.
  Tests: small "The orchestrator session", "A running session", planning sessions counted with no
  Bead, "A partial runtime" panel output, "A consumer repository without test records", commits with
  no Bead token; medium a summary with stale tokens keeps the last values and states it.
  Check: scripts/dashboard.test.sh, scripts/dashboard-data.test.sh. Branch feat/.

- [ ] TASK-DSH-009 [complex] [~950 loc] One change appears as a left-to-right flow with lanes and its longest chain.
  Per design Decision 11 and the graph and layout requirements, change scope only. Fill
  scripts/lib/dashboard_graph.py: subgraph, cycle breaking, layering, dummies, crossing sweeps,
  coordinates, components, longest chain and lanes, ghost nodes, the 80-node cap with closed
  collapse, `graph_view` and the per-generation LRU. Serve `/api/v1/graph` for `scope=change`, and
  answer other scopes 501 until TASK-DSH-010. Fill scripts/dashboard/graph/render.js and graph/graph.css:
  SVG nodes with status shapes, edges, longest chain, faded closed nodes, the legend and the cycle
  banner. Fill the Graph heading of docs/dashboard.md.
  Tests: small "Every edge goes right", "A cycle in the data", "The same input twice", "Two equal
  chains", self-loop, disconnected components, an 80-node fixture under one second, "A scope above the
  cap"; medium "A change as a flow" and "A cycle exists" through `/api/v1/graph`.
  Check: scripts/dashboard.test.sh, scripts/dashboard-data.test.sh. Branch feat/.

- [ ] TASK-DSH-010 [standard] [~850 loc] The graph works by touch, mouse and keyboard, for a Bead's neighbourhood and the ready frontier.
  Per design Decision 16 (Graph) and the graph and interface requirements. Add the `bead:<id>` scope
  with `depth` and the `ready` scope to scripts/lib/dashboard_graph.py and serve them. Fill
  scripts/dashboard/graph/interact.js (Pointer Events pan, pinch, wheel, double-tap, keyboard, fit,
  phone layer stepper, reduced motion), graph/scope.js (scope picker, default ready frontier, depth,
  collapsed groups that expand) and graph/list.js (the topological text alternative). Add the
  graph's "Open in graph" entry from detail through the shared route.
  Tests: small "A neighbourhood" at depth 1 and 2, "The ready frontier", an unknown `bead:` scope,
  group expansion; medium both scopes through `/api/v1/graph`. "The graph by touch" is covered in the
  acceptance of TASK-DSH-011.
  Check: scripts/dashboard.test.sh, scripts/dashboard-data.test.sh. Branch feat/.

## 4. Release readiness

- [ ] TASK-DSH-011 [complex] [~300 loc: packed install, docs and live acceptance, deliberately small] A packed install runs the dashboard, and the live acceptance on a phone is recorded.
  Per design Decision 14 and the packaging requirement. Add a packed test: `npm pack`, `init` and
  `update` in a scratch repository, woff2 byte identity, `remove`, a drift check of fonts and logo
  against docs/assets, and no test file shipped. Finish docs/dashboard.md, docs/README.md and
  docs/_config.yml, finalise the CHANGELOG entry and link the page from docs/guides.md. Write an
  unsigned acceptance report under docs/acceptance/ from a real run on the delivery host, with 673 real
  Beads, on a desktop browser and on a phone over Tailscale: open the link, every view, touch graph,
  themes, a note with markup, "Unencrypted connection" on a LAN bind and a first-load timing. Never stop
  Dolt for this: the stub suites cover it. Contract drift goes in a discovery note.
  Tests: large "A consumer update" and the install, update and remove cycle; "Theme choice", "The table
  on a phone", "The graph by touch" and "A note contains markup" are manual rows of the acceptance
  report, since no JS runner exists.
  Check: new scripts/packed-dashboard.test.sh, scripts/package-manifest.test.sh, scripts/docs-site.test.sh.
  Branch feat/.
