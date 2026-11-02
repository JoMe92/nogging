## MODIFIED Requirements

### Requirement: The dashboard is an optional foreground command

`nogg dashboard` SHALL start a foreground web server for the current repository and SHALL stop on
SIGINT or SIGTERM. It SHALL read the canonical checkout's state from any linked worktree. It SHALL
write no configuration key and leave no process behind. It SHALL install a service unit only through
`nogg dashboard service enable`, never through `init`, `update` or any other command. Nothing else
in Nogging SHALL depend on it. A port already in use SHALL end the command with a message naming
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

#### Scenario: The installer writes no dashboard unit

- **WHEN** `init` or `update` runs in a repository with systemd
- **THEN** no `nogg-dashboard-<slug>.service` is rendered or suggested for enabling

### Requirement: The server binds to private addresses only

The default bind address SHALL be `127.0.0.1`. `--bind <address>` SHALL accept only a literal IP
address inside an explicit allow-list: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`,
`192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`, `::1/128`, `fc00::/7`, and `fe80::/10` with a
zone. The decision SHALL NOT use the `is_private` or `is_global` properties of Python's
`ipaddress` module. It SHALL refuse wildcard addresses, IPv4-mapped IPv6 addresses, hostnames and
every other address before any socket opens, and the error SHALL name the refused value and how to
list eligible addresses. `--list-binds` SHALL print this host's eligible addresses as a hint, and
that output SHALL NOT feed the bind decision.

A non-loopback bind SHALL be refused inside a supervised session, whether or not an operator consent
exists and whether or not a pairing link is open. Outside a supervised session, a non-loopback
`--bind` SHALL be refused unless the operator-terminal test holds. The consented service is the only
network start that needs no operator terminal. These refusals SHALL happen before any socket opens
and before a secret is created. A non-loopback run that starts SHALL append a `started` audit event,
and a `stopped` event when it ends.

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

#### Scenario: A consent does not lift the session refusal

- **WHEN** a valid operator consent exists, or a pairing link is open on a running service, and a
  supervised session runs `nogg dashboard --bind <the consented address>`
- **THEN** the command refuses it with the same message, and creates no secret

#### Scenario: A network bind without a terminal

- **WHEN** `nogg dashboard --bind <private address>` runs outside a supervised session with stdin
  that is not a terminal, as under `systemd-run`, `nohup` or with the session variable removed
- **THEN** the command refuses it, names `nogg dashboard service enable`, opens no socket and
  creates no secret

#### Scenario: A pseudo-terminal outside a login session

- **WHEN** `nogg dashboard --bind <private address>` runs with a pseudo-terminal on stdin and stdout
  in a cgroup that is not a login session scope, as under `systemd-run --user --pty`
- **THEN** the command refuses it and prints no token and no link

#### Scenario: A terminal with piped output

- **WHEN** the operator runs `nogg dashboard --bind <private address> | tee out.txt` on a terminal
- **THEN** the server starts as before and does not print the link

### Requirement: A non-loopback bind requires an access token

A non-loopback bind SHALL require an access token, a session cookie, or a redeemed pairing link for
every route except the data-free shell, its static assets and the unauthorized page. The secret
SHALL be at least 256 bits from `secrets`, stored in `<state>/dashboard/secret` with mode `0600`
inside a `0700` directory, and SHALL survive a restart. A secret file with wider permissions SHALL be
refused. `--rotate-token` SHALL replace the secret and invalidate every existing browser session and
every open pairing link. Token comparison SHALL be constant-time on bytes. Failed authentications
SHALL be limited to ten per minute, after which the server SHALL answer 429 with `Retry-After`. A
loopback bind SHALL need no token.

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
- **THEN** cookies issued before the rotation are rejected, and an open pairing link reads as
  expired

#### Scenario: A loopback client

- **WHEN** a client calls `/api/v1/summary` on the default loopback bind
- **THEN** the server answers without a token

### Requirement: The link is opened once and then remembered

On a non-loopback bind started on a terminal, the command SHALL print a link that carries the token
in the URL fragment, only when stdout is a terminal. It MAY also print a terminal QR code when
`qrencode` is on `PATH`, passing the link on stdin. The consented service SHALL never print the
token link. The shell SHALL read a `#token=` or `#pair=` fragment, remove it with
`history.replaceState` before any request, and call `/api/v1/auth` with an `Authorization: Bearer`
or `Authorization: Pairing` header. The server SHALL answer with a signed, expiring cookie that is not
the token itself, set `HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000`, with the port in the
cookie name. A pairing link SHALL yield the same cookie as the token.

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

