## Context

`beads-dashboard` delivered `nogg dashboard`: a foreground, read-only server that binds a
literal private address, needs a 256-bit token on a network bind, trades that token for a
signed 30-day cookie, and refuses a network bind inside a supervised session, because the
link printed with the token would reach the session log. All its Beads are closed. Its
acceptance report is unsigned, and rows 9 to 17, everything that needs a phone or a
browser, are open.

The Product Owner works from a phone through Remote Control. The Orchestration Agent is
the session they talk to. It runs under the `orchestrator` profile with the command floor
lifted and with `bypassPermissions`, so nothing mechanical stops it. What limits it is its
launch prompt plus visibility: the session list, the append-only log and the durable
record. The sessions it launches keep their `restricted` or `trusted` profiles.

Facts from the code that shape this design:

- `calling_session_record()` in `scripts/nogg` proves a session by process ancestry. When
  ancestry does not prove one and `NOGG_SESSION_NAME` is unset, it returns `None`, which
  callers read as "operator shell". So any process whose ancestry no longer leads to its
  session looks like the operator. `systemd-run --user …`, `tmux new-session -d …` and
  `setsid` all break ancestry, and so does a fenced process whose namespace check fails
  once it also drops the variable. The dashboard's refusal relies on this function, so it
  has the gap that the SPEC-0adz discovery reports for `nogg loop`.
- The secret lives in `<state>/dashboard/secret`, mode `0600`. Any process that runs as
  the operator's user can read it, as `docs/security-model.md` already states.
- `announce()` prints the token link only when stdout is a terminal. A network bind without
  a terminal is allowed today and prints no link. A network run is not recorded anywhere.
- The installer renders every unit in `manifest.systemd`, and `nextsteps.js` suggests
  enabling each one after `init` and `update`.

## Goals / Non-Goals

**Goals**

- The Product Owner gets the dashboard onto the phone from a chat with the Orchestrator,
  with no terminal after a one-time setup.
- No path that Nogging provides puts the long-lived secret into a log, transcript, command
  line, Bead, commit, chat or process listing.
- No agent can start a network exposure through Nogging. An exposure exists only as the
  operator's recorded decision, in one form that is listed, stoppable and auditable.
- The old refusal still holds, and the plain ways around it close for the dashboard.

**Non-Goals**

- TLS, internet exposure, a hostname bind, or a wider bind allow-list.
- Any change to the HTTP response policy, the cookie, the failure limiter or the loopback
  run.
- Making a same-user process unable to read the secret or to obtain a terminal. That needs a
  second user or root, and Nogging uses neither (Decision 2).
- Retiring the token link of a terminal run. See *Open Questions*.
- Running the open acceptance rows of `beads-dashboard`, or archiving it.

## Decisions

### Decision 1: A new change, archived after `beads-dashboard`

This is a new change, `dashboard-phone-access`, and not a revision of `beads-dashboard`.
`beads-dashboard` is merged with every Bead closed. Rows 1 to 8 of its report describe
code that stays as it was, and rows 9 to 17 describe behaviour this change keeps. A
revision would reopen a delivered change and mix a security decision into a report that
covers something else. A new change gets its own Beads, its own `[security]` reviews and
its own acceptance report.

The `dashboard` capability exists only inside `beads-dashboard` until that change is
archived, and this change modifies requirements that `beads-dashboard` adds. So
**`beads-dashboard` must be archived before this change.** In the other order, the
`MODIFIED` requirements have nothing to replace. Implementation can start now, because the
code of `beads-dashboard` is on `develop`. Whoever archives the two runs the scratch
rehearsal again: both archives in order on a copy, then `openspec validate --all
--strict`. The *Rehearsal* section below records the planning-time result. This change does
not archive `beads-dashboard`.

### Decision 2: What the boundary is, and what it is not

| Who | Today | After this change |
|---|---|---|
| The operator at a login terminal (console or SSH, also inside their own tmux) | May bind a network address and sees the token link | Unchanged, and the run is now recorded. May also enable the service once |
| A proven supervised session (Lead, planner, specialist, loop, orchestrator) | Refused | Refused, with or without consent or an open link (Decision 4) |
| A process that breaks its ancestry: `systemd-run`, `systemd-run --pty`, `nohup`, `setsid`, `tmux new-session -d` on the shared server, a dropped session variable after a failed proof | Passes as the operator; with a pseudo-terminal it even sees the token link | Refused by the operator-terminal test (Decision 4) |
| A process running as the operator's user that opens a new login session (`ssh -t localhost`), writes the state files directly, or reads the secret file | Can do anything the operator can | Unchanged. Nogging cannot stop this |

