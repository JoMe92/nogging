## 1. Close the plain bypass of the old refusal

- [ ] TASK-DPA-001 [complex] [security] [~220 loc: security fix shipped alone, so the bypass closes before the new service path exists] A network bind outside a supervised session needs an operator login terminal.
  Per design Decisions 2, 4 and 12 and the requirements on private binds and on the operator-terminal test. In scripts/nogg add `operator_terminal()` as Decision 4 defines it: no proven session and no unproven session name, stdin a terminal, no ancestor that is the shared Nogging session server (ask the tmux server of the configured socket for its pid with `-N`, ask herdr through its backend, and never start a server), and a logind `session-<id>.scope` cgroup where `/proc/self/cgroup` and systemd exist. Inject the cgroup reader, the server-pid lookup and the ancestry so that tests need no real host. Each failed condition gets its own message, and the terminal case suggests `ssh -t`. In `dashboard_command`, keep the supervised-session refusal and its message exactly as they are, then refuse a non-loopback `--bind` when `operator_terminal()` is false, before any socket and before a secret. Move the "open secret refuses a network start" check of scripts/dashboard-server.test.sh into a pseudo-terminal with an operator cgroup fact, and keep its assertion. Update docs/dashboard.md (Start and Access: the new rule, `ssh -t`), docs/security-model.md (the table of Decision 2 for the terminal rows) and CHANGELOG.md [Unreleased], where the behaviour change goes under Changed.
  Tests: small, one per condition of `operator_terminal()` with injected facts: "The operator in their own tmux", "A pane on the shared session server", a dropped session variable after a failed proof, an `app.slice` cgroup, a host without cgroups (condition skipped); medium (temporary repository, `pty.openpty()`): "A supervised session asks for a network bind" (unchanged message), "A network bind without a terminal" (stdin `/dev/null`, session variable removed, no secret created), "A pseudo-terminal outside a login session" (no token, no link printed), "A remote command without a terminal" (no tty, the message names `ssh -t`), "A terminal with piped output", the made-up session name still failing closed, and loopback inside a session still serving.
  Check: scripts/dashboard-server.test.sh, scripts/lib/dashboard_security_test.py. Branch fix/.

## 2. Exposure as the operator's recorded decision

- [ ] TASK-DPA-002 [complex] [security] [~560 loc] The operator enables the dashboard once as a user service, and every exposure is recorded.
  Per design Decisions 5 and 10 and the requirements on operator consent, the consented service, state, packaging and the audit trail. Add new scripts/lib/dashboard_service.py with the consent record (atomic `0600` write; owner, mode and schema checks; the bind policy again on read), the audit writer (`O_APPEND`, `0600`, one `write()` per line, mirrored to stdout by the service and sent through `systemd-cat -t nogg-dashboard` by the CLI when it exists), the unit text of Decision 5 (quoted canonical WORKDIR, `LimitCORE=0`, `RestartPreventExitStatus=78 203`), and `enable`, `disable`, `run` and `status`, with `systemctl`, `loginctl` and `systemd-cat` called through an injectable runner. Wire `nogg dashboard service {enable,disable,run}` and `nogg dashboard status` into the argument parser. `enable` uses `operator_terminal()` from TASK-DPA-001, needs stdout to be a terminal, reads the confirmation from `/dev/tty`, notes when lingering is off, warns when the socket path is too long and refuses without `systemctl`. `disable` is allowed under `operator_terminal()` and from the proven orchestrator only, and running it twice succeeds. `run` refuses in a session, outside its own unit's cgroup (exit 78) and on a missing or tampered consent (exit 78); it serves only the consent's values through `serve()`, prints no token and no link, and opens no control socket yet. A terminal network run appends `started` with mode `terminal`, and `stopped` when it ends. `--rotate-token` appends `rotated` and names the next step that fits. Extend `dashboard_secret_diagnostics` into the doctor lines of Decision 10, and keep doctor silent when the dashboard is unused. Add the module to bin/lib/manifest.js and the `remove` item for an enabled unit to bin/lib/nextsteps.js, and keep the unit out of `manifest.systemd`. Update docs/dashboard.md (a new Service section, Access), docs/commands.md, docs/security-model.md (the remaining rows of Decision 2, the journal note) and CHANGELOG.md.
  Tests: small consent round trip, a tampered consent (mode, schema, public and wildcard address), unit text without the secret and with the quoted canonical WORKDIR, the audit line fields and one write per line, a doctor line for each state; medium (stub `systemctl`, `loginctl` and `systemd-cat` on PATH, `pty.openpty()`, an injected cgroup fact, a temporary repository) "The operator enables the service", "A mistyped confirmation", "A session asks to enable", "No terminal", "A host without systemctl", "The secret stays out of the unit", "No consent", "A tampered consent", "A start beside the unit", "The service inside a session", "The orchestrator switches it off", "A Lead tries to switch it off", "Disabled twice", "A consent does not lift the session refusal", "The service prints no token", "A terminal run is recorded", "The token is rotated from the chat" (without the pair hint yet), "Doctor with a unit and no consent", "Doctor with a consented service", "Doctor on an unused install"; small in the installer suites "The installer writes no dashboard unit" and "Remove with the service enabled".
  Check: scripts/dashboard-server.test.sh, new scripts/lib/dashboard_service_test.py, scripts/package-manifest.test.sh, scripts/cli.test.sh. Branch feat/.

