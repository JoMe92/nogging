## Context

See proposal.md for motivation. `scripts/nogg` currently rejects every non-Claude orchestrator; its supervisor, trust check, adoption fallback and resume lookup assume Claude. The canonical lock, unit and tmux singleton already resolve from the main checkout. `stop` disables the service; there is no matching operator-facing `start` command. The current native launch already records exact Claude session IDs; older specification prose about `--continue` must not reintroduce latest-conversation selection.

The installed Happier CLI exposes `codex`, session status/stop and exact Happier-session resume. Its help is evidence of advertised interfaces, not proof of unattended startup, exact Codex-thread recovery or policy propagation. A regular Happier session created by the operator is independent of the Nogging singleton.

The canonical recovery report has existing unrelated mixed worktrees, a missing recorded worktree and paused rebase journals. They are preserved for their owners; this plan neither repairs nor incorporates their changes. Doctor reported no change ready to archive. Pending discoveries were reviewed; the relevant ones are carried into Decisions 1, 4 and 8. Existing discovery labels remain pending where this plan does not resolve their original tasks.

## Goals / Non-Goals

Goals: one owned orchestrator across both runtimes; durable operator intent; verified conversation identity; remote control that corresponds to the actual managed orchestrator; role-scoped authority; backwards-compatible installation.

Non-goals: simultaneous orchestrators, cross-provider conversation translation, conversion of the standalone Happier operator session, new agent runtimes, herdr orchestration, globally relaxed Codex policies, or implementing the change during planning. Claude through Happier is deferred; Claude retains native Remote Control.

## Decisions

### 1. Establish the runtime and Happier contracts before dependent code

TASK-DRO-001 records a bounded compatibility report in `docs/acceptance/<date>-orchestrator-runtime-contract.md`: installed versions, actual supported launch/resume arguments, exact native Codex thread receipt, Happier remote ID plus its associated Codex thread, readiness/liveness, stop semantics, policy propagation and log availability. Exercise an inert persona in an operator-approved scratch repository using a private host-born tmux socket and disposable service names. Never use production sessions, prompts, credentials or the shared socket for probes.

Prove that a Happier-wrapped Codex process can remain owned by the Nogging tmux session, that stopping it cannot leave a remote-controlled agent running, and that exact resume reconnects to its own conversation without selecting another thread for the cwd. Verify both the tmux process and the remote session; a wrapper process that only spawns a detached agent is insufficient evidence. Record effective Codex sandbox/approval/network and execpolicy behavior, not just Happier's permission label.

The existing command wrapper and supported CLI APIs are the chosen integration surface. Do not invent CLI flags, scrape an unrelated session or silently substitute an execution-run/subagent API. If the installed interfaces cannot satisfy this contract, record a blocking discovery on TASK-DRO-001 and return to planning; dependent implementation remains blocked. Exact option spelling and minimum tested versions are the output of this task, while the product contract and architecture remain fixed here.

### 2. Canonical persistent selection and an explicit start command

Add `orchestrator start [--agent claude|codex] [--control native|happier]`. Store desired selection and per-runtime resume checkpoints atomically in versioned canonical `.nogging/state/orchestrator.json`. This is operator state, not a tracked change to `.nogging/config.json`; native default configurations do not acquire a mandatory Happier dependency. Explicit arguments override persisted selection. Without a prior selection, Claude/native is the legacy default; an explicitly selected new Codex runtime defaults to Happier unless `--control native` is supplied. When changing only the agent, resolve that agent's default control rather than inheriting an incompatible old control. Claude/happier and unsupported runtimes fail before mutation.

`start` preflights runtime, authority, selected remote integration, installation and workspace trust before changing desired state or launching an agent. The command installs/re-enables the existing rendered per-repository unit when necessary, reloads user units and starts it. It does not install lingering, log in, accept workspace trust, write user-global settings or launch unobserved fallback processes. Missing prerequisites fail with a concrete operator remedy; optional lingering is reported separately. The unit continues to execute `orchestrator run`, which reads the canonical selection. A manual `run` with no selection state keeps the Claude/native behavior.

Starting the same healthy selection is idempotent. A different selection while the unit, supervisor lock or owned agent is live is refused before changing state. Switching is `stop` -> verify no owned live process/remote session -> `start --agent ...`; no automatic failover on quota or provider failure. A stopped selection and each provider's checkpoint survive `stop` for the next start. Corrupt or unknown-version state is preserved and rejected with recovery guidance, never replaced by a Claude guess. Linked-worktree start/status/stop/restart resolve the main checkout; `run` still refuses from a linked checkout.

### 3. Codex receives the existing orchestrator authority exception only for this role

Ship `.nogging/launch-profiles/orchestrator.codex.toml` and reuse the shared orchestrate-only prompt. The intended authority is unrestricted host execution, no interactive approvals, network access and no execution OpenSpec fence, matching Claude's existing orchestrator exception. The prompt still permits direct planning/code changes only during a named takeover, with the canonical planning lock for planning and a claimed Bead for execution. Human acceptance remains unsigned.