#### Scenario: The service prints no token

- **WHEN** the consented service starts
- **THEN** its output names its address and `nogg dashboard pair`, and holds neither the token nor
  a link

### Requirement: The dashboard adds no state

The dashboard SHALL add no Bead, dependency, fact, commit or configuration. Its only files SHALL be
the access secret, created on the first non-loopback start, on `service enable` or on token rotation;
the consent record and the user unit, written only by `service enable` and removed by `service
disable`; the append-only audit trail; and the control socket of a running service, removed when it
stops. The audit trail SHALL be the only file a request may write to, one line per event in a single
append. Every `bd` call SHALL use `--readonly --sandbox` with a timeout, and the process SHALL set
`BEADS_DOLT_AUTO_START=0` and `GIT_OPTIONAL_LOCKS=0`. It SHALL NOT start, stop or restart Dolt, run
usage collection, drain the usage spool, run `doctor`, or persist any snapshot to disk. A request
SHALL be served from memory and SHALL NOT start a subprocess.

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

- **WHEN** a terminal network run has refreshed every source
- **THEN** the secret file and the audit trail are the only files it has created

### Requirement: The dashboard ships with init and update and stays quiet when unused

`init` and `update` SHALL install the modules and static assets, binary fonts included, and `remove`
SHALL remove them. Tests SHALL NOT ship. The Poppins licence SHALL ship beside the fonts. `doctor`
SHALL print nothing about the dashboard unless the secret, the consent record or the user unit
exists. It SHALL warn when the secret or the consent is wider than `0600`, and when the unit exists
or runs without a valid consent. It SHALL note an enabled service with a matching consent and name
its address. `remove` SHALL tell the operator to run `nogg dashboard service disable` while the
service is enabled. No configuration key SHALL be required.

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

#### Scenario: Doctor with a unit and no consent

- **WHEN** `nogg-dashboard-<slug>.service` exists or is active and no valid consent record exists
- **THEN** `doctor` warns and names `nogg dashboard service disable`

#### Scenario: Doctor with a consented service

- **WHEN** the service is enabled with a matching consent
- **THEN** `doctor` prints a note naming the address and port, and no warning

#### Scenario: Remove with the service enabled

- **WHEN** `remove` runs while `nogg-dashboard-<slug>.service` is enabled
- **THEN** its next steps tell the operator to run `nogg dashboard service disable` first

## ADDED Requirements

### Requirement: A network exposure without a terminal needs the operator's recorded consent

`nogg dashboard service enable --bind <address> [--port <n>] [--allow-host <host[:port]>]` SHALL be
the only way to create an exposure that runs without a terminal. It SHALL refuse unless the
operator-terminal test holds and stdout is a terminal. It SHALL refuse a loopback or
disallowed address with the bind policy's message, and SHALL print the plain-HTTP and carrier-NAT
warnings for the address. It SHALL read one line from the terminal and continue only when that line
equals the address. It SHALL then write `<state>/dashboard/consent.json` atomically with mode
`0600`, holding the bind, port, allow-hosts, the time and the terminal name. It SHALL create the
secret if missing, write `nogg-dashboard-<slug>.service` into the user unit directory, enable and
start it, and append a `consent` audit event. The unit and its working directory SHALL be those of
the canonical checkout. It SHALL note when user lingering is off and warn when the control socket
path would be too long. On a host
without `systemctl` it SHALL refuse and name the terminal run. Nothing written by `enable` SHALL
contain the secret.

#### Scenario: The operator enables the service

- **WHEN** the operator runs `nogg dashboard service enable --bind 100.86.79.27` on a terminal and
  types `100.86.79.27`
- **THEN** the consent record is written with mode `0600`, the unit is written, enabled and started,
  and the audit trail has a `consent` event

#### Scenario: A mistyped confirmation

- **WHEN** the typed line differs from the address
- **THEN** nothing is written and `systemctl` is not called

#### Scenario: A session asks to enable

- **WHEN** `service enable` runs inside a supervised session, the Orchestration Agent's included
- **THEN** it refuses, writes nothing and calls no `systemctl`