## 3. Pairing from the chat

- [ ] TASK-DPA-003 [complex] [security] [~620 loc] A one-time pairing link from `nogg dashboard pair` signs a phone in.
  Per design Decisions 6, 7, 8, 9, 10 and 11 and the requirements on pairing links, on who mints them, on the access token and on the audit trail. The store goes into scripts/lib/dashboard_security.py beside `FailureLimit`: `token_hex(16)` codes, only SHA-256 hashes in memory, five minutes, single use under one lock, bound to a hash of the secret current at mint time, at most three open with the oldest ended, the issued cookie's hash and the peer address kept with a used code, tombstones for one hour and at most 32, an injected clock and no I/O. In scripts/lib/dashboard_server.py, give `Request` the method and add the `Pairing` branch of `route_auth` exactly as Decision 7's table says: GET only, the secret read once, no burn without a secret, the same cookie, a quiet 200 only for the cookie this redemption issued, `used_elsewhere` and `same_peer`, the fixed reasons `pairing_used` and `pairing_expired`, unknown codes through `refuse_attempt`, and audit events through the dashboard_service writer. Add the control socket that `service run` opens after its TCP bind: `0600` in the `0700` directory; a stale socket removed only when it refuses connections, while a non-socket or a live socket is kept; `SO_PEERCRED` read as `(pid, uid, gid)`; one request of at most 1 KiB in 2 s (`pair`, `status`); an accept loop that checks the stop event so SIGTERM removes the socket; and the path-length check. Add `nogg dashboard pair` with the caller rule of Decision 9, printing the link on its own line through the existing `link()` helper, and let `status` and `--rotate-token` read the running service through the socket. In scripts/dashboard/auth.js, accept `#pair=`, remove the fragment first, and show the used (two texts by `same_peer`), used-elsewhere and expired messages as text nodes; update the panel text in scripts/dashboard/index.html. Update docs/dashboard.md (Access: pairing, the in-app browser note, what to do after "already used"), docs/security-model.md (a link in a chat, the LAN race of Decision 11) and CHANGELOG.md.
  Tests: small store: mint, redeem once, "Two redemptions race" with threads, expiry with an injected clock, a rotation ends open links, "A fourth link", tombstone answers; small route: every row of Decision 7 through `route_auth`, including "The same phone taps the link again", "A lost race on a phone that was already signed in", "A rotation during a redemption", "A HEAD request or a preview", "Guessing under the limiter", "A terminal run has no pairing"; medium (a real server with the harness's network-rules bind `Bind("127.0.0.1", None, False)`, temporary state, short socket path) "The Product Owner opens a pairing link" (cookie set, then `/api/v1/summary` answers), "The link is opened twice from different browsers" (one `link_replayed`), "The server restarts", "Another user connects" (SO_PEERCRED stubbed at the socket boundary), "The socket path is taken", "A slow control client", SIGTERM removes the socket, "The Orchestration Agent mints a link", "The operator mints a link on a terminal", "A Lead asks for a link", "An unproven process without a terminal", "No service runs", "A full login is traceable", "Status from anywhere", "The audit trail cannot be written", "The token is rotated from the chat" with the pair hint; the client source scan of dashboard_client_test.py keeps passing for auth.js.
  Check: scripts/lib/dashboard_security_test.py, scripts/lib/dashboard_server_test.py, scripts/lib/dashboard_service_test.py, scripts/lib/dashboard_client_test.py, scripts/dashboard-server.test.sh. Branch refactor/.

## 4. The Orchestrator's part

- [ ] TASK-DPA-004 [standard] [~100 loc: below the 400-line range; prompt and guidance wording only, and the text is the contract] The Orchestration Agent hands over a dashboard link only when the Product Owner asks.
  Per design Decision 9 and the orchestration-agent requirement on dashboard links. Add the section of Decision 9 to .nogging/launch-prompts/orchestrator.md and the matching paragraph to .claude/commands/orchestrate.md, and add one sentence on phone access to the Orchestration section of docs/operating-model.md. The prompt names the exact commands: `./scripts/nogg dashboard pair`, `service disable`, `--rotate-token`, and the terminal command it hands to the Product Owner. It also names every prohibition: the secret file, a `#token=` link, `service enable` and `service run`, `systemctl` on the unit, the consent and unit files, and a network bind. Restarting the live orchestrator so that it reads the new prompt stays with the operator, and the Lead does not do it.
  Tests: small wording checks in scripts/commands.test.sh: the prompt says "only when the Product Owner asks", forbids reading the secret, a `#token=` link, `service enable`, `systemctl` on the unit and a network bind, and names the terminal command. The prompt is the contract, so the source-text exception of the test policy applies.
  Check: scripts/commands.test.sh, scripts/runtime-guidance-docs.test.sh, scripts/docs-site.test.sh. Branch docs/.

## 5. Live acceptance on the delivery host

- [ ] TASK-DPA-005 [complex] [~120 loc: live acceptance report, deliberately small] The Product Owner gets the dashboard onto the phone from a chat, after one terminal step.
  Per design Decisions 3, 11 and 12. After 001 to 004 are integrated into develop and the operator has restarted the orchestrator, write docs/acceptance/<date>-dashboard-phone-access.md, unsigned with an empty Signed-off-by line, from a real run on the delivery host. The Product Owner runs `nogg dashboard service enable --bind <tailscale address>` on a login terminal, once. Then, by chat only: ask the Orchestrator for the link, open it on the phone over Tailscale in the browser they use, and come back later still signed in. Tap the used link again from a second browser and see "already used from another address" with exactly one `link_replayed`, then rotate the token through the chat and confirm that the second browser is signed out. Let one link expire. Switch the dashboard off through the chat and confirm that `status` shows it off. Record whether the Remote Control chat renders the link as tappable, which browser opened it, and whether the host's journal is persistent and holds the events. Add `status` and `doctor` output with addresses reduced to the Tailscale one, plus the refusals that a Lead session gets for `--bind`, `service enable` and `pair` and those that a `systemd-run --user --pty` start and a pane opened on the shared server get for `--bind`. Never stop Dolt, the shared tmux server or the orchestrator for this. The open rows 9 to 17 of the beads-dashboard report are not part of this report.
  Tests: large the whole chat-to-phone flow on the real host, as manual rows of the report; the automated scenarios are in 001 to 003.
  Check: report committed, scripts/docs-site.test.sh. Branch test/.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A depends on B):