The last row is the honest limit. Nogging runs every agent as the operator's own user. A
`trusted` session or the floor-lifted Orchestrator really can read and write any file that
user owns, and can log in to its own host. No file mode, signature, terminal or cgroup check
defends against that: a signature would need a key the same process can read, and a login
session looks the same to the kernel whoever opened it. This change does not claim
otherwise. It does three things:

- It closes every path a *Nogging command* offers: a wrong command, a call without a
  terminal, a detached start, or a new window on the shared session server no longer exposes
  anything or prints a token.
- It keeps the one *legitimate* path behind an act at a login terminal that a person
  performs and confirms by typing.
- It records every network start, consent, revocation and login in an append-only trail and,
  where the host keeps one, in the journal (Decision 10). `status`, `doctor` and the
  Orchestrator's prompt look at that trail.

A `restricted` Claude or Codex session cannot write the main checkout's `.nogging/state/`,
because its sandbox does not reach that path. A `restricted` Pi session has no sandbox and
relies on the guard extension and the rules above. `docs/security-model.md` gains these
rows.

### Decision 3: Recommendation: a consented user service plus one-time pairing links

The brief names three options. They answer two separate questions: **who starts the
listener** and **how the phone logs in**.

- **Option 2: a host-local consent that lets a supervised session start the bind.** It
  needs a new kind of supervised session that runs no agent, and an exception to the old
  refusal ("refused in a session, unless …"). After the one-time consent, every exposure
  would start on an agent's initiative. It also adds a role to the session list, the
  dispatcher and `watch`. This option is rejected.
- **Option 3: a user service enabled once by the operator.** The operator's act at the
  terminal *is* the decision, and the bind is fixed in it. The old refusal stays exactly as
  it is, because no session starts the bind. systemd lists, stops and restarts the service.
  Nogging already runs the Orchestrator this way. The cost is a listener that stays up
  while the service is enabled. That is acceptable: every data route needs a credential,
  the shell holds no data, the refresher idles after five minutes without requests, and the
  server then holds about 100 MB on the delivery host.
- **Option 1: a one-time pairing link.** This is how the phone logs in without the long-lived
  token. It needs a running server to bind the link to, which option 3 provides.

**Recommended: option 3 for the listener, option 1 for the login.** The Orchestrator can
mint a link but cannot open a listener. The operator opens the listener once and never has
to hand the token to anyone.

A Remote Control permission prompt as the consent was also considered. A tap on the phone
would be a real out-of-band act, but the Orchestrator runs with `bypassPermissions`, so it
sees no prompt, and its claims could not be told apart from a real tap. This can be
revisited if the Orchestrator ever runs with prompts.

### Decision 4: The operator-terminal test and the unchanged refusal

One predicate, `operator_terminal()`, decides "a person at a login terminal". It is true
only when all of these hold:

1. `calling_session_record(...)` returns `None`. A proven session, and a made-up session
   name, fail as today.
