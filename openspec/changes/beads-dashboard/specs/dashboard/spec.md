## ADDED Requirements

### Requirement: The dashboard is an optional foreground command

`nogg dashboard` SHALL start a foreground web server for the current repository and SHALL stop on
SIGINT or SIGTERM. It SHALL read the canonical checkout's state from any linked worktree. It SHALL
install no service unit, write no configuration key and leave no process behind. Nothing else in
Nogging SHALL depend on it. A port already in use SHALL end the command with a message naming
`--port`, and SHALL NOT pick another port silently.

#### Scenario: The operator starts it with defaults

- **WHEN** the operator runs `nogg dashboard`
- **THEN** the server listens on `127.0.0.1` on the default port and prints its address

#### Scenario: The port is taken

- **WHEN** the chosen port is already in use
- **THEN** the command exits non-zero, names the port and suggests `--port`

#### Scenario: It runs from a linked worktree

- **WHEN** `nogg dashboard` runs in a linked worktree
- **THEN** it reads sessions, test records and token data of the canonical checkout

#### Scenario: A stop leaves nothing behind

- **WHEN** the server receives SIGTERM
- **THEN** the process exits, the socket closes and no child process remains

### Requirement: The server binds to private addresses only

The default bind address SHALL be `127.0.0.1`. `--bind <address>` SHALL accept only a literal IP
address inside an explicit allow-list: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`,
`192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`, `::1/128`, `fc00::/7`, and `fe80::/10` with a
zone. The decision SHALL NOT use the `is_private` or `is_global` properties of Python's
`ipaddress` module. It SHALL refuse wildcard addresses, IPv4-mapped IPv6 addresses, hostnames and
every other address before any socket opens, and the error SHALL name the refused value and how to
list eligible addresses. `--list-binds` SHALL print this host's eligible addresses as a hint, and
that output SHALL NOT feed the bind decision.

#### Scenario: A public address is refused

- **WHEN** the operator runs `nogg dashboard --bind 8.8.8.8`
- **THEN** the command exits non-zero before opening a socket and names the refused address

#### Scenario: The wildcard is refused

- **WHEN** the operator passes `0.0.0.0` or `::`
- **THEN** the command refuses it and does not expand it to the host's interfaces

#### Scenario: A Tailscale address is accepted

- **WHEN** the operator passes a `100.64.0.0/10` address assigned to this host
- **THEN** the server binds to it and requires the access token

#### Scenario: A mapped or borderline address is refused

- **WHEN** the operator passes `::ffff:127.0.0.1`, `100.128.0.1`, `172.32.0.1` or `2606:4700::1`
- **THEN** the command refuses it

#### Scenario: A hostname is refused

- **WHEN** the operator passes `localhost` or `dashboard.example`
- **THEN** the command refuses it and asks for a literal address

#### Scenario: A link-local IPv6 address has no zone

- **WHEN** the operator passes `fe80::1` without a zone
- **THEN** the command refuses it and names the zone form

#### Scenario: A supervised session asks for a network bind

- **WHEN** `nogg dashboard --bind <non-loopback address>` runs inside a supervised session
- **THEN** the command refuses it, because the token would reach the session log

### Requirement: A non-loopback bind requires an access token

A non-loopback bind SHALL require an access token for every route except the data-free shell, its
static assets and the unauthorized page. The secret SHALL be at least 256 bits from `secrets`,
stored in `<state>/dashboard/secret` with mode `0600` inside a `0700` directory, and SHALL survive a
restart. A secret file with wider permissions SHALL be refused. `--rotate-token` SHALL replace the
secret and invalidate every existing browser session. Token comparison SHALL be constant-time on
bytes. Failed authentications SHALL be limited to ten per minute, after which the server SHALL
answer 429 with `Retry-After`. A loopback bind SHALL need no token.

#### Scenario: A request has no token on a network bind

- **WHEN** a client calls `/api/v1/summary` on a non-loopback bind without a valid session
- **THEN** the server answers 401 and returns no data

#### Scenario: A wrong token is sent

- **WHEN** a client calls `/api/v1/auth` with a wrong token
- **THEN** the server answers 401 and sets no cookie

#### Scenario: Too many failures

- **WHEN** an eleventh failed authentication arrives within one minute
- **THEN** the server answers 429 with `Retry-After`

#### Scenario: The secret is too open

- **WHEN** the secret file has mode `0644`
- **THEN** a non-loopback start refuses and names the file and the required mode

#### Scenario: The token is rotated

- **WHEN** the operator runs `nogg dashboard --rotate-token`
- **THEN** cookies issued before the rotation are rejected

#### Scenario: A loopback client

- **WHEN** a client calls `/api/v1/summary` on the default loopback bind
- **THEN** the server answers without a token

### Requirement: The link is opened once and then remembered

On a non-loopback bind the command SHALL print a link that carries the token in the URL fragment,
only when stdout is a terminal. It MAY also print a terminal QR code when `qrencode` is on `PATH`,
passing the link on stdin. The shell SHALL read the fragment, call `/api/v1/auth` with an
`Authorization: Bearer` header and remove the fragment with `history.replaceState`. The server SHALL
answer with a signed, expiring cookie that is not the token itself, set `HttpOnly; SameSite=Strict;
Path=/; Max-Age=2592000`, with the port in the cookie name.

#### Scenario: The phone opens the link

- **WHEN** a phone opens the printed link
- **THEN** the cookie is set, the fragment is gone from the address bar and history, and data loads

#### Scenario: The phone comes back

- **WHEN** the same browser returns within 30 days
- **THEN** data loads without the link

#### Scenario: The token never reaches a server log

- **WHEN** the link is opened
- **THEN** no request line contains the token

#### Scenario: Output is not a terminal

- **WHEN** stdout is a pipe or a file
- **THEN** the link is not printed, and the command says how to print it on a terminal

### Requirement: Requests are checked before they are served

The server SHALL accept GET and HEAD only and SHALL answer every other method with 405 and `Allow`.
It SHALL reject a request body. It SHALL allow only a `Host` equal to the bound address and port, or
`localhost` on a loopback bind, or a literal value given with `--allow-host`, and SHALL answer any
other with 421 and a missing one with 400. A present `Origin` SHALL equal the server's own origin,
and a present `Sec-Fetch-Site` SHALL be `same-origin` or `none`. The server SHALL send no CORS
headers. It SHALL check the peer address against the bind allow-list before starting a request
thread. Static routes SHALL come from a fixed map loaded at start, so no filesystem path derives
from a request. A Bead ID SHALL match a strict pattern and exist in the snapshot. Responses and logs
SHALL NOT echo the path, the query or a header value.

#### Scenario: A write is attempted

- **WHEN** a client sends POST, PUT, PATCH or DELETE to any route
- **THEN** the server answers 405 and nothing changes

#### Scenario: DNS rebinding

- **WHEN** a request arrives with `Host: attacker.example`
- **THEN** the server answers 421 without data

#### Scenario: A cross-site page calls the API

- **WHEN** a request carries a foreign `Origin` or `Sec-Fetch-Site: cross-site`
- **THEN** the server answers 403

#### Scenario: Path traversal

- **WHEN** a client requests `/assets/../../.nogging/state/dashboard/secret`
- **THEN** the server answers 404

#### Scenario: A forwarded public peer

- **WHEN** a connection arrives from a public peer address
- **THEN** the server closes it before serving a request

#### Scenario: An unknown Bead

- **WHEN** a client requests a malformed or unknown Bead ID
- **THEN** the server answers 404 and starts no subprocess

### Requirement: Responses carry a strict policy and use local assets only

Every response SHALL carry `Content-Security-Policy: default-src 'none'; script-src 'self';
style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; base-uri 'none';
form-action 'none'; frame-ancestors 'none'; require-trusted-types-for 'script'`,
`X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff` and
`Cross-Origin-Resource-Policy: same-origin`. API and auth responses SHALL carry `Cache-Control:
no-store`. Every asset SHALL be served by this server, and no page SHALL reference an external URL,
send telemetry or use an external font.

#### Scenario: Headers on an API response

- **WHEN** a client reads any API route
- **THEN** the response carries every header above and `Cache-Control: no-store`

#### Scenario: No external reference ships

- **WHEN** the shipped HTML, CSS and JS are scanned
- **THEN** they contain no `http://` or `https://` reference that a browser would load

