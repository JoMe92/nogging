## Context

The baseline is `origin/develop` at a6ff0db (v2.2.0, 2026-10-15). The Product
Owner's decision (2026-10-15) is final: add herdr as a second, switchable
session backend, keep tmux as the default and the permanent fallback, and leave
the default unchanged in this change.

The tmux coupling as it stands (line numbers at a6ff0db):

- One wrapper in `scripts/nogg:2131-2140` (`tmux_bin`, `tmux_socket`,
  `tmux()`, `tmux_has_session`, `tmux_sessions`) with about 40 call sites:
  - launch: `new-session` with `-e` env, `pipe-pane`, `display-message
    #{pane_pid}`;
  - list/reconcile, reap, cleanup (`kill-session`, `kill-server`);
  - stop (`C-c` then `kill-session`), attach (`execvp tmux attach [-r]`);
  - send (`-l`, Enter, plus a second Enter for Claude), nudge (`C-u`, `-l`);
  - `resume-when-ready` (`Escape`), watch/classify/sweep (`capture-pane -p
    [-e]`), doctor and recover;
  - the orchestrator (`run` blocks on `tmux_has_session`).
- `scripts/nogg_usage.py:907,1017` stores `tmux`/`socket` in a usage
  reservation and probes `has-session` directly.
- `scripts/lib/token_usage_collect.py` receives liveness as a boolean from
  `scripts/nogg`. It is backend-neutral except for one docstring.
- `scripts/session-launch` is tmux-neutral: it is the process *inside* the
  session.
- `.nogging/launch-prompts/{autonomous,no-autonomous-claim,orchestrator}.md`
  say "tmux session" literally.
- About 10 test scripts stub tmux on `PATH` (`scripts/session.test.sh`,
  `orchestrator.test.sh`, `session-nudge-placeholder.test.sh`, …).

Discoveries that bear on this change (closed, already reviewed in this planning
session):

- SPEC-7qzj: `pane_input()` tells actual input from a dim placeholder only from
  `capture-pane -e` SGR attributes. An unidentifiable pane is an *unverified
  failure*, never a resend.
- SPEC-5ktw: the startup stderr sink attaches inside `session-launch` before
  the log pipe can exist.
- SPEC-43k1: the Antigravity pane adapter cannot see a running-tool marker.

## Goals / Non-Goals

**Goals:**

- A primitive-only seam with tmux behind it and no tmux behaviour change.
- A herdr backend that keeps every supervision guarantee: a durable record
  before exec, an append-only bounded log, least authority through the
  unchanged launch wrapper, deliberate lifecycle, no credential leakage.
  Where a guarantee cannot hold, the herdr backend refuses or documents a
  tested replacement.
- Mixed backends run at the same time.
- Live `agent_status` in `session list`.
- Execution can be split across parallel Lead sessions with minimal file
  overlap.

**Non-Goals:** see `proposal.md`. In short: no orchestrator move, no default
switch, no tmux removal, no plugins or web, no new network listener, no
automatic installation of herdr or its agent integrations, and no replacement
of the `session watch` adapters.

## Decisions

### 1. Gate spike before any implementation (TASK-HDR-001)

All other tasks depend on the spike. It installs herdr v0.9.x at user level:

- the binary goes in `~/.local/bin`, with no sudo;
- the release asset is fetched without `curl`/`wget` (the command floor
  forbids them), for example with `gh release download`;
- the published SHA-256 is checked with `sha256sum -c` before first run.

The spike then tests on the delivery Pi, inside the real Nogging wrapping
(`scripts/session-launch` + a prototype PTY recorder + `HERDR_AGENT=<agent>`).
For each gate item it records PASS or FAIL with evidence:

| Item | PASS criterion | Fallback when it alone fails |
| --- | --- | --- |
| (a) status | herdr reports idle and working (and blocked where reproducible) for Claude, Codex and Antigravity under the wrapper. | That agent's `agent_status` is `unknown`. Decision 9. |
| (b) ANSI in `pane.read` | Some `pane.read` source returns the SGR attributes needed to tell a dim placeholder from input. | Nudge/send deviation with a replacement check. Decision 8. |
| (c) pane-ID stability | A pane's ID, or its label lookup, resolves the same pane across a server restart. | Resolve by label; liveness is process-bound anyway. Decision 6. |
| (d) native resume | Native resume restores the conversation per agent after a server restart, **and** auto-restore can be disabled for Nogging panes so that no agent starts outside the launch wrapper. | herdr restore stays disabled for Nogging panes; resume uses Nogging's exact resume. Decision 7. |
| (e) PTY recorder log | The recorder captures a complete append-only log while the Codex and Antigravity TUIs render, resize and accept input correctly. | The herdr backend refuses that agent before any side effect, and the operator uses tmux for it. Decision 5. |

**Gate rule (Product Owner):** if two or more of (a)–(e) fail, the spike
records a discovery with `--status blocked` and the change goes back to
planning; no dependent task proceeds. If exactly one fails, the spike records a
non-blocking discovery naming the fallback above, and dependent tasks implement
that fallback.

The spike also records the implementation facts that the later tasks code
against, so that no task builds on an assumption:

- the exact CLI form and JSON output of every primitive used;
- how a dedicated named herdr session is addressed and isolated;
- how the server starts headless on demand;
- whether `pane.close` terminates the process tree;
- what happens to a pane when its process exits;
- `send_text`/`send_keys` semantics, including Claude's double Enter;
- whether read-only attach exists;
- herdr's auto-update behaviour;
- whether pane screen history is off by default;
- what each herdr agent integration would modify in global agent
  configuration.

Sanitized fixtures — CLI help, JSON outputs and `pane.read` captures with and
without escapes, with no secrets and no conversation content — are committed
under `scripts/fixtures/herdr/spike/` for the fake-CLI stub. A spike that needs
the operator to fetch the asset records a `progress:` note and asks; it never
bypasses the floor.

### 2. A primitive-only seam

`scripts/lib/session_backend.py` defines the interface, a registry
(`tmux`, `herdr`) and the resolvers. A backend implements **only** these
primitives:

| Primitive | Contract | tmux | herdr |
| --- | --- | --- | --- |
| `start(name, cwd, env, argv, log)` → `ref` | Create the session that runs `argv` in `cwd` with `env`, wiring log capture. Returns the backend reference persisted in the record. | `new-session -d -s -c -e … --`, then `pipe-pane -o` | Labelled pane created with the recorder-wrapped `argv` (Decision 5). |
| `pid(ref)` | Root process ID of the session, or None. | `display-message #{pane_pid}` | `pane.process_info` |
| `send_text(ref, text)` | Literal text, no submit. | `send-keys -l` | `pane.send_text` |
| `send_keys(ref, key)` | One normalized key: `enter`, `escape`, `ctrl+c` or `ctrl+u`. | `Enter`, `Escape`, `C-c`, `C-u` | `pane.send_keys enter`, `esc`, `ctrl+c`, `ctrl+u` |
| `capture(ref, attributes)` | Visible screen with no scrollback. With `attributes`, SGR escapes are kept where the backend can. | `capture-pane -p [-e]` | `pane.read --source visible` |
| `capabilities` | Static flags: `capture_attributes`, `read_only_attach`, `agent_status`. | all except `agent_status` | per spike |
| `live(records)` → `(alive, unknown)` | Names of this backend's records whose session is alive, plus names whose liveness could not be determined. | `list-sessions` names; `unknown` is always empty (today's behaviour) | Decision 6 |
| `kill(ref)` | Terminate the session hard. | `kill-session` | `pane.close` + process termination fallback (Decision 6) |
| `attach_argv(ref, read_only)` | The argv the CLI `execvp`s. | `tmux -L <sock> attach -t <name> [-r]` | Decision 10 |
| `agent_status(ref)` (optional) | `idle`, `working`, `blocked`, `done`, `unknown`, or None when unsupported. | None | Decision 9 |
| `idle_shutdown()` | Called by cleanup when no non-retired record remains. | `kill-server` (today) | no-op: Nogging never stops the herdr server |