002<-001; 003<-002; 004<-003; 005<-004.

- 002 uses `operator_terminal()` from 001.
- 003 binds pairing to the service, consent and audit writer of 002.
- 004 documents the `pair` command of 003.
- 005 needs all four on the host.

Branches are `<type>/dashboard-phone-access`, one prefix per task: fix/ 001, feat/ 002, refactor/
003, docs/ 004, test/ 005. Before allocating a dependent worktree, verify that every prerequisite
execution commit is integrated into develop. A closed Bead alone is not enough.

Archive order: `beads-dashboard` is archived before this change (design Decision 1). No execution
task archives either change.

## Execution contract

**Scope.** A task's first line is its Bead title. Its full slice is that line plus the indented
paragraph under it, the design Decisions it names, design Decision 12, and the matching requirements
in specs/.

**Work.** The Main Worker claims each task and implements it only in its own allocated worktree, in
several commits within the configured commit range. Write the tier classification to the Bead note
on every launch.

**Security review.** Tasks marked [security] change authority, approval or secret handling. They get
a code-reviewer pass before each commit and a reviewed pull request. On a Codex or Pi Lead, the
Orchestration Agent's PR review is that review.

**Testing.** Every suite is offline, with no systemd, Dolt, bd, shared tmux or herdr server, and no
network:
- stub `systemctl`, `loginctl` and `systemd-cat`;
- pseudo-terminals;
- injected cgroup and server-pid facts;
- private sockets under 108 bytes;
- injected clocks, with no real sleeps.

Test in stages: the tests of the changed files while working, those tests plus lint before each
commit, and the suites the task names once per Bead. The full `scripts/test` is CI's job. Run a long
command as one blocking call (`./scripts/nogg run-quiet -- <command>`), and never poll it.

**Closing.** Push the branch and open the pull request against develop. Only then run bd close and
`scripts/nogg task-done`, and append every SHA and the evidence to the Bead. A Codex Lead needs
--full-access or --profile trusted to reach the shared Dolt server.

**Limits.**
- Agents never hand-edit OpenSpec.
- Discoveries carry the discovery label and prose.
- Prompts, fixtures and docs contain no email address and no real token, and no fixture holds a real
  code or secret.
- No Lead enables a dashboard unit, writes a consent, or starts a network bind on the host. Enabling
  stays with the operator.
- Nobody signs human acceptance.