### Requirement: Server resources are bounded

The server SHALL run at most 16 request threads and answer a canned 503 beyond that. It SHALL use
HTTP/1.0 without keep-alive, a 5 second socket timeout, a 10 second deadline for reading a request,
at most 8 KiB for the request line and 16 KiB for all headers. It SHALL serve precomputed gzip
responses to clients that accept them.

#### Scenario: A slow client

- **WHEN** a client sends its headers one byte at a time past the deadline
- **THEN** the server closes the connection and frees the thread

#### Scenario: An oversized header

- **WHEN** a request exceeds the header limit
- **THEN** the server answers 431 and closes the connection

#### Scenario: Many clients at once

- **WHEN** more than 16 requests are in flight
- **THEN** further requests get 503 and the running ones finish

### Requirement: The dashboard adds no state

The dashboard SHALL add no Bead, dependency, fact, commit or configuration. Its only file SHALL be the
access secret. Every `bd` call SHALL use `--readonly --sandbox` with a timeout, and the process
SHALL set `BEADS_DOLT_AUTO_START=0` and `GIT_OPTIONAL_LOCKS=0`. It SHALL NOT start, stop or restart
Dolt, run usage collection, drain the usage spool, run `doctor`, or persist any snapshot to disk. A
request SHALL be served from memory and SHALL NOT start a subprocess.