#### Scenario: No terminal

- **WHEN** `service enable` runs with stdin or stdout that is not a terminal, or outside a login
  session scope
- **THEN** it refuses, writes nothing and calls no `systemctl`

#### Scenario: A host without systemctl

- **WHEN** `service enable` runs on a host without `systemctl`
- **THEN** it refuses, writes nothing, and names the terminal run

#### Scenario: The secret stays out of the unit

- **WHEN** the service is enabled
- **THEN** neither the unit, the consent record nor the command line of the service contains the
  secret

### Requirement: The consented service binds exactly what was consented

`nogg dashboard service run` SHALL be what the unit runs. It SHALL take no bind option. It SHALL refuse
inside a supervised session, and, where cgroups are readable, outside the cgroup of
`nogg-dashboard-<slug>.service`. It SHALL refuse unless the consent record exists, is a regular file
with mode `0600` owned by the operator, matches its schema, and its bind and allow-hosts pass the
bind policy again. A refusal that waiting cannot cure SHALL exit 78. It SHALL serve exactly the
consented bind, port and allow-hosts, bind TCP before it opens the control socket, and print no token
and no link. The unit SHALL restart the service on failure with no start limit, so a bind address
that is not up yet at boot is tried again, SHALL NOT restart it after exit 78 or 203, and SHALL
disable core dumps. `nogg dashboard service
disable` SHALL stop and disable the unit, remove the unit file and the consent record, and append a
`revoked` audit event. It SHALL be allowed from the operator's terminal and from the proven
Orchestration Agent, and refused for every other supervised session. Disabling an already disabled
service SHALL succeed.

#### Scenario: No consent

- **WHEN** `service run` starts and no consent record exists
- **THEN** it exits non-zero, names `nogg dashboard service enable`, and opens no socket

#### Scenario: A tampered consent

- **WHEN** the consent record has mode `0644`, or names `8.8.8.8` or `0.0.0.0`
- **THEN** `service run` exits 78 and opens no socket

#### Scenario: A start beside the unit

- **WHEN** `service run` starts from a cgroup other than the unit's, as under `systemd-run`
- **THEN** it exits 78, opens no socket, and leaves a running service's control socket in place

#### Scenario: The service inside a session

- **WHEN** `service run` runs inside a proven supervised session with a valid consent
- **THEN** it refuses with the supervised-session message

#### Scenario: The orchestrator switches it off

- **WHEN** the proven Orchestration Agent runs `nogg dashboard service disable`
- **THEN** the unit is stopped, disabled and removed, the consent is gone, and a `revoked` event
  names the orchestrator

#### Scenario: A Lead tries to switch it off

- **WHEN** a Lead session runs `service disable`
- **THEN** it refuses and nothing changes

#### Scenario: Disabled twice

- **WHEN** `service disable` runs when no service is enabled
- **THEN** it succeeds and changes nothing

### Requirement: A one-time pairing link signs a phone in

`nogg dashboard pair` SHALL ask the running consented service, over its control socket, for a pairing
link. The service SHALL mint a code of at least 128 bits from `secrets`, keep only its SHA-256 hash in
memory together with its expiry and a hash of the current secret, and return
`http://<bind host>:<port>/#pair=<code>` with its expiry. A code SHALL be valid for five minutes, for
one successful redemption, and only on the server process that minted it and only under the secret
that was current when it was minted. At most three links SHALL be open at once, and a fourth SHALL
end the oldest. A redemption SHALL happen only on a GET of `/api/v1/auth` with `Authorization:
Pairing <code>`, which SHALL read the secret once and use that value both to check the code and to
sign the cookie. A HEAD, a missing or refused secret, or a server without a pairing store SHALL never
consume a code. A successful redemption SHALL set the same signed cookie as the token, and the server
SHALL keep a hash of that cookie and the peer address with the used code. A used code SHALL never
yield a cookie. A used code sent with exactly the cookie its redemption issued SHALL be answered 200
quietly. A used code sent with any other valid cookie SHALL be answered 200 without a new cookie and
with a `used_elsewhere` notice. A used code without a valid cookie SHALL be answered 401
`pairing_used`. Both used answers SHALL say whether the peer address equals the redeeming one and
SHALL record `link_replayed` once per code. An expired code SHALL be answered 401 `pairing_expired`.
Used and expired codes SHALL NOT count as failed attempts. An unknown code SHALL
count as a failed attempt under the existing limit. A correct open code SHALL never be limited. The
code SHALL never be written to a file or log.

