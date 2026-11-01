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
`[SPEC-1cu]`, on all local and remote-tracking branches and tags, with its production and
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

## Detail

## Overview

## Usage

## Graph

## Graph navigation