2. stdin is a terminal. This is what `nohup`, plain `systemd-run`, `setsid … </dev/null` and
   an agent's ordinary tool call lack. Stdout is not tested, so `nogg dashboard --bind … |
   tee` on a terminal still works.
3. Where `/proc/self/cgroup` exists and the host runs systemd: the process's cgroup ends in a
   logind session scope (`session-<id>.scope`). A console or SSH login, and an operator's
   own tmux started from it, are inside one. `systemd-run --user --pty` lands in
   `app.slice` and a unit lands in its service, so both fail. On a host without them the
   test is skipped, and `status` and `doctor` say so.
4. No ancestor process is the shared Nogging session server: the tmux server of the
   configured `session_tmux_socket`, or the herdr server. A pane that an agent opened on that
   server with `tmux new-session -d` therefore fails, even when the server was born inside a
   login session. The server pid is asked through the backend without starting it.

`dashboard_command` checks, in this order, and refuses before any socket opens and before a
secret is created:

1. `check_bind` and `check_allow_host`, as today.
2. A loopback bind continues unchanged.
3. A proven supervised session: refuse with the current message, unchanged.
4. `operator_terminal()` is false: refuse with *"refusing --bind <address> outside an
   operator terminal: a network bind runs in the foreground on a login terminal, or as the
   consented service (`nogg dashboard service enable` on a terminal)"*. The message names
   which condition failed and suggests `ssh -t` for a remote command.
5. Serve as today. The token link and QR code stay as before. The run appends `started` with
   `mode: terminal` to the audit trail, and `stopped` when it ends.

The same predicate gates `service enable`, which also needs stdout to be a terminal, and the
operator path of `pair` (Decision 9). The predicate does not stop a same-user process that
opens a real login session (Decision 2).

### Decision 5: Consent and the unit

`nogg dashboard service enable --bind <address> [--port <n>] [--allow-host <h>]…`

- Refuses unless `operator_terminal()` holds and stdout is a terminal.
- Checks the address with `check_bind`. A loopback address is refused, because loopback needs
  no service. It prints the plain-HTTP note or warning, and the carrier-NAT warning of
  `--list-binds` for this address.
- Prints what will happen, then reads one line from `/dev/tty` and requires that line to equal
  the address. Anything else aborts and writes nothing.
- Writes `<state>/dashboard/consent.json` atomically, with mode `0600` inside the `0700`
  directory: `{"schema": "nogg.dashboard.consent/v1", "bind", "port", "allow_hosts", "at",
  "tty"}`. `tty` is the terminal's device name. The record holds no personal address.
- Creates the secret if missing, so the first start does not race to create it.
- Writes `~/.config/systemd/user/nogg-dashboard-<slug>.service` from a template in
  `dashboard_service.py`. `<slug>` and `WORKDIR` come from the canonical checkout, so a
  linked worktree writes the same unit. Then it runs `systemctl --user daemon-reload` and
  `systemctl --user enable --now nogg-dashboard-<slug>.service` and appends `consent`.
- Notes when user lingering is off, because the service then stops at logout. It reuses
  `_linger_on()`. It warns when the control socket path would be too long (Decision 8).
- On a host without `systemctl` it refuses and names the terminal run as the way that still
  works. A second `enable` replaces the consent and restarts the service. That is a new
  decision with its own audit line.

The unit:

```ini
[Unit]
Description=Nogging dashboard on a consented private address ({{NAME}})
After=default.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory="{{WORKDIR}}"
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
UMask=0077
LimitCORE=0
ExecStart="{{WORKDIR}}/scripts/nogg" dashboard service run
Restart=on-failure
RestartSec=30
RestartPreventExitStatus=78 203

[Install]
WantedBy=default.target
```

- `Restart=on-failure` with no start limit covers a Tailscale address that is not up yet at
  boot. That start fails with "not assigned to this host" and is tried again every 30 seconds.
- A refusal that waiting cannot cure exits 78 (`EX_CONFIG`): no consent, a tampered consent,
  or a start outside the unit. A missing `scripts/nogg`, for example after `remove`, exits
  203. Neither is retried, so a broken setup does not loop forever.
- `LimitCORE=0` keeps the secret out of a core dump. A clean `systemctl --user stop` is not
  undone by a restart.

`service enable` writes the unit, and the installer does not. The unit is not in
`manifest.systemd`, so `init` and `update` never render it and never suggest enabling it.
`nextsteps.js` adds one `remove` item when `nogg-dashboard-<slug>.service` is enabled: *"Run
`./scripts/nogg dashboard service disable` before removing"*.

`nogg dashboard service disable` runs `systemctl --user disable --now`, deletes the unit file
and the consent, runs `daemon-reload`, and appends `revoked`. It may run under
`operator_terminal()` or from the proven Orchestrator, since ending an exposure is always
allowed to the session the Product Owner talks to. Every other session is refused. Disabling
twice is not an error. A new exposure afterwards needs `enable` at a terminal again.

`nogg dashboard service run` is what the unit runs. It takes no bind option and checks:

1. It is refused in a proven supervised session, with the old message.
2. Where cgroups are readable, it is refused unless its own cgroup is
   `nogg-dashboard-<slug>.service`. A `systemd-run` or a pane cannot start it, which also
   stops it from undoing an operator's `systemctl stop` from the side.
3. It reads the consent. The file must exist and be a regular `0600` file owned by the
   operator. It must match its schema, and its bind and allow-hosts must pass the policy
   again. Otherwise it exits 78 and names the remedy.
4. It serves exactly the consented values. It binds TCP first and only then opens the
   control socket (Decision 8). It prints its address and a pointer to `nogg dashboard pair`,
   and never the token or a link.

### Decision 6: The pairing code

- **Form.** `secrets.token_hex(16)`: 128 bits as 32 lowercase hex digits, with nothing that
  Markdown in a chat could turn into formatting. Guessing is not a realistic attack: a code
  lives at most five minutes, and the limiter allows ten failures a minute. The server builds
  the link with the existing `link()` helper, so the link-local zone form stays correct:
  `http://<bind host>:<port>/#pair=<code>`. `pair` prints it alone on its own line.
