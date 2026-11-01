# Dashboard

`nogg dashboard` is an optional, read-only web view of this repository's Beads,
sessions, tests and token records. It runs in the foreground, adds no Beads,
facts, commits or configuration, and nothing else in Nogging depends on it.

## Start

```bash
./scripts/nogg dashboard                 # http://127.0.0.1:8742/ until Ctrl-C
./scripts/nogg dashboard --port 9000     # another port; a taken port is an error
./scripts/nogg dashboard --list-binds    # addresses this host could use
./scripts/nogg dashboard --bind 100.101.102.103   # a Tailscale address, for a phone
```

It stops on Ctrl-C or SIGTERM and leaves no process behind. There is no service
unit and no configuration key. It reads the state of the main checkout from any
linked worktree.

`--bind` takes one literal private address: `127.0.0.0/8`, `10.0.0.0/8`,
`172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`, `::1`,
`fc00::/7`, or `fe80::/10` with a zone, as in `fe80::1%eth0`. Everything else is
refused before a socket opens: a public address, a wildcard such as `0.0.0.0`, an
IPv4-mapped address and any hostname, `localhost` included. Most browsers cannot
open a link-local IPv6 address, so prefer another address for a phone.

`--list-binds` is a hint and never feeds the decision. It warns about a
`100.64.0.0/10` address on an interface that is not `tailscale*`, because that
range is also used for carrier NAT.

`--allow-host <host[:port]>` adds one exact `Host` value, for example a Tailscale
MagicDNS name such as `pi.tailnet.ts.net:8742`. Include the port: a value without
one matches only port 80. Repeat it for more names. It accepts no wildcard.

## Access

A loopback bind needs no token. Any other bind needs one for everything except the
shell, its assets and the unauthorized panel, none of which hold data.

On the first network start, `nogg dashboard` creates a 256-bit secret in
`.nogging/state/dashboard/secret` with mode `0600`, in a `0700` directory. On a
terminal it then prints a link, and a QR code when `qrencode` is installed:

```text
Open once on each device: http://100.101.102.103:8742/#token=<token>
```

The token travels in the URL fragment, which no request, server log or `Referer`
carries. The page removes it from the address bar and the current history entry at
once, then trades it for a signed cookie valid for 30 days. The cookie is not the
token. The link stays valid until the token is rotated, and a browser's global
history may keep the visited address with its fragment, so rotate the token if a
device with that history leaves your hands.

When output is not a terminal, no link is printed. A network bind is refused inside
a supervised session, because the link would reach the session log. Any network bind
outside `100.64.0.0/10` also prints a warning: the traffic is plain HTTP, so prefer a
Tailscale address for a phone. An address inside that range prints a note, because
carrier NAT uses the same range and only Tailscale encrypts the traffic.

```bash
./scripts/nogg dashboard --rotate-token
```

This replaces the secret and exits. Every browser session ends at once, in a
running dashboard too. Start a network bind on a terminal to print a new link.

A secret file wider than `0600` or a directory wider than `0700` refuses a network
start, and `nogg doctor` warns about such a file. A running server that finds its
secret gone or too open refuses every session until the file is fixed.