Everything else stays in `scripts/nogg` above the seam and backend-neutral:

- records, transitions and the lifecycle lock;
- name generation and collision checks (records, logs, every available
  backend);
- the planning and orchestrator locks, Bead binding, reap/cleanup policy;
- the stop grace sequence: `send_keys ctrl+c`, wait for the stop grace period,
  then `kill`;
- kickoff composition, nudge/send policy, the `_submit_pane_input` double
  Enter, pane classification, the usage gate and collection, doctor and
  recover.

The rule is that a backend never decides lifecycle state; it only reports
facts.

### 3. Module layout and file ownership

- `scripts/lib/session_backend.py`: interface, registry, resolution and the
  normalized key names. It is loaded the same way as `token_usage_collect`
  (`scripts/lib` on `sys.path`, no bytecode).
- `scripts/lib/session_backend_tmux.py`: the moved tmux primitives. Its config
  keys are unchanged (`session_tmux_command`, `session_tmux_socket`).
- `scripts/lib/session_backend_herdr.py`: the herdr primitives over the CLI.
  New keys: `session_herdr_command` (default `herdr`) and
  `session_herdr_session` (default `nogging`), the latter being the dedicated
  namespace analogous to `tmux -L nogging`.
- `scripts/session-pty-recorder`: a new executable helper (Decision 5).
- `scripts/fixtures/herdr/`: spike fixtures, plus a stateful fake `herdr` CLI
  (`scripts/fixtures/herdr/bin/herdr`) driven by `$HERDR_STUB_DIR`, the same
  technique as the tmux stub.

After TASK-HDR-002, `scripts/nogg` contains no direct `tmux` invocation, and a
test greps for that. Each task that adds a shipped file adds its own entries to
`package.json` `files` and the matching `bin/lib/manifest.js` lists
(`verbatim`/`executable`/`docs`) next to entries of the same kind:

- HDR-002 ships the two seam/tmux modules;
- HDR-006 ships the herdr module and the recorder;
- HDR-010 ships the guide.

Script entries and doc entries sit in separate regions of each file, so
parallel tasks do not produce adjacent-line conflicts.

### 4. Selection, records and mixed backends

- `session_backend` (`.nogging/config.json`) is `tmux` or `herdr`. Absent
  means `tmux`. `templates/nogging-config.json` documents it with `tmux`.
- `session launch --backend {tmux,herdr}` overrides the config. Precedence is
  `--backend`, then config, then `tmux`. An invalid value, or `herdr` when the
  herdr module or binary is unavailable, is refused **before** any worktree,
  trust, reservation, record or backend side effect, with the same ordering
  discipline as the existing preflight.
- Every new record carries `backend` and the backend's `backend_ref`. For
  tmux that is `{socket}`. For herdr it is `{herdr_session, workspace,
  pane_id, label}`. A record without `backend` is tmux.
- Lifecycle operations resolve the backend **from the record**, never from the
  current config, so changing `session_backend` never strands a running
  session. `session list` builds liveness per backend over its own records and
  shows a `BACKEND` column.
- If a backend's tool is unavailable or fails unexpectedly, its records are
  reported with liveness `unknown`: `list` shows the stored state with an
  `(unknown)` marker. `reap` and `cleanup` leave those records untouched and
  print a NOTE. A tool failure is never proof that a session is dead, which
  mirrors the existing reservation rule. tmux keeps today's semantics:
  `list-sessions` failing means no live sessions.
- The Orchestration Agent stays on tmux. `orchestrator run` always launches
  and adopts on tmux whatever `session_backend` says, and `session launch
  --role orchestrator --backend herdr` is refused.