TASK-DRO-001 must demonstrate a supported per-invocation policy path. TASK-DRO-003 then implements that path without editing, disabling or renaming repository/global Codex rules for other sessions, copying secrets, or changing user-global trust. If installed Codex policy cannot express the exception without weakening other roles, launch refuses and the task becomes a blocking discovery. `lead`, `planning` and `specialist:*` launches that select the orchestrator profile must either normalize to their usual role authority/floor/fence or reject before side effects; they must never inherit the exception. Record actual authority and its provenance, not an assumed FULL-ACCESS flag.

Use native Codex exact-thread receipt/resume machinery where it already exists, with model/effort forwarded through the validated wrapper contract. The Codex default follows the Product Owner's Luna policy (`gpt-6-luna`, medium effort); an explicit supported override is recorded. Claude model behavior is unchanged. The runtime-neutral persona names the supported local workflow entry points so Codex can follow `/orchestrate` intent without requiring Claude slash-command dispatch. Other-agent floor behavior and the manual Claude permission template remain unchanged.

### 4. One tmux-owned supervisor and provider-specific exact recovery

Keep the existing canonical systemd unit, orchestrator lock and fixed tmux session name. Happier is a remote-control adapter around Codex inside that owned session, not a replacement session backend. No new herdr path is introduced; the existing session-backends specification remains valid.

Persist requested agent/control separately from observed identity, including managed session name, runtime conversation ID, Happier session ID when applicable, working directory, role, timestamps, effective authority, readiness and exit reason. Checkpoint each `(agent, control)` independently so stop/switch/switch-back can resume its previous exact conversation without overwriting the other provider's checkpoint. Keep remote IDs distinct from Codex thread IDs. Native/Happier changes do not transfer a thread implicitly.

A live session is adopted only when its durable ownership, main checkout, role, runtime/control and process/remote identities match. A recordless or ambiguous tmux singleton is reported as unknown and refused, never synthesized as Claude or killed as foreign. Legacy records without agent mean Claude only when existing Claude ownership/ID evidence verifies that interpretation. Preserve unrelated transcripts and regular Happier sessions.

Restart and service recovery use the matching checkpoint. First use cold-starts with the current persona. A recorded ID whose conversation is missing, corrupt, owned by another context or incompatible fails with a remedy; do not silently resume the cwd's newest conversation or cold-start after losing known state. A verified prior launch that never established a conversation can retry its initial cold start. Supervisor-only restart adopts the same owned live session and starts no second agent. A full restart refreshes runtime configuration and preserves its exact conversation. Keep the current guard against terminating one's own control session mid-restart.

Discovery context: SPEC-3nwm documented Claude trust/disclaimer hazards and latest-cwd resume ambiguity. SPEC-22a8 and SPEC-t374 document incomplete Codex lifecycle acceptance, null process ownership and unverified message delivery. Do not treat those older reports as acceptance of this design. Launch must establish the host-owned process and exact runtime receipt; user messages need actual receipt evidence, and unverified delivery is not automatically resent.

### 5. Happier access belongs to the managed Codex session

For Codex/happier, the wrapper supplies the validated authority, model, effort, cwd and persona, captures its own remote session ID and exact Codex thread, and reports readiness only after backend initialization and remote registration. Use only documented supported interfaces verified in Decision 1. `status` displays the actual Happier session ID and a link only when the integration supplies one; operator instructions tell the user to open that exact session in Happier. Never infer an ID by selecting the newest remote session for the path.

Remote readiness and agent liveness are separate. An API timeout produces unknown/degraded remote state and bounded retry/backoff, not a second agent. Authentication failure or unsupported integration fails explicitly without auto-login, account switch, provider switch or native fallback. A live Codex process does not imply Happier is reachable. Native Codex is available only through explicit native selection and reports that mobile access is not configured.

`stop` disables future automatic service restart, terminates the owned runtime/adapter with the existing graceful timeout, and confirms the owned remote session is inactive. Never archive/delete conversations merely to stop execution. If termination or remote verification is uncertain, report partial/unknown stop, retain ownership/checkpoint evidence and refuse a new start until reconciled. A transient remote outage must not discard the singleton or launch a replacement. Foreign Happier sessions and unrelated tmux panes are never touched.

### 6. Diagnostics, payload and migration are part of the feature

Expose desired agent/control and observed runtime/conversation/remote IDs, readiness, authority and exit reason in `orchestrator status` (including versioned JSON), `session list`, `doctor` and recovery evidence. Keep existing native log/attach/send operations useful for both runtimes; route transport-specific inspection/delivery through the adapter when a wrapped Codex TUI is unavailable. A normal Happier session remains a normal session and cannot acquire the orchestrator role from its title/tag. Use the existing source-attributed token collection; unknown wrapped runtime usage remains unknown, never borrowed from another Codex session or reported as zero.