After ten failed authentications in a minute, further failures get 429 and
`Retry-After`. A correct token or a valid session is never limited, so the limit
cannot lock you out, and a request with no credential or an expired cookie does not
count. See the [security model](security-model.md#the-dashboard) for what
this does not protect against.

## Interface

The page is a shell of static files that holds no data. It works on a desktop browser and on a
phone at 360 CSS pixels, with touch targets of 44 by 44 pixels, and it has no control that writes.

**Navigation.** Three views live behind hash routes, so the server needs no fallback:
`#/` (Overview), `#/beads?…` (the table) and `#/graph?scope=&id=`. A `bead=<ID>` parameter on any
route opens the one detail panel on top of that view. On a desktop the tabs sit in the header. On a
phone they are a fixed bar at the bottom with safe-area padding. The search field sends `q` to the
Bead table. A skip link, landmarks and a polite live region for freshness serve screen readers, and
every control is reachable by keyboard. Focus returns to the control that opened a sheet.

**Freshness.** The header chip shows when the data was last updated. It polls
`/api/v1/freshness` every 10 seconds while the tab is visible, stops while it is hidden and polls at
once when it returns. With data saving on (`prefers-reduced-data`) it does not poll by itself, and
Poppins is replaced by the system font. Choosing the chip opens a sheet with each source's state and
a "Refresh now" button, which is one more read and starts nothing on the server. The states:

| Situation | What the page shows |
|---|---|
| Data older than 5 minutes | Banner: "Data may be stale, last update 12:04" |
| The server does not answer | Banner: "Server not reachable. Showing data from 12:04." |
| `bd` cannot be read | Full page "Beads are not reachable" with Retry |
| No valid session | Full page: open the access link from the host again |
| Plain HTTP on a non-loopback address | Banner: "Unencrypted connection" |

**Themes.** System, Light or Dark, chosen in the header and remembered in this browser under
`nogging-theme`. It applies at once. System follows `prefers-color-scheme`. The tokens are in
`scripts/dashboard/tokens.css`, taken from the docs site colour scheme. Text keeps 4.5:1 contrast and
controls and marks keep 3:1 in both themes, which `scripts/lib/dashboard_tokens_test.py` recomputes
from that file. Breakpoints: phone under 600, tablet 600 to 959, desktop 960 to 1439, wide from 1440.

**Status without colour.** Every status has its own shape as well as its colour: open is a hollow
circle, ready a triangle, in progress a half-filled circle, blocked an octagon with a bar, deferred a
dashed diamond and closed a check in a square. Priority is text, `P0` to `P4`.

**Text is text.** The client builds every value from the API as a text node. No script uses
`innerHTML` or an equivalent, and a test scans the scripts for one. The policy also forbids inline
script and style.

**For a view author.** A view registers itself and does not edit shared files:

```js
window.noggingApp.registerView("beads", {
  mount(container, ctx) {          // ctx: params, store, panel, link, openDetail, format, dom
    const panel = ctx.panel({ title: "Beads" });
    container.appendChild(panel.element);
    panel.load("beads", "/api/v1/beads", (envelope) => /* nodes */);
  },
  unmount() {},                    // optional
});
```

`panel.set(state, info)` takes one of five states: `loading`; `ready` (a node or a list of nodes);
`gap` (`{since}`, shown as "No data before {date}", never a zero); `empty` (text); `error`
(`{message, retry}`). `store.get(name, path)` caches one response per name and
`store.subscribe(fn)` reports the sources whose generation changed. `registerView("detail", {open(id),
close()})` provides the detail panel. `dom.statusBadge(status)` and `dom.priorityChip(n)` give the
shared look.

## Data

Every number on the dashboard comes from memory. One background thread, the
*refresher*, reads the sources one at a time and keeps one snapshot per source. A
request only reads a snapshot, so a request never starts a program, and ten phones
asking at once cause no more reads than one.

| Source | What it reads | Every | Skipped when |
|---|---|---|---|
| `beads` | `bd list`, `bd ready` and `bd dep cycles` | 30 s | never |
| `sessions` | the session records of the main checkout | 30 s | the directory did not change |
| `tests` | the `nogg test` run records | 2 min | the record files did not change |
| `git` | Git commits that carry a Bead token | 10 min | the refs did not change |
| `tokens` | the usage store | 15 min | the collector has not succeeded again |

The socket opens before any source has loaded, so the page shows each panel as
`loading` until its source arrives. After five minutes without a request the
refresher idles and starts no source until the next request, so a dashboard nobody
watches costs nothing. Idle data reads `stale`, not `fresh`.

### States

Every response names the state and `as_of` time of each source it used, and
`/api/v1/freshness` holds that block alone, with a `generation` counter that moves
only when a source's data really changed. The client polls it every 10 seconds and
refetches a view when its sources' generation moved.

| State | Meaning |
|---|---|
| `loading` | the first read has not finished |
| `fresh` | read, or checked and unchanged, within two intervals |
| `refreshing` | a read is running and the previous snapshot is still served |
| `stale` | the last read failed, was skipped, or is older than two intervals; the last good data stays |
| `unavailable` | the read failed and there is no earlier data |
| `absent` | the source does not exist here: no test records, no session records |

A failed source keeps its last good snapshot and tries again after 30 s, then 1, 2,
4 and 8 minutes, at most every 10 minutes. It never affects another source. A stale or
unavailable source also carries a `reason`: `dolt_unreachable` (the Dolt server is not
running; on the host, run `bd dolt start`), `bd_absent` (`bd` is not installed),
`bd_error`, `busy` (a collector holds the usage lock, so the read waits) or `error`.
Nothing but this class reaches a client: the text `bd` printed on stderr is read to pick
the class and then dropped. The dashboard never starts Dolt and shows no control for it.

### What it adds

Nothing. Every `bd` call is `bd --readonly --sandbox …` with a 30 second timeout, with
`BEADS_DOLT_AUTO_START=0` in its environment, so a call cannot start Dolt. It runs no
`doctor` and no usage collection, adds no Bead, fact, commit or configuration, and writes
no snapshot to disk. The access secret is its only file. "Read-only" does not promise that
no file is touched: a `SELECT` on an embedded Dolt store may update its own manifest.

### What is served

The API serves allow-listed fields only. A field that is not in the list does not exist
for the API.

- **Bead:** `id, title, status, priority, issue_type, labels, description, notes,
  close_reason, parent, created_at, started_at, closed_at, updated_at, dependency_count,
  dependent_count, dependencies`, with each dependency reduced to `issue_id, depends_on_id,
  type, created_at`. The list at `/api/v1/beads` leaves out `description`, `notes` and
  `close_reason` and adds `change` (the `openspec:change:` label, or null) and `ready`.
  Never `owner`, `created_by` or `assignee`: `assignee` says who claimed a Bead, not who
  worked on it.
- **Session:** `name, agent, requested_model, reasoning_effort, selection_tier, role,
  bead_id, planning_id, state, started_at, ended_at, exit_reason`. Never the command, the
  prompt, the working directory, the log path, the host, the owner, process or thread
  identifiers or the grants. The `exit_reason` is its first line, scrubbed, at most 200
  characters.
- **Test run:** `bead, stage, at, seconds, status`.

`/api/v1/changes` lists the Beads of each change by status, with the Beads that carry no
change label under `change: null`, so they stay reachable.

### The scrubber is best effort

Free text (titles, descriptions, notes, close reasons, labels and exit reasons) passes a
scrubber that replaces e-mail-like strings with `[address]`, token-like strings with
`[secret]` and home-directory paths with `~`. It catches the common shapes: addresses,
well-known token prefixes, JSON web tokens, `token=…` and `Bearer …` values and long
random strings. Git object names (40 or 64 hex characters) and hyphenated names such as session names stay
readable, so a secret of exactly that shape is not caught unless a key word such as `token=`
precedes it. Credentials in a URL (`https://user:pass@host`) are replaced.
It cannot know what a secret looks like in free text, so it will miss some and may hide a
harmless string. On this repository's own history it would match a handful of notes. Treat
the dashboard as a view for people who may already read the Beads, and do not write
credentials into Beads or notes.

Records of sessions are local to the host that ran them. A panel built from them says so
and shows the earliest record it holds as its floor, rather than a zero for the time
before.

## Usage data

Two sources are slow, so they refresh in the background, behind a gate, and never for a
request. Neither adds anything to your repository.

### Git

The `git` source lists every commit whose subject carries a Bead token such as
`[SPEC-abc]`, on all local and remote-tracking branches and tags, with its production and
test lines. Merges do not count, and a rebased or cherry-picked copy counts once.

- It reloads only when the hash of `git for-each-ref` over branches, remotes and tags
  moves. Other refs, such as Dolt's, do not cause a reload.
- A commit never changes, so its line counts stay in memory and later reads ask Git only
  for new commits.
- A token is anything in brackets shaped like a Bead ID, because this source reads without
  the Bead list. `[wip]` does not count; `[skip-ci]` would.
- Commits include unmerged work. Commits without a token appear only as a count.
- Subjects pass the scrubber. Author names and addresses are never read.

### Tokens

The `tokens` source reads the local usage store and keeps known work per Bead, per day and
runtime and per model, for the whole history. Raw facts are dropped once they are reduced:
no device, hostname, session or store path stays in memory.

Dolt allows no write beside a running read: an insert fails at once with `database is read
only`, and the collector moves a batch to quarantine after three such failures. A periodic
read would make that far more likely, so the source holds a read lease:

- The lease is a shared, non-blocking lock on `collector.lock`, held for all Dolt calls of a
  read. Taking it creates and changes nothing, and it leaves `Store.locked()` as it was.
- If a collection is inside, the source touches no Dolt: it stays `stale` with the reason
  `busy` and tries again 30 seconds later.
- If a collection starts during a read, the collector waits. Every Dolt call of the read
  inherits the lease, so this also holds when the dashboard dies mid-read and its Dolt
  child lives on.
- With no lock file or no store the source reads `absent`, and nothing is created.
- All Dolt calls of one read share a cap of 45 seconds. Past it the read is killed, and the
  source backs off like any failed source.
- It reloads only when `last_success_at` in `collector/status.json` moves.

A waiting collector delays `session stop` by the length of the read, about 9 seconds on a
store of 1.4 GB by the planning estimate, and at most by the cap. The lease does not cover a manual `nogg token-usage
report`: run during a collection, it can still cost the collector an import attempt, which
the next pass retries.

### What the numbers mean

Tokens are the known counters of the usage store. They are not a cost and not a share of a
quota. A counter the source could not report stays unknown instead of counting as zero.

- `floors` holds the earliest fact per runtime. Before that date there is no data, not zero.
- `partial` names each runtime whose sums miss something: a fresh input or output nobody can
  prove, a fact the adapter calls incomplete, a fact with no time, or consumption reported
  across a day boundary. That last case stays out of the days, because splitting it would
  invent numbers, but it counts for its Bead and model.
- A Bead with runtime but no usage event has no token entry, rather than zero.
- `pending_batches` counts the batches in the spool. The dashboard counts them and never
  imports them.

## Beads

The Beads tab (`#/beads`) lists every Bead from `/api/v1/beads`. The list carries no description and
no notes, only the fields a row needs, and the server adds the `change`, a `ready` flag and `facets`:
for status, type, priority, change and label class, each choice with the number of Beads behind it,
counted over all Beads. A Bead with no `openspec:change:` label counts under no change and stays
reachable through the Change filter ("No change", `change=(none)` in the address).

**Columns.** ID, status, priority, type, title (two lines, then cut), change, updated and age. Every
column sorts by its header button, and the header carries `aria-sort`. The default is priority, then
the most recently updated. A missing value sorts last in either direction. The Updated and Age
columns sort by what they show, so ascending means the shortest time first. A Bead that `bd ready`
lists also shows a Ready badge beside its status.

**Filters.** Status, type, priority, change and label class (OpenSpec task, Discovery) are
multi-select: a Bead matches a filter when its value is any of the ticked ones, and it must match
every filter that has a tick. The search takes words that must all occur in the ID or the title, and
waits 250 ms after typing. Closed Beads are hidden until "Include closed" is ticked or the status
filter names Closed. The list shows 50 rows a page.

**The address.** Everything lives in the URL, so a link reproduces the view, and only what differs
from the default is written:

| Parameter | Meaning |
|---|---|
| `status`, `type`, `priority`, `change`, `label` | comma list of choices, e.g. `status=open,blocked` |
| `q` | search words |
| `closed=1` | include closed Beads |
| `sort`, `dir` | a column key (`id`, `status`, `priority`, `type`, `title`, `change`, `updated`, `age`) and `asc` or `desc` |
| `page` | page number, from 1 |

The Overview tiles link here with `status=`. A change of filter, sort or page replaces the history
entry instead of adding one, so Back leaves the table and does not step through clicks. Typing
rewrites the address in place and does not rebuild the page.

**Phone.** Under 960 px a Bead is a card of three lines: ID, priority and status; the title (up to
three lines); the change and when it was updated. The whole card opens the detail. "Filters (n)" opens
the filters as a bottom sheet that closes with Done, Escape or a tap outside, and returns focus to
the button. From 960 px the same filters are a sidebar and the Beads form a table. Controls are at
least 44 pixels high and the page does not scroll sideways at 360 pixels. The table, the cards and the
sheet were written to these rules but have not been looked at in a real browser on a phone; the
live acceptance of the dashboard records that check.

## Detail

Clicking a Bead in any view opens its detail. The address gains `bead=<ID>` (for example
`#/beads?status=open&bead=SPEC-abc123`), so a link opens the same detail and the browser's back
button closes it. The data comes from `/api/v1/beads/<id>`, built from the snapshots the server
already holds, so a request starts no `bd`, Git or Dolt call. An ID that no Bead has answers 404
once the Bead list is loaded; before that the answer is a 200 with `bead: null` and the Beads
source state `loading`.

**Layout.** On a screen of 600 px or more it is a 480 px panel on the right; below that it takes
the whole screen. Focus moves into the panel, everything behind it is inert, Escape or the Close
button ends it, and focus goes back to what opened it. Opening another Bead from inside the panel
(a dependency or a Bead ID in a note) keeps that first trigger.

**Order.** Header (status, priority, type, ID, a Ready badge, change and the four times), description,
notes, close reason, dependencies, labels, commits, sessions, tokens, test cost. A field with no
value reads "Not recorded". The notes are cut to 12 lines with a "Show all" button, which only
appears when the text is longer.

**Dependencies** are listed by direction, "Depends on" and "Blocks", each with the other Bead's
status and an "Open in graph" link. A dependency on a Bead that is no longer in the list keeps its
ID and shows no title or status.

**Evidence blocks.** Commits, sessions, tokens and test cost each carry the state and time of the
source behind them, so a stale token source marks the token block and nothing else. A block whose
source gave no snapshot says so (still loading, could not be read, not available here) and shows
no list, so an unread source is never read as "none".

- **Commits** are the commits whose subject carries `[<id>]`, oldest first, with SHA, subject and
  production and test lines and their totals. A rebased or cherry-picked copy (same author time and
  subject) counts once.
- **Sessions** are the records on this host that name the Bead. With none, the block says that
  session records are host-local, not "none": work from another machine does not appear.
  Fields are the allow-listed session fields; the duration is end minus start and shows "Running"
  for a running session and "Not recorded" when a time is missing or runs backwards. From 600 px the
  sessions are a table that scrolls inside its own region; below that they are cards.
- **Tokens** are the known work counters of the Bead. A Bead with no usage event shows "No usage
  event", never zero. Counters that some events lack, partial runtime history and batches waiting
  for collection are named under the numbers.
- **Test cost** is the seconds per test stage summed over the runs that ran, and the run count.

**Text is text.** Every value enters the page as a text node. Descriptions, notes and close reasons
keep their line breaks (`white-space: pre-wrap`); Markdown and HTML are shown literally, so a note
holding a `<script>` tag shows those characters and runs nothing. The only links inside text are a
known Bead ID, which opens that Bead's detail, and a SHA of this Bead's own commits, which jumps to
that commit row. A URL is never turned into a link. The assignee is never shown.

Not covered by an automated test: how the panel looks and behaves in a browser. The server side is
tested; the rendering, the focus handling and the phone layout belong to the live acceptance.

## Overview

The start page answers "how is the work going" from metadata, in six panels. It reads
`/api/v1/summary?range=7d|30d|90d|all` (default 30 days). The range and the grouping (day or week)
are in the URL, so a view can be bookmarked. Every panel has a title, a line saying how fresh its
sources are, and a **Table** button that shows the same numbers as a real table.

| Panel | Shows | Source |
|---|---|---|
| Beads by status | Open, in progress, blocked, closed and deferred counts. Each tile opens the Bead table filtered to that status. | Beads |
| Project age | Root commit date, first Bead date and the age in days. Without Git the age counts from the first Bead and says so. | Beads, Git |
| Closed over time | Closed Beads per UTC day or week. | Beads |
| Closed by change | The ten changes with most closed Beads, the rest as "Other", and Beads without a change as "No change". | Beads |
| Cycle and lead time | Median and p90 with a histogram, for cycle time (started to closed) and lead time (created to closed). | Beads |
| Activity | Beads created, Beads closed, commits, sessions started and test runs per day or week. | Beads, Git, Sessions, Tests |

### Gaps are shown, not zeroed

A period before a source has any record is a hatched band that reads "No data before {date}", never
a bar of height zero. Each activity row starts at its own first record (its *floor*, computed from
the records and not hard-coded), so a source that began later than the Beads shows a gap for the
earlier days. From its floor on, a day without a record is a real zero, because the source covers it.
A source that does not exist in this repository reads "Not available here". Nothing is averaged over
nothing: a statistic with no data has no value, and the page says so in words.

### Definitions

- **Cycle time** is `closed_at - started_at`; **lead time** is `closed_at - created_at`, so it
  includes the time a Bead waited. Open Beads are excluded from both. A closed Bead with no
  `started_at` is left out of the cycle time and counted ("N closed Beads have no start time"). A
  close before the start is left out and counted too.
- The **median** of an even number of values is the mean of the two middle ones. The **p90** is the
  nearest rank: the value at position ceil(0.9 n) of the sorted values.
- The range filters the closed Beads by their close time. Status counts and project age always
  describe the present.
- **Days are UTC days**, so a Bead closed at 01:00 local time may land on the previous chart day.
  Timestamps elsewhere show in the browser's local time.
- **Reopened Beads** are not visible: the Bead list holds the latest close only, so a reopened and
  re-closed Bead counts once, on its last close day.
- A closed Bead without a `closed_at` is counted apart ("have no close time") and left out of the
  chart.
- `assignee` is never shown as who worked on a Bead.

Switching the range refetches one cached response; it starts no subprocess. A change in a source
refetches the page without rebuilding it.

## Usage

Five more panels sit under the first six on the start page. They read the same
`/api/v1/summary?range=…` response, follow the same range and Day or Week controls, and have the
same **Table** button. Their sources are Sessions, Tokens, Git and Tests, so on a host or in a
repository that lacks one, that panel reads "Not available here" and shows no number.

| Panel | Shows | Source |
|---|---|---|
| Agent-hours | Hours of finished sessions per UTC day or week, how many are running, planning sessions, and the orchestrator's hours on their own line. | Sessions |
| Agents, models and tiers | Per agent: sessions, running, hours, the models **requested** at launch and the selection tiers. Apart, the models **observed** in usage with their known tokens. | Sessions, Tokens |
| Token usage | "Known: N" (fresh input plus output) with a per-runtime chart, and each runtime's own first record. | Tokens |
| Commits and changed lines | Commits that carry a Bead token and their production and test lines, plus a count of commits that carry none. | Git |
| Test cost | Runs, failures, total and median time per `nogg test` stage, and the seconds per day. | Tests |

### What the numbers mean here

- **Agent-hours** are `ended_at - started_at` of finished sessions, counted on the UTC day a session
  started. Parallel sessions add up, so the figure is *never* elapsed time. A session with no
  `ended_at` is **running**: it is counted ("N running", whatever the range, since it describes the
  present) and adds nothing to the hours. A session that ends before it starts, or has no start, is
  left out and counted. Planning sessions count in the hours but have no Bead, so they appear in no
  Bead's detail.
- **Orchestrator hours** are reported on their own line and are not in the headline: an always-on
  session would otherwise swamp every other figure.
- **Session records are local to this host.** The panel says so and names the date its records start.
- **Requested versus observed models.** A session record says which model was *asked for* and its
  selection tier; the usage store says which model *ran*. They are two lists on purpose. A missing
  tier reads "Not recorded" and is not guessed. The observed list covers the whole history, not the
  range.
- **Tokens** are `fresh_input + output` of the counters the records prove, and read "Known: N". A
  counter nobody could prove marks the sum with "+?" and the day with "(unknown counters)", and is
  never counted as zero. The provider's own total is not used. There is no cost and no quota
  percentage anywhere. Runtimes with partial data (Pi and Antigravity today) are named under the
  chart. Batches that wait in the spool are counted and say they are not in the numbers.
- **Commits** are those whose subject carries a token shaped like a Bead ID, on all branches,
  remotes and tags, so they may include unmerged work. A rebased copy counts once. Commits with no
  token are one count for the whole history. A commit whose line counts are missing is counted and
  adds no lines.
- **Test cost** sums the seconds of runs that finished (passed or failed). A stage with no run in the
  range reads "No run", never "0 s". Old records rotate away, so the panel says *Records kept from*
  the date of the earliest one: earlier days are missing, not free.

### Gaps

The rules of the first six panels hold here. Each series starts at its own floor, computed from the
records: the earliest session start, token fact per runtime, retained test record, or Bead-token
commit. When the chosen range opens before the floor, the early days are a hatched band that reads
"No data before {date}", never a bar of height zero. From the floor on, a day with no record is a
real zero because the source covers it. Stale tokens (the collector was busy, or a read failed) keep
their last values, and the panel's freshness line reads "data may be stale" with the time of the last
update. A source that is loading shows a loading panel, not empty numbers.

## Graph

The graph tab shows the dependencies of one change as a flow from left to right. Choose a change
from the list, or open `#/graph?scope=change&id=<change>`. Other scopes follow under
[Graph navigation](#graph-navigation).

The server computes the layout and the page only draws it, so the same data always gives the same
picture, on a desktop and on a phone alike.

**What you see.** Each Bead is a box with its ID, its title and the shape of its status. Only
`blocks` dependencies count: a blocker sits to the left of what it blocks, and other dependency
types appear in the detail panel only. Work that can run side by side falls into parallel lanes.
A Bead outside the change appears as a dashed ghost one step out, and only when it blocks or is
blocked by a Bead of the change. Unconnected parts stack from top to bottom, the largest first, with
Beads that have no dependency in a compact block at the end. Selecting a Bead opens its detail.

**The longest dependency chain.** The thick line is the chain with the most Beads, counted over
Beads that are not closed, or over all Beads once the change is finished. It sits on the top lane
of its part of the graph. A tie goes to the higher sum of `[~N loc]` estimates in the titles, then to
the lower ID. It is a count of steps in the dependencies and not a time estimate.

**Closed Beads** are faded, with an unfaded label. *Collapse closed Beads* folds them into one
group per layer, with at most 20 groups; a dependency that would run backwards after folding is left
out of the picture, so a group cannot look like a cycle.

**At most 80 nodes.** A larger scope collapses its closed Beads first. If it is still too large, the
longest chain stays, then the groups, then active work before waiting work, and ghosts leave first.
The page states how many of the nodes are hidden.

**Cycles.** A warning shows whatever `bd dep cycles` reports, also for a cycle outside the change.
When the change itself contains a cycle or a self-loop, the graph still renders: the layout turns
one edge around and draws it dashed, and no longest chain is marked, because a cycle has no longest
path. The page says so.

The answer of `GET /api/v1/graph?scope=change:<id>&closed=show|collapse` holds positions in abstract
units: `x` is the layer and `y` a row, and the client scales both to its node size. A malformed query
answers 400. Layouts are kept in memory, at most 32, and only until Beads change.

## Graph navigation

The graph opens on the **ready frontier**: the Beads that `bd ready` returns, which is small and
shows what can start now. Three scopes are one tap apart, and the route carries the scope, so a link
or a reload keeps it.

| Scope | Route | Shows |
|---|---|---|
| Ready frontier (default) | `#/graph` or `#/graph?scope=ready` | the Beads `bd ready` returns, and the `blocks` edges between them |
| Neighbourhood of a Bead | `#/graph?scope=bead&id=<ID>&depth=<1 to 5>` | the Beads that block it, up to `depth` steps upstream, and the Beads it blocks, up to `depth` steps downstream |
| One change | `#/graph?scope=change&id=<change>` | the flow described above; without an `id` it lists the changes |

The neighbourhood follows the blockers and the blocked Beads on their own, so a Bead that merely
shares a blocker with the centre does not appear. The centre has a thicker outline. "Open in graph"
in a Bead's detail links to the neighbourhood at depth 2. A Bead ID the data does not hold shows an
empty graph. Closed Beads collapse and expand as in a change: activate a *3 closed Beads* group, or
use *Show closed Beads*, to see them. The 80-node cap still applies, so a very large scope keeps
some Beads folded.

The API is `GET /api/v1/graph?scope=ready`, `scope=bead:<id>&depth=<n>` or `scope=change:<id>`, each
with `closed=show|collapse`. The depth counts only for `bead:` and defaults to 1, and a depth outside
1 to 5 answers 400.

**Mouse.** Drag pans, a click selects a Bead and opens its detail, and the wheel zooms at the cursor.

**Touch.** One finger pans, two fingers pinch to zoom, a tap selects, and a double tap zooms in 2×.
The graph area takes the touch, so the page does not scroll or zoom there. On a phone held upright the first view keeps the height of the
flow and starts at the first layer with open work. *Layer 2 of 7* with the two arrows beside it moves
one layer at a time.

**Keyboard.** Focus the graph, then the arrow keys move between Beads, Shift with an arrow pans, `+`
and `-` zoom, `0` fits the graph to the screen, and Enter opens the detail of the focused Bead.

**Buttons.** *Zoom in*, *Zoom out* and *Fit* are 44 pixels high. *Show list* swaps the picture for an
ordered list in dependency order, each Bead with its status and "Blocked by: …". It carries the same
information for a screen reader. With `prefers-reduced-motion` set, zooming and panning jump instead
of gliding.
