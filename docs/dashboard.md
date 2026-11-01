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
MagicDNS name. Repeat it for more names. It accepts no wildcard.

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
carries. The page trades it for a signed cookie valid for 30 days, then removes it
from the address bar and the history entry. The cookie is not the token, and the
token itself is never stored in the browser.

When output is not a terminal, no link is printed. A network bind is refused inside
a supervised session, because the link would reach the session log. Any network bind
outside `100.64.0.0/10` also prints a warning: the traffic is plain HTTP, so prefer a
Tailscale address for a phone.

```bash
./scripts/nogg dashboard --rotate-token
```

This replaces the secret and exits. Every browser session ends at once, in a
running dashboard too. Start a network bind on a terminal to print a new link.

A secret file wider than `0600` or a directory wider than `0700` refuses a network
start, and `nogg doctor` warns about it. A running server that finds its secret
gone or too open refuses every session until the file is fixed.

Ten failed authentications in a minute are answered with 429 and `Retry-After`. A
request with no credential at all is a plain 401, and a valid session is never
limited. See the [security model](security-model.md#the-dashboard) for what this
does not protect against.

## Interface

## Data

## Usage data

## Beads

## Detail

## Overview

## Usage

## Graph

## Graph navigation