- **Held in memory only.** The server keeps `sha256(code)`, never the code. Each entry also
  holds its expiry, its state, `sha256(label ‖ secret)` from mint time, and after redemption
  the hash of the cookie it issued and the peer address. No code reaches a file or a log.
- **Five minutes, single use.** The first successful redemption marks the entry used,
  atomically under one lock. No second redemption, even a concurrent one, gets a cookie.
- **Bound to the running server and its secret.** The store dies with the process, so a
  restart ends every open link. A rotation changes the secret, so the hash no longer matches
  and every open link reads as expired. A cookie already issued from a link is an ordinary
  signed cookie: it survives a restart and ends with a rotation.
- **Bounded.** At most three links are open at once, and a fourth mint ends the oldest open
  link and says so. Used and expired entries stay as tombstones for one hour, at most 32, so
  a late tap is answered as *used* or *expired* rather than as a guess. A same-user process
  could end the Product Owner's open link by minting more. That shows in the audit trail.
- **Constants**, not configuration. The dashboard still needs no configuration key.

The store is a class in `dashboard_security.py`, next to `FailureLimit`, with an injected clock
and no I/O.

### Decision 7: Redemption on the wire

The client reads `#pair=<code>` the same way it reads `#token=`. It removes the fragment with
`history.replaceState` before anything else, then calls `GET /api/v1/auth` with
`Authorization: Pairing <code>`. The response policy does not change: same headers, content
security policy, Host, Origin and peer checks, GET and HEAD only.

`route_auth` on a token-requiring server reads the secret **once** per request and uses that
one value for the mint-hash comparison and for signing the cookie. A rotation between the two
steps therefore cannot turn an old link into a new cookie. For a `Pairing` credential:

| Case | Answer | Counts as a failure | Burns the code | Audit |
|---|---|---|---|---|
| Not GET (a HEAD) | 401 `unauthorized` | no | no | none |
| The server has no pairing store (a terminal run) | as a wrong token | yes | — | none |
| The secret is missing or refused | 401 `unauthorized` | no | no | none |
| Valid, open, same secret | 200 with `Set-Cookie`, the same cookie as the token gives | no | yes | `link_redeemed` with the peer address |
| Used, and the request carries the very cookie this redemption issued | 200, no new cookie | no | — | none |
| Used, any other valid cookie | 200, no new cookie, data `{"pairing": "used_elsewhere", "same_peer": …}` | no | — | `link_replayed`, once per code |
| Used, no valid cookie | 401 `pairing_used`, data `{"same_peer": …}` | no | — | `link_replayed`, once per code |
| Expired, or ended by rotation, restart or a newer mint | 401 `pairing_expired` | no | — | none |
| Unknown | 401 `unauthorized`, then 429 at the limit | yes | — | none |

`same_peer` says whether the replay comes from the peer address that redeemed the code.

- **HEAD never burns.** A prefetch cannot use up a link. A preview never sees the code anyway,
  because the code sits in the fragment and only the page's script sends it.
- **A correct open code is never limited**, like a correct token, so the limiter cannot lock
  the Product Owner out.
- **The same phone tapping twice is quiet,** but only with the exact cookie that link
  produced. A phone that was already signed in from before and finds its new link used gets
  the page *and* a warning. A lost race is never silent.