#### Scenario: The Product Owner opens a pairing link

- **WHEN** a phone opens a freshly minted pairing link
- **THEN** the fragment is removed before the request, the response sets the dashboard cookie, and
  data loads

#### Scenario: The link is opened twice from different browsers

- **WHEN** a second browser without a cookie redeems a code that was already redeemed
- **THEN** it gets 401 `pairing_used`, no cookie, and a `link_replayed` audit event is written once

#### Scenario: Two redemptions race

- **WHEN** two requests redeem the same open code at the same time
- **THEN** exactly one response sets a cookie

#### Scenario: The same phone taps the link again

- **WHEN** the browser that redeemed a code sends it again with the cookie it received
- **THEN** the server answers 200, sets no new cookie and records nothing

#### Scenario: A lost race on a phone that was already signed in

- **WHEN** another browser redeemed the code first and the Product Owner's browser sends it with an
  older valid cookie
- **THEN** the server answers 200 with the `used_elsewhere` notice and `same_peer` false, and records
  `link_replayed`

#### Scenario: A rotation during a redemption

- **WHEN** the secret is rotated while a code minted under the old secret is being redeemed
- **THEN** no cookie signed by the new secret is issued for that code

#### Scenario: The link has expired

- **WHEN** a code is redeemed more than five minutes after it was minted
- **THEN** the server answers 401 `pairing_expired` and the failure count is unchanged

#### Scenario: A HEAD request or a preview

- **WHEN** a HEAD of `/api/v1/auth` carries an open code
- **THEN** the code is not consumed and a later GET still redeems it

#### Scenario: The server restarts

- **WHEN** the service restarts after a code was minted and before it was used
- **THEN** the code is unknown to the new process and yields no cookie

#### Scenario: Guessing under the limiter

- **WHEN** ten unknown codes arrive within a minute and then the real open code arrives
- **THEN** the unknown codes get 401 and then 429, and the real code still sets the cookie

#### Scenario: A fourth link

- **WHEN** a fourth link is minted while three are open
- **THEN** the oldest reads as expired and `pair` says that it ended one link

#### Scenario: A terminal run has no pairing

- **WHEN** a pairing code is sent to a network bind started on a terminal
- **THEN** it is treated as a wrong credential

### Requirement: Only the operator or the Orchestration Agent mints a link

`nogg dashboard pair` SHALL be allowed from a proven supervised session with role `orchestrator` and
when the operator-terminal test holds. It SHALL refuse every other caller
before connecting, including Lead, planning, specialist and loop sessions, an unproven session name
and an unproven process without a terminal. It SHALL print the link and its expiry on stdout whether
or not stdout is a terminal. When no service is running it SHALL say so and name the one terminal
command that enables it. The control socket SHALL be a Unix stream socket in the `0700` dashboard
state directory with mode `0600`. It SHALL answer only a peer whose uid equals the server's, read as
`(pid, uid, gid)` from `SO_PEERCRED`. It SHALL take one request of at most 1 KiB within 2 seconds
per connection, and SHALL never return a code hash, the secret or a cookie, only the minted link. A
server SHALL remove a stale socket at its path only when that socket refuses connections, SHALL not
remove a non-socket or a live socket there, and SHALL remove its own socket when it stops, SIGTERM
included.

#### Scenario: The Orchestration Agent mints a link

- **WHEN** the proven Orchestration Agent runs `nogg dashboard pair` while the service runs
- **THEN** it prints one link with its expiry, and a `link_minted` event names the orchestrator and
  the peer pid

#### Scenario: A Lead asks for a link

- **WHEN** a Lead session runs `nogg dashboard pair`
- **THEN** it refuses and opens no connection

#### Scenario: An unproven process without a terminal

- **WHEN** `pair` runs with no session proof and stdin that is not a terminal
- **THEN** it refuses and opens no connection

#### Scenario: No service runs

- **WHEN** the Orchestration Agent runs `pair` and no service is running
- **THEN** it exits non-zero and names `nogg dashboard service enable --bind <address>` on a terminal