#### Scenario: Beads are read only

- **WHEN** the refresher reads Beads
- **THEN** the stub `bd` records `--readonly --sandbox` on every call and `BEADS_DOLT_AUTO_START=0` in its environment

#### Scenario: Dolt is down

- **WHEN** the Dolt server is unreachable
- **THEN** the dashboard reports the source as unavailable, keeps its last good data and does not start Dolt

#### Scenario: A request spawns nothing

- **WHEN** 100 requests hit every route
- **THEN** no subprocess starts because of a request

#### Scenario: Pending usage stays pending

- **WHEN** usage batches wait in the spool
- **THEN** the dashboard shows the pending count, and the spool is unchanged after a refresh

#### Scenario: No snapshot on disk

- **WHEN** the server has refreshed every source
- **THEN** the secret file is the only file it has created

### Requirement: One background refresher keeps per-source snapshots

One daemon refresher thread SHALL run the sources strictly one at a time. Request threads SHALL only
read immutable snapshots and record demand. The socket SHALL open at once, before any source has
loaded. Sources SHALL refresh on these intervals: Beads and cycles 30 s, sessions 30 s, tests 120 s,
Git 10 min, tokens 15 min. A source whose change gate shows no change SHALL skip its reload. After 5
minutes without a request the refresher SHALL idle and run no source. A failed source SHALL keep its
last good snapshot, back off from 30 s up to 10 min, and SHALL NOT affect another source. Every
response SHALL state each source's state (`loading`, `fresh`, `refreshing`, `stale`, `unavailable`
or `absent`) and its `as_of` time, and `/api/v1/freshness` SHALL expose a generation counter.

#### Scenario: The first page load

- **WHEN** a browser opens the page before any source has loaded
- **THEN** the shell renders at once and each panel shows `loading` until its source arrives

#### Scenario: Many clients

- **WHEN** ten phones poll at the same time
- **THEN** at most one source refresh runs at any moment

#### Scenario: No clients

- **WHEN** no request has arrived for 5 minutes
- **THEN** the refresher starts no source until the next request

#### Scenario: One source fails

- **WHEN** the token source fails
- **THEN** its panels show the last good data as stale and the other sources stay fresh

#### Scenario: Nothing changed