- **"Used" is loud, and honest about where.** With `same_peer` false the page says: *"This
  link was already used from another address. If that was not you, ask for the token to be
  rotated (`nogg dashboard --rotate-token`), which signs every browser out."* With
  `same_peer` true it says: *"This link was already used from this address, perhaps by
  another app on this device. Ask for a new link."* *Expired* says: *"This link has expired.
  Ask for a new one."* Every text is a text node.
- The reasons are fixed strings in `REASONS`, and the extra data are booleans. Nothing comes
  from the request.

A lost response after a successful redemption leaves the link used and the phone without a
cookie. The Product Owner asks again, and the audit trail shows a redemption with no session
after it. That trade-off is accepted, because a link redeemable twice would be worse.

### Decision 8: The control socket

The CLI must reach the running server without reading the secret, so the process that prints
a link never holds the long-lived credential.

- `service run` binds TCP first. Only after that succeeds does it open a Unix stream socket at
  `<state>/dashboard/control.sock`, inside the `0700` directory, with mode `0600`. A failed
  second instance therefore never touches the live socket.
- Before binding, it looks at the path. A non-socket there is a refusal and is never removed.
  A socket that accepts a connection belongs to a live server: refusal, and the socket is kept.
  Only a socket that refuses connections is stale and removed. On stop the server removes its
  own socket. The accept loop waits with a short timeout and checks the stop event, so SIGTERM
  always removes it.
- If the path is longer than the platform's limit (107 bytes on Linux), the service still
  serves, and `pair` reports why it cannot reach it. `service enable` warns up front.
- Each connection is checked with `SO_PEERCRED`, read in kernel order `(pid, uid, gid)`. A
  peer whose uid differs from the server's is closed without an answer. The order is spelled
  out on purpose: `session_backend_tmux.py` reads the same option with the fields swapped
  (discovery S1 on SPEC-iohv), and this code must not copy that bug.
- The protocol is one JSON line in and one JSON line out, then close. The server reads at most
  1 KiB within 2 seconds, one connection at a time:
  - `{"op": "pair", "caller": "<label>"}` returns `{"link", "expires_at", "ended": <n>}`.
  - `{"op": "status"}` returns bind, port, `started_at`, the number of open links and the
    earliest expiry. It never returns a code or a hash.
- The label is the CLI's claim about its caller. The server also records the peer pid from
  `SO_PEERCRED`, so a forged label still leaves a pid in the trail.

### Decision 9: Who may mint a link, and what the Orchestrator may do

`nogg dashboard pair` is allowed in two cases:

- from a proven supervised session with role `orchestrator`, labelled `orchestrator:<name>`;
- under `operator_terminal()`, labelled `operator`.

Every other caller is refused before it connects: Lead, planning, specialist and loop
sessions, a made-up session name, and every process that fails the operator-terminal test.
The link and its expiry go to stdout whether or not stdout is a terminal. That is the point:
the link may reach the chat, because a copy dies after use or after five minutes. When no
service runs, `pair` says so and names the terminal command. Like every rule here, a same-user
process could talk to the socket directly (Decision 2). The audit line with the peer pid stays
visible.

The Orchestrator's prompt gets a short section, and `/orchestrate` documents the same:

- Run `./scripts/nogg dashboard pair` only when the Product Owner asks in this conversation
  for the dashboard link. Send the link to them once, and to nobody else. Never put it into a
  Bead, a commit, a file or another session.
- Never read `<state>/dashboard/secret`, never build or send a `#token=` link, never run
  `service enable`, `service run` or `systemctl --user start|enable|restart` for the dashboard
  unit, never write its consent or unit, and never start a network bind. When `pair` says no
  service runs, give the Product Owner the one terminal command.
- Run `service disable` when the Product Owner asks for the dashboard to be switched off, and
  `--rotate-token` when they report a link that was already used from another address.

### Decision 10: Audit, status and doctor