Update package manifests/helper contracts, rendered-unit handling, init/update/remove and installation/security/operating/architecture/recovery/Codex guides, canonical AGENTS.md and installed instruction copies, plus `.codex/prompts/orchestrate.md` with matching Claude entry-point guidance. Update preserves operator selection, checkpoints, unrelated settings and locally modified managed files using the existing pending-update mechanism. Init without systemd remains inert; native Claude works with no Happier installed. Removal follows explicit existing removal semantics and never deletes provider transcripts.

Migration reads a legacy verified Claude record as Claude/native, preserving its exact ID. Do not start a service during package update. Rollback is explicit stop, verify termination, then select Claude/native using the installed version's supported state format; preserve a backup of new state before a downgrade. Do not edit state while an old supervisor is live.

### 7. Explicit dependency and execution contract

Use stable TASK-DRO IDs. Explicit Beads edges (`A <- B`) are: 002<-001; 003<-002; 004<-003; 005<-004; 006<-005; 007<-006; 008<-007. These are deliberately serial because state, wrapper and supervisor contracts overlap in `scripts/nogg`. TASK-DRO-001 uses docs/, 002-005 feat/, 006 docs/, and 007-008 test/ branches for `dual-runtime-orchestrator`; reuse a lane only after its predecessor is integrated and retired. Before allocating a dependent execution worktree, verify prerequisite commits are integrated into develop, not merely that a Bead is closed.

The Main Worker claims one named Bead and executes its design/spec slice. Follow current AGENTS.md for validation, close -> task-done -> one Conventional implementation commit including the task tick -> SHA/evidence note. Execution never edits OpenSpec directly. Specialists, if explicitly dispatched later, follow their existing role boundaries. Planning materializes unclaimed Beads and does not perform any runtime probe or implementation.

### 8. Meaningful isolated validation and unsigned live acceptance

Focused suites use fake runtime/Happier/systemctl responses, temporary HOME/state/config, scratch Git repositories, bounded timeouts and short private socket paths. They must not connect to real Dolt/Beads, alter user settings, rely on PID ranges, require real namespaces, signal the fleet, run a background production service or recursively run the full suite. Include missing auth/trust/profile/CLI, unsupported flags, corrupt state, exact ID mismatch, cross-runtime adoption, concurrent starts, graceful-stop timeout, a detached surviving remote process, API outage and role/profile authority isolation. Verify native Claude still works without Happier and herdr defaults cannot move the orchestrator off tmux.

TASK-DRO-007 runs the relevant existing suites and one full `scripts/test` after integration. TASK-DRO-008 performs actual scratch-host acceptance for Claude/native, Codex/native and Codex/happier: cold start/persona, benign remote request and verified reply, own exact resume after process loss and service restart, reboot-equivalent recovery, supervisor-only adoption, stop from a linked checkout, repeat stop, stop/switch/switch-back, second-start refusal and survival of unrelated sessions. Verify at most one agent at every stage and that stop leaves no remotely operable owned process. Systemd reboot-equivalent tests alone do not prove an actual host reboot; report the distinction.

The real tmux birth must occur in the host namespace; SPEC-iohv shows that current namespace warnings can be wrong (SO_PEERCRED field order), so do not use that warning as proof. Its nudge timing discovery also means an exit-zero/queue acceptance alone is insufficient proof of a delivered mobile instruction. These findings stay with their original Beads; acceptance can record a blocking discovery if they prevent the scoped checks, never fix them ad hoc here. The packed orchestrator fixture issue from SPEC-t374 is relevant regression coverage: only execution roles should be asserted fenced; TASK-DRO-007 reconciles fixtures with the actual role contract.

Write versioned, redacted, dated evidence in `docs/acceptance/<date>-dual-runtime-orchestrator.md`, leave `Signed-off-by:` empty, and distinguish pass/fail/skipped/unknown. Quota, missing authorization or unverified mobile behavior means acceptance remains incomplete. No unrelated Bead is closed or claimed to make the report appear complete.

## Risks / Trade-offs

- Happier's wrapper may detach or expose insufficient identity/resume controls -> compatibility gate blocks dependent work rather than shipping an unowned agent.
- Codex policy may prevent the existing unrestricted orchestrator exception -> verify a scoped invocation; preserve other sessions' floor and return to planning if unsupported.
- Provider or remote outage resembles process death -> reconcile process and remote identities separately, retain unknown ownership and bound retries.
- Full host authority and an auto-resumed persona remain a standing injection target -> preserve explicit opt-in, visible actual authority, takeover discipline, canonical singleton and human sign-off.
- Existing live acceptance gaps are not proof of runtime failure or success -> use new scratch evidence, retain unsigned reports and block acceptance honestly.