### 5. Append-only log through a PTY recorder

herdr has no `pipe-pane` equivalent, and `events.subscribe` is not durable. So
the herdr backend starts
`scripts/session-pty-recorder <log> <max-bytes> <depth> -- <session-launch
argv…>` as the pane command. The recorder:

- uses the Python standard library only (`pty`, `termios`, `select`,
  `signal`) and has no third-party or `script(1)` dependency;
- allocates a PTY for the child, puts its own stdin in raw mode while
  forwarding, copies the initial window size and propagates every SIGWINCH;
- forwards input unchanged and copies child output both to the pane and to a
  `scripts/session-log-writer` child, which keeps the same rotation and
  append-only semantics as tmux. The log therefore holds the same raw terminal
  stream that `pipe-pane` captures;
- passes the child's exit status through. On SIGHUP or SIGTERM it forwards the
  signal to the child and waits for it;
- never kills the agent because logging failed. A dead writer leaves a single
  `# log capture failed …` line where possible and passthrough continues;
- answers `--contract` with `{"version":1,…}` and no side effects, so launch
  preflight and doctor can negotiate it like the other helpers;
- adds no secrets of its own.

`NOGG_STARTUP_LOG` keeps working, because the startup stderr sink lives inside
`session-launch`, below the recorder.

If gate item (e) failed for an agent, the herdr backend refuses that agent at
launch with a message to use `--backend tmux`.

### 6. herdr addressing, liveness and termination

- Each Nogging session is one pane labelled with the session name. It lives in
  a workspace named after the repository slug, inside the dedicated herdr
  session `session_herdr_session`, created through the CLI form the spike
  verified (`layout.apply`, `pane.split` or `agent.start`).
- Env: the existing `NOGG_SESSION_*`, `NOGG_OPENSPEC_FENCE` and
  `NOGG_STARTUP_LOG`, plus `HERDR_AGENT=<agent>` so that herdr's detection
  manifest sees through the wrapper. Env is passed through the pane env
  parameter, or as an `env` argv prefix where the CLI lacks one.
- The server is started headless on demand where the spike shows it is needed,
  the same way tmux auto-starts its server. No service is installed.
- **Liveness is bound to the launched process.** A herdr record is alive when
  both of these hold:
  - its pane resolves, by `pane_id` or else by unique label;
  - the pane's root process equals the recorded `session_pid` with the same
    `session_pid_start`.

  A restored pane with the same label but a different process is not this
  session. After a herdr server restart or `herdr update` without `--handoff`,
  Nogging records therefore reconcile to `failed`, exactly like a vanished tmux
  session, whether or not pane IDs are stable.
- `kill` closes the pane. If the spike shows that `pane.close` does not
  terminate the process, the backend signals the recorded process group, only
  after re-verifying the PID start time, using SIGTERM, then the stop grace
  period, then SIGKILL. A pane whose process already exited is closed by
  cleanup.
- `idle_shutdown` is a no-op. Nogging never stops the herdr server, never runs
  `herdr update`, and never touches non-Nogging panes or other herdr sessions.

### 7. Native resume never bypasses the launch wrapper

herdr's restore re-runs an agent through its native resume command. That
process would start without Nogging's effective settings, prompt, command
floor or OpenSpec boundary helper, which is a least-authority violation. In
this change herdr auto-restore of agents is therefore **disabled for Nogging
panes**. The spike verifies the narrowest control: per pane or per dedicated
session where possible, otherwise the documented herdr setting that the guide
asks the operator to set for the Nogging herdr session.

A restored Nogging-labelled pane that no live record owns is reported by
`session list` and closed by `session cleanup`; it is never adopted. Resume
works on both backends through Nogging's own exact resume
(`session launch --resume <id>` for Claude and Antigravity).

Gate item (d) records per-agent native-resume capability, so a later change
can route herdr resume through the wrapper.

### 8. Nudge and send verification on herdr