- **WHEN** the Git refs have not changed since the last refresh
- **THEN** the Git source is not reloaded

### Requirement: Reading tokens does not disturb usage collection

The token source SHALL hold a shared, non-blocking, read-only lease on the collector lock for the
whole store read, and SHALL NOT create, chmod or take exclusively that lock. If the lease is busy it
SHALL keep its last snapshot and retry later. A missing lock file or store SHALL report `absent`. The
read SHALL be capped at 45 seconds. The change gate SHALL be the collector's `last_success_at`.

#### Scenario: A collection is running

- **WHEN** the collector holds its lock
- **THEN** the token source skips this refresh, stays `stale` and touches no Dolt

#### Scenario: A collection starts during a read

- **WHEN** a collection asks for the lock while the lease is held
- **THEN** the collector waits and no batch fails because of the read

#### Scenario: A repository without a store

- **WHEN** no token store exists
- **THEN** the source is `absent` and no directory or lock file is created

### Requirement: Gaps are shown honestly

Each statistic SHALL show missing data as a gap and SHALL NOT show zero for a period without records.
Data floors SHALL be computed from the records and SHALL NOT be hard-coded versions: token data from
the earliest fact per runtime, tests from the earliest retained record, sessions from the earliest
`started_at` on this host, commits from the first commit carrying a Bead token. Session panels SHALL
say that records are local to this host. Token panels SHALL mark unknown counters and name runtimes
with partial data. A source that does not exist in a repository SHALL read "not available here".

#### Scenario: Tokens start later than Beads

- **WHEN** the chart range begins before the first token fact
- **THEN** the chart shows a gap with the first date, not zero values

#### Scenario: A consumer repository without test records

- **WHEN** the repository has no test records
- **THEN** the test panel reads "not available here"

#### Scenario: A partial runtime

- **WHEN** token facts for Pi have unknown counters
- **THEN** the panel marks the sum as partial and never shows a false total

### Requirement: The API exposes allow-listed fields only

The model layer SHALL expose Bead, session, usage and Git fields through allow-lists. It SHALL NOT
expose a Bead's `owner`, `created_by` or `assignee`. It SHALL NOT expose a session's command, prompt,
working directory, log path, host, owner, process or thread identifiers, or grants. It SHALL NOT
expose a device ID, hostname, store path, raw error text or Git author e-mail. A session's
`exit_reason` SHALL be reduced to its first line, at most 200 characters. Free text SHALL pass a
scrubber that replaces e-mail-like and token-like strings and home-directory paths, and the scrubber
SHALL be documented as best effort. Stderr of a source SHALL NOT reach a client.

#### Scenario: An owner address

- **WHEN** a Bead's `owner` holds an e-mail address
- **THEN** no API response contains that address

#### Scenario: An address in notes

- **WHEN** a note contains an e-mail address
- **THEN** the API returns the note with the address replaced

#### Scenario: A session record

- **WHEN** a session is returned in Bead detail
- **THEN** its fields are exactly the allow-listed ones

#### Scenario: A long exit reason

- **WHEN** a session's `exit_reason` holds a multi-line startup log
- **THEN** the API returns only its scrubbed first line

#### Scenario: A source error

- **WHEN** `bd` fails with stderr text
- **THEN** the client sees the classified state only

### Requirement: Bead text is rendered as text

The client SHALL render every value from the API with text nodes and SHALL NOT use `innerHTML` or an
equivalent sink. It SHALL NOT render Markdown or auto-link Bead text. Line breaks SHALL be preserved.

#### Scenario: A note contains markup

- **WHEN** a note contains `<script>alert(1)</script>`
- **THEN** the page shows that text literally and no script runs

### Requirement: The start page shows statistics from metadata

The start page SHALL show: Beads by status; closed Beads per day or week and by change; cycle time
(`started_at` to `closed_at`) and lead time (`created_at` to `closed_at`) as median and p90, counting
Beads excluded for a missing start; agent-hours from sessions, with the orchestrator's hours
separate and running sessions counted, not summed; project age from the root commit and the first
Bead; an activity timeline; token usage with `fresh_input + output` as the headline; agents with
models and tiers; commits and changed lines split into production and test; and test cost per stage.
It SHALL label requested models from sessions and observed models from usage as different things.
`assignee` SHALL NOT be presented as who worked.