- **Audit trail.** `<state>/dashboard/audit.jsonl` has mode `0600`. Each event is one
  `write()` of one line on a descriptor opened with `O_APPEND`. That is the only file a
  request may write, so the line from a redemption cannot interleave with another. Each line
  holds `{"at", "event", …}`:
  - `consent`: bind, port, tty.
  - `revoked`: caller.
  - `started`: mode `service` or `terminal`, bind, port, pid, and for a service the consent's
    `at` and `tty`.
  - `stopped`.
  - `link_minted`: caller, peer pid, expires_at, and `id`, the first 8 hex digits of the
    code's hash.
  - `link_redeemed` and `link_replayed`: id, peer address, and for a replay `same_peer`.
  - `rotated`.

  No code, token, cookie, or hash beyond those 8 digits is written.
- **The journal.** The service's stdout goes to the journal, and it prints every line it
  appends. The CLI sends its own events (`consent`, `revoked`, `rotated`, and a terminal
  run's `started` and `stopped`) through `systemd-cat -t nogg-dashboard` when `systemd-cat`
  exists. The operator's user can read the journal but not rewrite it. Whether the journal
  survives a reboot depends on the host's journald storage. `status` says whether the
  journal is persistent. The acceptance records it for the delivery host.
- **Failures.** If `link_minted` cannot be written, the mint fails and no link is returned.
  An event written while a request is served that cannot be written does not fail the
  request, and the line still goes to stdout. The file grows by a few lines per login and
  needs no rotation.
- **`nogg dashboard status`** works from anywhere and writes nothing. It prints:
  - the consent (address, port, since when, from which terminal), or "no exposure is
    consented";
  - the unit's enabled and active state;
  - what the running service reports over the socket;
  - whether the cgroup test applies on this host and whether the journal is persistent;
  - the last ten audit lines.
- **`doctor`** stays silent on a repository that never used the dashboard. Otherwise it adds:
  - a NOTE when the service is enabled with a matching consent, naming the address;
  - a WARN when the unit exists or is active without a valid consent, or when the consent's
    mode is wider than `0600`;
  - the existing secret warning.
- **`--rotate-token`** keeps working from anywhere, appends `rotated`, and names `nogg
  dashboard pair` as the next step when the service runs. Otherwise it names a terminal run.
  It can only reduce access.

### Decision 11: The attacks the brief names

- **Someone reads the log before the Product Owner opens the link.** The reader needs the link
  *and* a route to the private address within five minutes, before the Product Owner taps.
  - A same-user agent on the host already has the secret. The link gives it nothing new.
  - A reader of the Remote Control transcript elsewhere is not on the tailnet or the LAN.
  - A device on a shared LAN that also sees the chat could race the Product Owner. Then the
    Product Owner's tap shows "already used from another address", even on a phone that was
    signed in before (Decision 7). The audit trail shows both peer addresses, and
    `--rotate-token` ends the intruder's cookie.

  A device-code step, where the phone shows a code and the Product Owner types it into the
  chat, would stop this race. It was weighed and left out: the intruder must already sit on
  the private network and read the chat within the window. For that case the plain HTTP
  traffic is the larger exposure, and that is already a documented residual risk.
- **Replay.** A used code never yields a cookie, at any time and under concurrency. Its first
  replay is recorded once. After a restart the code is unknown and counts as a guess.
- **The rate limiter.** Unknown codes count toward the shared limit of ten failures a minute
  and get 429. Used and expired codes do not count, because they are a person coming back.
  A correct code passes even during 429, as a correct token does, so a flood of guesses
  cannot lock out the real link.
- **History and synced history.** A browser may keep `…#pair=<code>` in its global history.
  That code is dead.
- **Link previews and in-app browsers.** A preview that runs no script burns nothing. An
  in-app browser that runs the page does burn the code, and its cookie stays in that
  browser's own store. The guide tells the Product Owner to open the link in the browser they
  will use. If an app burned it first, the page says "from this address" and asks for a new
  link, instead of suggesting an intruder.
- **Plain HTTP on a LAN.** The code travels once in the clear, as the token and the cookie do
  today. Tailscale encrypts it, and the existing warning stays.
- **The address changes.** The service fails and retries. `status` and `doctor` show it, and
  only a new `enable` at a terminal binds another address.

### Decision 12: Tests and execution discipline

Every suite is offline: no systemd, no Dolt, no `bd`, no shared tmux server and no real
network. Tests use stubs and injected facts:

- stub `systemctl`, `loginctl` and `systemd-cat` on `PATH`;
- `pty.openpty()` for terminals;
- an injectable reader for the cgroup line and the session server pid;
- injected clocks and no sleeps;
- socket paths under 108 bytes.

The existing medium test that an open secret refuses a network start runs without a terminal.
It moves into a pseudo-terminal with an operator cgroup fact, and its assertion stays, so the
test stays as strict as before.

These tests prove that the old refusal still holds without consent or pairing:

- a proven Lead session asking for `--bind <private address>` with no consent: refused, old
  message;
- the same Lead with a valid consent on record: still refused;
- the same Lead while a pairing link is open on a running service: still refused;
- `service run` from inside a proven session: refused;
- with the session variable removed and stdin `/dev/null`: refused, no secret created;
- with a pseudo-terminal but an `app.slice` cgroup (the `systemd-run --pty` shape): refused,
  no token printed;
- with a pseudo-terminal under the shared session server's pid (the `tmux new-session -d`
  shape): refused, no token printed;