#### Scenario: The operator mints a link on a terminal

- **WHEN** the operator runs `nogg dashboard pair` on a login terminal while the service runs
- **THEN** it prints one link, and `link_minted` names `operator`

#### Scenario: The socket path is taken

- **WHEN** the control socket path holds a regular file, or a socket that accepts connections
- **THEN** the service does not remove it and serves without pairing, and `status` says why

#### Scenario: A slow control client

- **WHEN** a client connects to the control socket and sends nothing, or more than 1 KiB
- **THEN** the server closes it within 2 seconds and the next `pair` succeeds

#### Scenario: Another user connects

- **WHEN** a peer with another uid connects to the control socket
- **THEN** the connection closes with no answer and nothing is minted

### Requirement: Exposure and pairing are recorded

The dashboard SHALL append `consent`, `revoked`, `started`, `stopped`, `link_minted`, `link_redeemed`,
`link_replayed` and `rotated` events to `<state>/dashboard/audit.jsonl`. The file SHALL have mode
`0600` and SHALL be opened for append, one write per line. The service SHALL print each event it
appends to stdout, and the CLI SHALL also send its own events through `systemd-cat` when that
exists. An
event SHALL hold its time, its kind and only these fields: bind, port and terminal name for `consent`;
the caller for `revoked`; the mode (`service` or `terminal`), bind, port and pid for `started`, plus
the consent's time and terminal for a service; the caller, the peer pid, the expiry and
an 8-hex-digit identifier from the code's hash for `link_minted`; the identifier and the peer address
for `link_redeemed` and `link_replayed`. No event SHALL hold a code, the secret, a cookie or a full
hash. A mint whose event cannot be written SHALL fail and return no link. `nogg dashboard status`
SHALL print the consent or that none exists, the unit's enabled and active state, the running
service's open-link count and earliest expiry, whether the cgroup test applies and whether the
journal is persistent, and the last ten events, and SHALL write nothing. `--rotate-token` SHALL
append `rotated`.

#### Scenario: A full login is traceable

- **WHEN** the Orchestration Agent mints a link and the phone redeems it
- **THEN** the audit trail holds `link_minted` and `link_redeemed` with the same identifier, and
  neither line contains the code

#### Scenario: Status from anywhere

- **WHEN** any session runs `nogg dashboard status`
- **THEN** it prints the exposure and the last events, and no file changes

#### Scenario: A terminal run is recorded

- **WHEN** the operator starts `nogg dashboard --bind <private address>` on a login terminal and
  stops it
- **THEN** the audit trail holds `started` with mode `terminal` and then `stopped`, without the token

#### Scenario: The token is rotated from the chat

- **WHEN** the Orchestration Agent runs `nogg dashboard --rotate-token`
- **THEN** a `rotated` event is appended and the message names `nogg dashboard pair` when the service
  runs

#### Scenario: The audit trail cannot be written

- **WHEN** appending `link_minted` fails
- **THEN** `pair` exits non-zero and no link is returned

### Requirement: An operator terminal is a login session, not an agent's pseudo-terminal

The operator-terminal test SHALL hold only when the calling process is not a proven supervised
session and carries no unproven session name, stdin is a terminal, no ancestor process is the shared
Nogging session server (the tmux server of the configured socket or the herdr server), and, on a host
where `/proc/self/cgroup` and systemd exist, the process's cgroup is a logind session scope. The
server's pid SHALL be asked without starting a server. Where the cgroup condition cannot be checked,
the test SHALL skip it, and `status` and `doctor` SHALL say so. A refusal SHALL name the condition
that failed and suggest `ssh -t` for a remote command. The test SHALL gate a non-loopback `--bind`,
`service enable` and the operator path of `pair`.

#### Scenario: The operator in their own tmux

- **WHEN** the operator runs the command in a tmux server they started from an SSH login
- **THEN** the test holds

#### Scenario: A pane on the shared session server

- **WHEN** the command runs in a pane of the shared Nogging tmux server, opened with
  `tmux new-session -d`, with a pseudo-terminal and no session proof
- **THEN** the test fails and the refusal names the session server

#### Scenario: A remote command without a terminal

- **WHEN** the command runs through `ssh host ./scripts/nogg dashboard --bind <address>` without `-t`
- **THEN** the test fails and the refusal suggests `ssh -t`