#### Scenario: Beads by status

- **WHEN** the Beads source is fresh
- **THEN** the page shows open, in progress, blocked, closed and deferred counts that match `bd`

#### Scenario: Lead time with a missing start

- **WHEN** closed Beads have no `started_at`
- **THEN** cycle time excludes them and states how many it excluded

#### Scenario: The orchestrator session

- **WHEN** an always-on orchestrator session has run for weeks
- **THEN** its hours are shown separately and are not in the agent-hours headline

#### Scenario: A running session

- **WHEN** a session has no `ended_at`
- **THEN** it counts as running and adds nothing to the hours sum

#### Scenario: Project age

- **WHEN** the page loads
- **THEN** it shows the root commit date, the first Bead date and the age in days

### Requirement: The table lists every Bead

The Bead view SHALL list all Beads with filters for status, type, priority, change and label class
(`openspec:task`, `discovery`), free-text search over ID and title, and sorting by every shown column.
Filters and sort SHALL live in the URL. The default view SHALL show non-closed Beads, with one control
to include closed ones. The list SHALL load without descriptions or notes, and SHALL be paged at 50
rows so the DOM stays small.

#### Scenario: A filter by change

- **WHEN** the user filters by one change
- **THEN** only Beads with that `openspec:change:` label remain, and the URL reproduces the view

#### Scenario: The list payload

- **WHEN** `/api/v1/beads` is read
- **THEN** it carries no `description` and no `notes`

#### Scenario: A Bead without a change

- **WHEN** a Bead has no change label
- **THEN** it appears under "no change" and stays reachable through the filter

### Requirement: The detail view shows one Bead with its evidence

Clicking a Bead in any view SHALL open the same detail view with its own URL. It SHALL show title,
status, type, priority, description, notes, close reason, dependencies in both directions with their
status, labels, commits with SHA and subject, production and test lines, sessions with agent, model,
effort, tier, role, start, end, duration and exit reason, tokens, and test cost. Each block that
depends on a slow source SHALL show its own freshness.

#### Scenario: A Bead with commits

- **WHEN** a Bead's commits carry its `[<id>]` token
- **THEN** the detail lists them, a rebased copy counts once, and the line counts match

#### Scenario: A Bead without sessions

- **WHEN** no session record names the Bead on this host
- **THEN** the block says records are host-local rather than "none"

#### Scenario: Both directions

- **WHEN** a Bead blocks two others and depends on one
- **THEN** the detail lists all three by direction with their status

### Requirement: The graph is scoped

The graph view SHALL offer three scopes: one change, the neighbourhood of one Bead with upstream
blockers and downstream unblocked Beads to a chosen depth, and the ready frontier. It SHALL NOT draw
the whole repository by default. At most 80 nodes SHALL be visible. Closed Beads SHALL be faded and
collapsible, and collapse SHALL happen first when a scope exceeds the cap. The response SHALL report
how many nodes were left out. Only `blocks` edges SHALL affect layout. A Bead outside a change scope
SHALL appear only as a ghost node one step out. `bd dep cycles` output SHALL show as a warning.
Clicking a node SHALL open the same detail view.

#### Scenario: A change as a flow

- **WHEN** the user picks a change
- **THEN** its Beads appear left to right by dependency, with parallel lanes and the longest chain marked

#### Scenario: A neighbourhood

- **WHEN** the user opens the graph from a Bead with depth 2
- **THEN** only Beads within two `blocks` steps appear

#### Scenario: The ready frontier

- **WHEN** the user picks the ready scope
- **THEN** the Beads that `bd ready` returns appear

#### Scenario: A scope above the cap

- **WHEN** a scope holds 300 Beads
- **THEN** closed Beads collapse first, at most 80 nodes appear, and the view states how many are hidden