The policy is unchanged and stays above the seam: nudge refuses non-running
sessions; without `--message` it resends only positively identified input;
placeholders and ambiguity are never executed; `--message` clears, sends and
verifies with one bounded retry.

What changes is that `pane_input` consults the backend's `capture_attributes`
capability:

- With attributes (gate item (b) passed), Claude's framed-box dim
  classification is identical to tmux.
- Without attributes, plain text cannot tell a dim placeholder from input. In
  that case the Claude box classifies as `empty` (box present, no text) or
  `unknown` (box holds text). It is never `input` or `placeholder`. Nudge
  without `--message` is then a reported no-op that asks for `--message`. This
  matches the existing requirement.
- **Replacement check** after a `--message` nudge or `send --verify`
  without attributes: the submission is verified when either
  - herdr reports the agent `working` after the submit, or
  - the framed box is identifiable and no longer holds the submitted text.

  Otherwise the submit step is retried once, then the operation fails as
  "submission could not be verified".
- Codex verification (`undelivered_input` from plain text) and the Codex
  `codex queue` primary path are backend-independent and unchanged.

The Claude double Enter stays in `_submit_pane_input`. The spike confirms it
over `pane.send_keys`; a differing need becomes a key sequence inside the
herdr backend, never in the policy.

### 9. `agent_status` in `session list`

`session list` gets an `AGENT_STATUS` column. Its value is herdr's status for
a live herdr record (`idle`, `working`, `blocked`, `done` or `unknown`),
queried read-only per listing. It is `-` for tmux records, terminal records,
or a backend without the capability. A query that fails or is slow shows
`unknown` and never fails the listing; one bounded call per listing covers all
herdr records where the CLI allows it. `watch`, `sweep` and `doctor` keep the
Nogging adapters; status is additive.

### 10. Attach

`session attach <name>` `execvp`s the backend's `attach_argv`. For herdr that
is the herdr client attached to the dedicated session, focused on the pane.
If herdr offers no read-only client, `attach --read-only` on a herdr record is
refused with a pointer to `session log --follow`. It never silently attaches
read-write. The launch hint prints the backend's own attach command.

### 11. Usage reservations stay backend-neutral

`Reservations.bind` stores a backend-neutral liveness probe
`{backend, argv}`. The argv exits 0 when the session is alive: tmux
`has-session`, or herdr's verified pane query. `_alive` runs the probe and keeps
the rule that a tool failure is not proof of death. Entries written before this
change, carrying `tmux`/`socket`, are still read.

### 12. doctor

Herdr checks run **only** when `session_backend` is `herdr` or at least one
non-retired herdr record exists. Otherwise doctor prints nothing about herdr.

- When configured as the backend:
  - a missing binary or a recorder contract mismatch is a `FAIL`;
  - a version outside the verified `0.9.x` range is a `WARN`;
  - server reachability is a `NOTE`, because launch starts the server on
    demand.
- When only records exist, everything is a `NOTE` or `WARN`.
- Always, when shown, a `NOTE` that `herdr update` without `--handoff`, or a
  server restart, ends every Nogging herdr session, and that they then reap as
  `failed`.

Doctor uses two read-only CLI calls (version, reachability) directly, so it can
be built in parallel with the backend module against the fake stub.

### 13. Security posture

- No new listener: herdr's socket is a local Unix socket owned by the same
  non-privileged user. Nogging never enables herdr remote access or plugins,
  and never installs herdr integrations; the guide documents what each would
  modify (from the spike).
- Pane screen history stays off. The guide warns that it would persist terminal
  output, which can contain secrets.
- The launch wrapper, effective settings, command floor, OpenSpec boundary
  helper and redaction are identical on both backends. The recorded
  `command` is the redacted inner argv.

## Dependencies and parallel lanes

`A ← B` means A depends on B (`bd dep add A B`). Edges are explicit, not
inferred from task order.

