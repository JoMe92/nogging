## Why

The Product Owner is often on the phone, reaches the Orchestration Agent through Remote
Control and has no terminal at hand. On 2026-11-02 they asked the Orchestrator to start the
dashboard and hand over the link. `nogg dashboard --bind 100.86.79.27` refused:

    refusing --bind 100.86.79.27 inside a supervised session: the token would reach the
    session log, and network exposure stays an operator act

That refusal is the specified behaviour of `beads-dashboard`. The Product Owner's answer was
"Fixe das". So the flow changes on purpose, and this change alters a security requirement:
today a network bind needs a person at a terminal every time. After this change it needs a
person at a terminal **once**.

While reading the code for this change, a second problem showed up. The refusal
recognises a supervised session only when process ancestry proves one. A start that breaks
ancestry, such as `systemd-run`, `setsid`, or a new window on the shared tmux server, looks
like the operator. With `systemd-run --pty` it even prints the token link into the agent's
own output. So today an agent can expose the dashboard with one command, and nothing
records it. The SPEC-0adz discovery reports the same gap for loop management. This change
closes the plain paths for the dashboard, and it ships that fix first.

## What Changes

- **A user service, enabled once by the operator.** `nogg dashboard service enable --bind
  <address>` runs only at an operator login terminal. It asks the operator to type the address again,
  records that consent, writes one systemd user unit and starts it. From then on the
  dashboard runs on that address, survives reboots and is restarted on failure. `nogg
  dashboard service disable` ends it and removes the consent. The installer never writes
  this unit.
- **A one-time pairing link for the phone.** `nogg dashboard pair` asks the running service
  for a link that works once, for five minutes, and only on that server process. Opening it
  sets the same signed cookie the access link sets. The long-lived token never leaves the
  host. A copy of the pairing link in a session log, transcript or chat is dead after use
  or after five minutes. The Orchestration Agent may run `pair` when the Product Owner asks
  for the link, and only then. Its prompt forbids it to read the secret, build a token link,
  or start or enable the service.
- **The old refusal stays, and the gap closes.** A network bind inside a supervised session
  is refused as before, with or without consent, and a pairing link does not change that.
  Any other network bind except the consented service now needs an *operator terminal*: a
  terminal on stdin, inside a login session's cgroup, and not running under the shared
  Nogging session server. That refuses an agent's `systemd-run` (also with `--pty`),
  `nohup`, `setsid` or `tmux new-session -d`. A loopback run is unchanged. A network run at
  a login terminal still prints its access link, and is now recorded.
- **Recorded and auditable.** The consent is a file the service reads before it binds.
  Every consent, revocation, network start (service or terminal), minted link, redemption,
  replay and rotation goes to an append-only audit file, and to the journal where the host
  keeps one. No line holds a code or a token.
  `nogg dashboard status` and `doctor` show the current exposure.

**Is a terminal still needed?** Yes, once: the Product Owner runs `nogg dashboard service
enable --bind <address>` on the host, at the keyboard or over `ssh -t`, and types the address
again to confirm. After that, getting the dashboard onto a phone takes only a chat with the
Orchestrator. A terminal is needed again only when the consented address changes or after
the service has been disabled. This step cannot be moved into the chat. The host cannot
tell a real chat instruction from an agent that claims one, so a consent written by an agent
would prove nothing.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `dashboard`: network exposure through a consented user service, the terminal rule for
  every other network bind, one-time pairing links, the audit trail and the status view.
  This modifies requirements that `beads-dashboard` adds, so `beads-dashboard` must be
  archived first (design Decision 1).
- `orchestration-agent`: the Orchestrator hands over a pairing link only when the Product
  Owner asks for it, and never enables, starts or consents to an exposure.

## Impact

- **New file:** `scripts/lib/dashboard_service.py` (consent, audit, unit text, the control
  client and `status`), with its tests.
- **Changed files:** `scripts/nogg` (the `dashboard` subcommands and the terminal rule, the
  `doctor` lines), `scripts/lib/dashboard_security.py` (the pairing store),
  `scripts/lib/dashboard_server.py` (redeeming a pairing, the control socket),
  `scripts/dashboard/auth.js` and `index.html` (a `#pair=` link and its messages),
  `bin/lib/manifest.js` (ships the new module), `bin/lib/nextsteps.js` (a `remove` hint
  for an enabled service), `.nogging/launch-prompts/orchestrator.md`,
  `.claude/commands/orchestrate.md`, `docs/dashboard.md`, `docs/security-model.md`,
  `docs/commands.md`, `CHANGELOG.md`.
- **Unchanged:** the private bind allow-list, the HTTP response policy (headers, content
  security policy, GET and HEAD only, Host and Origin checks, the peer check), the 30-day
  cookie and its signature, the failure limiter, the loopback run, and the access link of
  a terminal run.
- **Security surface.** A listener that stays up while the service is enabled, on an
  address the operator chose. A second, local-only Unix socket that only the operator's
  user can open. A short-lived login credential that may appear in a chat. The design walks
  through each attack the brief names. It says plainly what a process that runs as the
  operator's own user can still do: read the secret, or open a real login with `ssh -t
  localhost`. Nogging cannot prevent that. It records it.
- **Behaviour change.** A network bind without an operator terminal (no stdin terminal, a
  `systemd-run` scope, a pane on the shared session server, `ssh` without `-t`) is now
  refused.
- **Out of scope:** the open acceptance rows 9 to 17 of `beads-dashboard` (this change
  makes them doable from a phone, but does not run them), archiving `beads-dashboard`,
  TLS, internet exposure, and the acceptance findings of `beads-dashboard` (no Pi data,
  787 spool batches).