- `service run` with no consent, a `0644` consent, a consent for a public address, or outside
  the unit's cgroup: exit 78, no socket opened;
- `service enable` from a session, without a terminal, from a non-session cgroup, or with a
  mistyped confirmation: refused, nothing written, no `systemctl` call;
- `pair` from a Lead, a loop session, or any process failing the operator-terminal test:
  refused, no connection made.

The terminal rule ships first as its own `[security]` task, so that the plain bypass closes
before the new service path exists. `[security]` tasks get a `code-reviewer` pass before each
commit and a reviewed pull request. The live acceptance is a separate task, because it needs
the Product Owner at the terminal once and the phone.

## Risks / Trade-offs

- **The listener stays up while enabled.** This is accepted: no data without a credential, an
  idle refresher, and `disable` at any time.
- **Same-user agents remain all-powerful** (Decision 2). An agent can open a real login with
  `ssh -t localhost`, or read the secret. Visibility and the audit trail are the safeguard,
  as for the floor-lifted Orchestrator.
- **An operator command over SSH without `-t`** is now refused. The message and the guide say
  `ssh -t`.
- **A host without systemd or cgroups** gets the weaker test without condition 3 and no
  service. `status` and `doctor` say so.
- **A link copied wrongly in the chat** fails as unknown and counts as one failed attempt.
  The Product Owner asks again.
- **The in-app browser trap.** The cookie lands in the wrong browser. The guide covers it.
- **The archive order** (Decision 1). A wrong order breaks `openspec archive`, and the
  rehearsal catches it.

## Migration Plan

Nothing migrates. A repository without the service behaves as before, except that a network
bind outside an operator terminal is refused. The CHANGELOG states this as a behaviour change
and names `ssh -t`. A consumer who wants the service runs `service enable` once. The rollback
is `service disable`.

## Rehearsal

On 2026-11-02 the planner took a scratch copy of `openspec/` and archived `beads-dashboard`
and then `dashboard-phone-access`, both with `openspec archive -y`.

- The first archive created `specs/dashboard/spec.md` with 20 requirements.
- The second added 7 requirements to `dashboard` and replaced 6 in place, and it added 1
  requirement to `orchestration-agent`.
- The merged `dashboard` spec holds 26 requirements, and the unchanged scenario "A supervised
  session asks for a network bind" is still there.
- `openspec validate --all --strict` then passed 43 of 44 items. The one failure was the
  placeholder `## Purpose` ("TBD - created by archiving change beads-dashboard") that `openspec
  archive` writes for a new capability. The same failure appears when `beads-dashboard` is
  archived alone.

Whoever archives `beads-dashboard` replaces that placeholder in the main spec, as part of
`/plan`'s archive review. A delta cannot replace it, because a delta's `## Purpose` is read
only when the capability is created.

## Open Questions

- **Retire the token link of a terminal run?** If a terminal run printed a pairing link
  instead of `#token=`, no command would ever print the long-lived token. That would also
  cover a same-user process that opens a real login session. It changes a working flow and
  an open acceptance row of `beads-dashboard`, so it is left to the Product Owner as a
  follow-up.
- The acceptance records whether the Remote Control chat renders the link as tappable, which
  browser opens it, and whether the host's journal is persistent.