#### Scenario: A cycle exists

- **WHEN** `bd dep cycles` reports a cycle
- **THEN** the view shows a warning and the graph still renders

### Requirement: The layout is deterministic and always terminates

The layout SHALL be computed on the server in pure Python and cached per data generation. It SHALL
be a layered left-to-right layout: every forward edge SHALL point rightward, no two nodes SHALL
overlap, equal input SHALL give equal output, and it SHALL terminate on cycles and self-loops by
reversing back-edges, which it SHALL mark. The critical path SHALL be the longest `blocks` chain by
node count over non-closed Beads, or over all Beads when the change is finished, and it SHALL be
labelled "longest dependency chain", never a time estimate. When the scope contains a cycle no chain
SHALL be marked, and the view SHALL say why. Disconnected components SHALL stack vertically, the
largest first.

#### Scenario: Every edge goes right

- **WHEN** an acyclic scope is laid out
- **THEN** each edge's target lies right of its source and no nodes overlap

#### Scenario: A cycle in the data

- **WHEN** the scope contains a cycle or a self-loop
- **THEN** layout terminates, marks the reversed edges and marks no longest chain

#### Scenario: The same input twice

- **WHEN** the same scope is laid out twice with nodes in a different order
- **THEN** the results are identical

#### Scenario: Two equal chains

- **WHEN** two chains have the same length
- **THEN** the tie breaks by `[~N loc]` sum and then by ID, and the result is stable

### Requirement: The interface works on desktop and phone

Every view SHALL work on a desktop browser and on a phone at 360 CSS pixels wide without horizontal
page scroll, with touch targets of at least 44 by 44 CSS pixels. The look SHALL use the docs site's
brand tokens, the Nogging logo and the Poppins font, in light, dark and system themes. Text and
interface colours SHALL meet WCAG 2.1 AA contrast, and status SHALL always be shown by shape as well
as colour. The graph SHALL support pan, pinch zoom, tap and a fit-to-screen control on touch, and
mouse and keyboard on desktop, and SHALL offer a text alternative. Charts SHALL have a data-table
alternative. Tooltips SHALL work by tap. Animation SHALL honour `prefers-reduced-motion`. The
interface SHALL show no write control. A plain-HTTP non-loopback session SHALL show an "unencrypted
connection" notice.

#### Scenario: The table on a phone

- **WHEN** the Bead view opens at 360 pixels wide
- **THEN** Beads appear as readable cards with no horizontal page scroll

#### Scenario: The graph by touch

- **WHEN** a user pinches, drags and taps on a phone
- **THEN** the graph zooms and pans, a tap opens the detail, and the page itself does not scroll or zoom

#### Scenario: Theme choice

- **WHEN** the user selects a theme
- **THEN** it applies at once and is remembered in that browser

#### Scenario: Colour-blind reading

- **WHEN** a status is shown in the graph or a table
- **THEN** a shape or icon distinguishes it without colour

### Requirement: The dashboard ships with init and update and stays quiet when unused

`init` and `update` SHALL install the modules and static assets, binary fonts included, and `remove`
SHALL remove them. Tests SHALL NOT ship. The Poppins licence SHALL ship beside the fonts. `doctor`
SHALL print nothing about the dashboard unless `<state>/dashboard/secret` exists, and then SHALL warn
only when its mode is wider than `0600`. No configuration key SHALL be required.

#### Scenario: A consumer update

- **WHEN** `update` runs in a consumer repository
- **THEN** `nogg dashboard` works there and the woff2 files match their source byte for byte

#### Scenario: Doctor on an unused install

- **WHEN** `doctor` runs in a repository that never started the dashboard
- **THEN** its output has no dashboard line

#### Scenario: Doctor with an open secret

- **WHEN** the secret file has mode `0644`
- **THEN** `doctor` warns and names the file

#### Scenario: A repository without bd

- **WHEN** `bd` is not installed
- **THEN** the server starts, Bead panels say `bd` is missing, and Git-based panels still work
