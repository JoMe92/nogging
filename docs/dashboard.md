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

## Usage data

## Beads

## Detail

## Overview

## Usage

## Graph

## Graph navigation