| Task | Complexity | Depends on | Main files (ownership) |
| --- | --- | --- | --- |
| HDR-001 gate spike | complex | — | `scripts/fixtures/herdr/spike/` |
| HDR-002 seam + tmux extraction | complex | 001 | `scripts/nogg` (all call sites), `scripts/lib/session_backend{,_tmux}.py`, `scripts/nogg_usage.py`, packaging (script region) |
| HDR-003 selection + dispatch | standard | 002 | `scripts/nogg` (launch args, records, list `BACKEND`, orchestrator pin), `scripts/lib/session_backend.py`, `templates/nogging-config.json` |
| HDR-004 PTY recorder | complex | 001 | `scripts/session-pty-recorder` + its test |
| HDR-005 fake herdr CLI stub | standard | 001 | `scripts/fixtures/herdr/bin/herdr` + its self-test |
| HDR-006 herdr backend core | complex | 003, 004, 005 | `scripts/lib/session_backend_herdr.py`, registry line, packaging (script region) |
| HDR-007 nudge/send on herdr | standard | 006 | `scripts/nogg` (pane_input / verify region) |
| HDR-008 agent_status column | routine | 006 | `scripts/nogg` (session_list region) |
| HDR-009 doctor herdr checks | standard | 003, 004, 005 | `scripts/nogg` (doctor region) |
| HDR-010 docs + guide | standard | 003 | `docs/**`, `README.md`, `AGENTS.md`, `.nogging/launch-prompts/*`, packaging (docs region) |
| HDR-011 herdr lifecycle suite | standard | 006, 007, 008 | `scripts/session-herdr.test.sh` |
| HDR-012 Pi acceptance | complex | 009, 010, 011 | `docs/acceptance/<date>-herdr-backend.md` |

These lanes can run in parallel:

1. After 001: {002, 004, 005}.
2. After 003: {009 (also needs 004 and 005), 010}.
3. After 006: {007, 008}.

Sequential spine: 001 → 002 → 003 → 006 → {007, 008} → 011 → 012.

The seam (002 → 003) is deliberately sequential and alone in the big regions of
`scripts/nogg`. The later `scripts/nogg` tasks (007, 008, 009) edit disjoint
functions.

Before allocating a dependent worktree, a Lead verifies that every prerequisite
execution commit is integrated into `develop`; Bead closure alone is not
enough. The live tasks (001, 012) need a host session that can reach the herdr
Unix socket and start all three runtimes. They are not suitable for a sandboxed
Codex worker.

## Risks / Trade-offs

- **A young upstream** (v0.x, near-daily releases) whose API semantics are
  partly undocumented. Mitigations: the gate spike, a pinned verified `0.9.x`
  range with a doctor WARN outside it, fixtures captured from the real binary,
  and tmux remaining the default and fallback.
- **Persistence regression**: a herdr server restart or update kills panes.
  Mitigation: documented, doctor NOTE, `--handoff` guidance, process-bound
  liveness so records never lie, and exact resume through the wrapper.
- **The recorder changes the TUI's terminal path.** Mitigation: gate item
  (e), refusal per agent on failure, and a recorder test with a fake TUI
  (winsize, alternate screen, resize, exit codes).
- **The refactor touches about 40 call sites.** Mitigation: a no-behaviour-change
  task with the full existing suite green and a grep guard; the seam lands
  before any herdr code.
- **Doctor and backend duplicate two CLI forms** (version, reachability). This
  is accepted for parallelism and is small and test-covered.

## Migration / Rollback

There is no migration. Existing installs keep `tmux`, and legacy records read
as tmux. Rollback means setting `session_backend` back to `tmux` (or omitting
`--backend herdr`); running herdr records still resolve to their own backend
until they are stopped and cleaned up.

## Open Questions

Each open question is resolved by the TASK-HDR-001 spike and recorded as Bead
evidence and fixtures before dependent work:

- the exact CLI forms;
- namespace addressing;
- headless server start;
- `pane.close` semantics;
- read-only attach;
- the restore-disable control;
- auto-update.
