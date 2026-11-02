# Dashboard phone access — delivery host acceptance — 2026-11-02

Unsigned execution evidence for TASK-DPA-005 (`SPEC-gh7v`), change `dashboard-phone-access`.

**Overall: partial, not accepted as it stands.** This run did only what a supervised Lead may
do without the Product Owner: it read the state, asked for a network bind and a pairing link
and recorded the refusals. No consent exists on this host, so no service runs and no link
exists. The Lead never started a network bind, never read the dashboard secret and never ran
`service enable`. It ran `pair` once, and only to record the refusal. Every row that needs the
Product Owner at a login terminal or on the phone is **open** below. No result is claimed for
an open row, and automated tests are not counted as live results. This report does not
establish Product Owner acceptance.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-11-02, about 12:20Z to 12:40Z |
| Host | `raspberrypi`, Raspberry Pi 5, Linux aarch64; Tailscale address `100.86.79.27` on `tailscale0` |
| Operator | Nogging-supervised Claude Lead `sf-lead-spec-gh7v-20261102t121851-c5e2` |
| Toolkit version | 3.6.0 (`package.json`) |
| Git commit | `22f2e0d` on `develop`, which holds TASK-DPA-001 to 004 |
| Runbook | TASK-DPA-005 with the Product Owner's scope for this session; not `docs/acceptance.md` |
| Backend | Real `bd` 1.2.2, the host's user journal and systemd; no network bind |
| Python | 3.13.5 |

## Results

Result is `pass`, `partial`, `fail` or `open`. `open` means nobody has done the check yet.

### Done on the host by the Lead

Each command ran from the main checkout with stdin closed (`</dev/null`) and a timeout, and its
output went to a scratch file first, which was checked for `token=`, `#pair=` and `http://`
before it was read. None of them was there.

| # | Check | Result | Evidence |
| --- | --- | --- | --- |
| 1 | `status` shows no consent | pass | `consent: no exposure is consented`; `unit: nogg-dashboard-nogging.service absent`; `service: not reachable: no dashboard service answers on …/.nogging/state/dashboard/control.sock`; `last events: none recorded`; exit 0 |
| 2 | `status` reports the host facts | pass | `cgroup test: applies; journal: persistent` |
| 3 | No dashboard state exists, before and after every step | pass | `.nogging/state/dashboard` is absent: no secret, no consent, no audit trail, no control socket. `~/.config/systemd/user/` holds no dashboard unit |
| 4 | A Lead asks for `--bind 100.86.79.27`: refused, no socket, no secret | pass | Exit 1: `nogg: session sf-lead-spec-gh7v-… is not running this process; cannot prove its authority, refusing a network dashboard bind`. No state created. See finding 2 for which refusal path answered |
| 5 | A Lead asks for `pair`: refused before it connects | pass | Exit 1: `nogg: refusing \`nogg dashboard pair\`: session sf-lead-spec-gh7v-… is not running this process; cannot prove its authority, refusing a dashboard pairing link`. No link printed |
| 6 | `doctor` stays silent about an unused dashboard | pass | Exit 0. Its one dashboard mention is `NOTE change ready to archive: beads-dashboard`, which concerns the old change, not the service |
| 7 | `--list-binds` names the Tailscale address | pass | `100.86.79.27`, with no carrier-NAT warning, because it sits on `tailscale0`. LAN, Docker and link-local addresses left out here |
| 8 | The operator-terminal test on this host's real facts | pass | Evaluated in-process, with no bind: the session variables removed, `operator_terminal_refusal([], …)`. With stdin forced to a terminal it refuses because the shared server cannot be identified from here; with the server list empty it refuses on the cgroup `…/app.slice/tmux-spawn-….scope`, which is not a logind session scope; with stdin not a terminal it refuses on stdin |
| 9 | Unit state through `systemctl --user` | partial | `enabled=unknown, active=unknown`: the Lead's tool shell cannot reach the user bus (`Failed to connect to user scope bus via local transport`). The unit file is absent, which row 3 shows directly. See finding 3 |

### Not run by the Lead, on the Product Owner's instruction

| # | Check | Result | Evidence |
| --- | --- | --- | --- |
| 10 | A Lead asks for `service enable --bind …`: refused, nothing written | open | Not run: this session was told never to run `service enable`. Automated: `dashboard_service_test.py` `test_a_lead_or_an_unproven_caller_is_refused`, `test_refusals_write_nothing_and_call_no_systemctl` |
| 11 | `systemd-run --user --pty ./scripts/nogg dashboard --bind 100.86.79.27`: refused | open | Not run: it is a network-bind attempt outside the supervised session, and this tool shell has no user bus. Automated: `scripts/dashboard-server.test.sh` "outside a login session scope" |
| 12 | `--bind` from a pane opened on the shared session server: refused | open | Not run, for the same reason. Automated: `scripts/dashboard-server.test.sh` "a pane on the shared session server is refused" |

### Open, for the Product Owner

