## Why

Nogging keeps its state in five places: Beads in Dolt, commits in Git, session records,
the token store and test records. Each has a good CLI, and none of them answers "where do
we stand" at a glance. Reading a change's progress today takes `bd list`, `bd dep tree`,
`git log`, `nogg token-usage report` and `nogg test report`, on a terminal, one at a time.
The Product Owner also wants that overview on a phone, away from the delivery host.

Epic SPEC-6puu (GitHub #283) asks for an optional web dashboard. The Product Owner approved
the scope of step 1 on 2026-11-01: statistics, a Bead table with detail, and a scoped
dependency graph, read-only, for desktop browsers and phones, reachable on the local network
and over Tailscale or a VPN, never from the internet. Epic SPEC-hg53 (Gantt and board) follows
later and should be able to reuse the data layer.

## What Changes

- **`nogg dashboard`.** A new optional foreground command starts a local web server. Nothing
  else in Nogging depends on it, it installs no service, and a repository that never runs it
  behaves exactly as before.
- **Start page.** Beads by status, what was done, how long work took, how old the project is,
  an activity timeline, token usage, agents with models and tiers, commits and changed lines,
  and test cost. A period without data is shown as a gap and never as zero.
- **Bead table and detail.** All Beads with filters, sorting and search. The detail view shows
  description, notes, dependencies in both directions, labels, and per-Bead commits, lines,
  sessions, tokens and test cost.
- **Graph view.** A left-to-right dependency flow for one change, the neighbourhood of one
  Bead, or the ready frontier, with parallel lanes, the longest dependency chain and a cycle
  warning. It never draws the whole repository by default.
- **Access control.** The default bind is `127.0.0.1`. An explicit option binds to a private
  address only, and every public or wildcard address is refused. A non-loopback bind needs an
  access token, opened once as a link on the phone and then remembered by the browser.
- **Read-only.** No endpoint mutates Beads, Git or state. A request never starts a subprocess.
  The server adds no Beads, facts or commits, and it never starts Dolt or triggers collection.
- **Local assets.** HTML, CSS, JS, the Nogging logo and the Poppins font are served locally,
  with the docs site's greens in light and dark. Charts and the graph are in-house SVG. There
  is no CDN, no telemetry and no new runtime dependency.

## Capabilities

### New Capabilities

- `dashboard`: the optional read-only web dashboard: command, bind and token policy, request
  and response rules, the data layer and its freshness, the three views, responsive behaviour,
  and packaging.

### Modified Capabilities

None. The token read lease and the per-commit Git attribution are internal additions behind
existing modules, and their behaviour for the dashboard is specified in `dashboard`.

## Impact

- **New files:** `scripts/lib/dashboard_{security,server,cache,sources,slow_sources,model,metrics,graph}.py`,
  their tests, `scripts/dashboard/` (static assets), `docs/dashboard.md`.
- **Changed files:** `scripts/nogg` (one subcommand), `scripts/lib/token_usage_store.py` (read
  lease), `scripts/lib/token_usage_report.py` (per-commit attribution, additive day and model
  views), `bin/lib/manifest.js`, `package.json`, `docs/security-model.md`, `docs/commands.md`,
  `THIRD_PARTY_NOTICES.md`, `CHANGELOG.md`.
- **No new runtime dependency.** Python standard library, Python 3.9 or newer, on the Linux hosts
  in the compatibility matrix.
- **Security surface.** A local network listener is new for Nogging. `docs/security-model.md`
  gains a section, including the residual risk of plain HTTP on a shared LAN.
- **Out of scope:** any write action, TLS, Internet exposure, a service unit, multi-repository
  views, and the Gantt and board views of SPEC-hg53.