**Before you start:** the Orchestrator has run since 2026-11-01 21:04Z, and TASK-DPA-004 (its
prompt section) reached `develop` on 2026-11-02 at 12:17Z. Restart it first with
`./scripts/nogg orchestrator restart`. Run row 13 from the login shell itself, not from a tmux
pane: this host's tmux moves each pane into its own `tmux-spawn-*.scope`, and the
operator-terminal test refuses that (row 8, `docs/dashboard.md`).

| # | Check | Spec scenario | Result | Evidence |
| --- | --- | --- | --- | --- |
| 13 | `./scripts/nogg dashboard service enable --bind 100.86.79.27` on a login terminal, typing the address to confirm | The operator enables the service | open | |
| 14 | `status` and `doctor` afterwards: consent, unit enabled and active, the `consent` and `started` events, a doctor NOTE naming the address | Status from anywhere; Doctor with a consented service | open | |
| 15 | Ask the Orchestrator for the link in the chat; it runs `pair` once and sends the link only to you | The Product Owner asks for the dashboard; The Orchestration Agent mints a link | open | |
| 16 | Does the Remote Control chat render the link as tappable? Which browser opened it? | TASK-DPA-005 | open | |
| 17 | Open the link on the phone over Tailscale: signed in, `#pair=` gone from the address bar, `link_redeemed` | The Product Owner opens a pairing link | open | |
| 18 | Come back later and still be signed in | The phone comes back | open | |
| 19 | Tap the used link from a second browser: "already used from another address", exactly one `link_replayed` | The link is opened twice from different browsers | open | |
| 20 | Ask the Orchestrator to rotate the token: `rotated`, and the second browser is signed out | The token is rotated from the chat | open | |
| 21 | Let one link expire (more than five minutes): "This link has expired" | The link has expired | open | |
| 22 | Ask the Orchestrator to switch the dashboard off: `service disable`, then `status` shows no consent and no unit, and `revoked` | The orchestrator switches it off | open | |
| 23 | The journal is persistent and holds the real events of rows 13 to 22 (`journalctl --user -t nogg-dashboard`) | A full login is traceable | open | Today's journal holds only test output; see finding 1 |

The open rows 9 to 17 of the beads-dashboard report are not part of this report.

## Findings

Recorded on `SPEC-gh7v` with the `discovery` label. Nothing here was fixed; these wait for a
planning session or a follow-up Bead. No design decision changed.

1. **The medium test writes `rotated` into the host's real journal (verified).** The user journal
   held 64 lines tagged `nogg-dashboard` on 2026-11-02, all `{"event":"rotated"}`, in bursts of
   three to four between 08:45Z and 12:18Z, while this host had no dashboard state at all.
   `scripts/dashboard-server.test.sh` runs `dashboard --rotate-token` at lines 319 to 407 before
   its `systemd-cat` stub exists (line 429), so the real `systemd-cat` receives them. Design
   Decision 12 requires every suite to stub `systemd-cat`. The effect: the journal, which row 23
   and Decision 10 use as the record nobody can rewrite, holds false `rotated` events. Read the
   events of rows 13 to 22 by timestamp, and do not run the dashboard tests while those rows run.
2. **The Lead's refusal came from the unproven-name path (verified effect, cause not analysed).**
   `calling_session_record` did not prove the Lead's tool process to be its session ("is not
   running this process"), so `--bind` and `pair` were refused as for a made-up session name,
   not with the old "inside a supervised session" message. Both paths refuse before any socket
   opens. The proven-Lead message is covered only by the automated tests.
3. **No user bus in the Lead's tool shell (verified).** `systemctl --user` fails here, so
   `status` shows `enabled=unknown, active=unknown`. If the Orchestrator's shell is sandboxed the
   same way, its `service disable` in row 22 would fail at `systemctl`. This was not checked,
   because the Lead must not touch the Orchestrator. Row 22 will show it.
4. **The herdr server receipt is from before the reboot (observed).** It is dated 2026-10-27 and
   names a PID namespace other than this sandbox's. From here the operator-terminal test
   therefore fails closed ("cannot tell whether it runs under the shared Nogging session
   server"). A login shell in the host namespace should not hit this, but if row 13 refuses with
   that reason, record it here.
5. **"The operator in their own tmux" does not hold on this host (documented, not tried
   live).** The spec scenario says the test holds in a tmux the operator started from an SSH
   login. `docs/dashboard.md` already says that a tmux built with systemd support, as on
   Raspberry Pi OS, moves each pane into its own `tmux-spawn-*.scope`, which the cgroup
   condition refuses. Row 8 shows such a scope refused. The spec and the shipped behaviour
   therefore disagree on this host, and row 13 has to run outside tmux.

## Deviations

- No consent, service, pairing link, phone or browser: rows 13 to 23 are open, by the Product
  Owner's instruction for this session.
- Rows 10 to 12 were not run by the Lead, by the same instruction. Row 8 evaluates the same
  predicate in-process instead, without a bind.
- `nogg test full` was not run, as the test policy says.

## Sign-off

Signed-off-by:
