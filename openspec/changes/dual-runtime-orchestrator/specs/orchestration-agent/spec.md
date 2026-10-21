## REMOVED Requirements

### Requirement: The Orchestration Agent is a Claude Code persona in this version

**Reason**: Claude Code and Codex are both supported orchestrator runtimes.
**Migration**: Existing verified Claude sessions retain Claude/native selection and their own exact conversation. Codex is selected explicitly using the common lifecycle commands; other runtimes remain unsupported.

## MODIFIED Requirements

### Requirement: The orchestrator runs always-on and recovers itself

Nogging SHALL provide an opt-in systemd user service running `scripts/nogg orchestrator run` that supervises one owned tmux orchestrator session using the persisted Claude Code or Codex selection. With user lingering enabled it SHALL recover after supervisor failure or host reboot. Recovery SHALL adopt only a live session verified to belong to this orchestrator, selected runtime/control and main checkout, or resume that selection's exact recorded conversation. It SHALL NOT choose the newest conversation for a working directory. A first launch SHALL receive the current orchestrator persona; an invalid established conversation SHALL fail with recovery guidance rather than select an unrelated conversation or silently start fresh.

`orchestrator restart` SHALL terminate the owned runtime session and restart the service with the current prompt/settings and its own conversation checkpoint. `restart --supervisor-only` SHALL adopt the same verified live runtime without launching another agent. Restart from within the session it would terminate SHALL be refused. Native Claude SHALL retain Remote Control registration. Codex with Happier control SHALL expose its actual managed session through Happier; explicit native Codex SHALL report mobile access as not configured.

#### Scenario: The orchestrator returns after a crash

- **WHEN** an enabled orchestrator supervisor exits unexpectedly
- **THEN** systemd restarts it with the persisted runtime/control
- **AND** it adopts the verified owned live session or resumes that selection's own exact conversation

#### Scenario: The orchestrator returns after a reboot

- **WHEN** the delivery host reboots with the orchestrator service enabled and user lingering on
- **THEN** the service starts without an interactive login using its saved runtime/control and conversation

#### Scenario: The orchestrator is reachable from a phone

- **WHEN** native Claude or Happier-controlled Codex reports remote readiness
- **THEN** the operator can read and send a benign instruction to the actual managed orchestrator through its selected remote interface
- **AND** status identifies that session without claiming an unrelated Happier session

#### Scenario: Operator restarts the orchestrator

- **WHEN** `scripts/nogg orchestrator restart` is invoked from outside the orchestrator
- **THEN** the owned runtime is terminated cleanly, its exit reason is recorded as restarted by operator, and the supervisor relaunches the selected runtime with its current settings and exact conversation

#### Scenario: Supervisor-only restart adopts the live session

- **WHEN** `scripts/nogg orchestrator restart --supervisor-only` is invoked
- **THEN** the verified owned runtime remains live, the supervisor adopts it and no second agent starts

#### Scenario: An ambiguous live session is not adopted

- **WHEN** the singleton tmux name exists without sufficient matching ownership/runtime evidence
- **THEN** startup reports unknown ownership and refuses without adopting or terminating it

#### Scenario: An established conversation is missing

- **WHEN** a recorded orchestrator conversation cannot be verified or resumed
- **THEN** startup fails with a concrete recovery instruction while preserving the checkpoint and unrelated conversations

## ADDED Requirements

### Requirement: Operators can select and start either orchestrator runtime

`scripts/nogg orchestrator start` SHALL accept `--agent claude|codex` and `--control native|happier`, persist the resolved selection in canonical versioned repository state and enable/start the repository's installed or rendered user service. Supported combinations SHALL be Claude/native, Codex/native and Codex/happier. Explicit selection SHALL override saved selection; absent saved/explicit selection SHALL mean Claude/native. Selecting Codex without a control or prior Codex selection SHALL default to Happier; selecting a different agent SHALL resolve that agent's control default rather than inherit an incompatible control. A repeated matching healthy start SHALL be idempotent. Changing runtime/control while an orchestrator may still be live SHALL be refused before selection changes. Runtime selection SHALL NOT change orchestrate-only scope, takeover rules, task ownership or human acceptance boundaries.

Runtime, authority, trust and selected-control prerequisites SHALL be checked before launching an agent. Missing dependencies, authentication, unsupported combinations, malformed/unknown-version state or service failures SHALL produce a nonzero result with a remedy. No command SHALL silently log in, accept trust, enable lingering, alter global permissions or substitute a runtime/control mode. Existing no-state `run` behavior SHALL retain the Claude/native default; linked-checkout lifecycle commands SHALL target the canonical repository, while linked-checkout `run` remains refused.

#### Scenario: Legacy installation starts Claude

- **WHEN** an operator runs `orchestrator start` without prior selection state
- **THEN** the canonical Claude/native service is enabled and started with the existing persona

#### Scenario: Operator explicitly starts Codex in Happier

- **WHEN** prerequisites are available and `orchestrator start --agent codex --control happier` is run
- **THEN** the managed Codex orchestrator starts and its selection survives service restart

#### Scenario: A live Claude orchestrator cannot be replaced implicitly

- **WHEN** an operator requests Codex while a Claude orchestrator is live or has unknown liveness
- **THEN** the request is refused with stop/reconcile guidance and no selection, checkpoint or process is replaced

#### Scenario: Native Codex does not require Happier

- **WHEN** an operator explicitly selects Codex/native on a host without Happier
- **THEN** native startup can succeed and status honestly reports mobile access as not configured

#### Scenario: Unsupported remote control refuses before mutation

- **WHEN** an operator requests Claude/happier or Codex/happier without its required compatible installation/authentication
- **THEN** startup fails before creating an agent or modifying the saved selection and names the missing prerequisite

### Requirement: Stop and switching preserve singleton ownership and provider history

`orchestrator stop` SHALL stop/disable the canonical supervisor and terminate its owned runtime and control adapter, with a bounded graceful timeout, without deleting conversations. It SHALL be idempotent and SHALL preserve provider/control-specific exact checkpoints. It SHALL NOT affect unrelated tmux panes or Happier sessions. A partial or unverifiable termination SHALL return nonzero with retained ownership evidence and SHALL prevent a replacement start until reconciled. A switch SHALL consist of verified stop followed by explicit start; switching back SHALL use that selection's previous exact checkpoint, never another provider's ID. The existing canonical orchestrator lock and cross-namespace liveness rules SHALL apply across all selections.

#### Scenario: Stop Codex from a linked checkout

- **WHEN** `orchestrator stop` is run from a linked worktree for a Happier-controlled Codex orchestrator
- **THEN** it disables the canonical service, terminates the owned Codex/adapter, verifies the owned remote session is inactive and preserves its checkpoint
- **AND** unrelated Happier sessions and the shared tmux server remain untouched

#### Scenario: Stop cannot verify a detached remote process

- **WHEN** local termination succeeds but the owned Happier runtime remains active or its termination cannot be verified
- **THEN** stop reports partial/unknown failure, retains ownership evidence and a subsequent start refuses duplication

#### Scenario: Switch back to Claude

- **WHEN** an operator verifiably stops Claude, starts and stops Codex, then starts Claude again
- **THEN** Claude resumes its own saved conversation while Codex's checkpoint remains available separately

### Requirement: Happier readiness and identity describe the owned Codex orchestrator

Codex/happier SHALL be a supported remote-control adapter inside the managed tmux lifecycle. Startup SHALL record both the exact Happier session ID and associated Codex conversation ID from attributable evidence. Status SHALL distinguish process liveness, backend readiness and remote reachability, and expose the actual session ID plus a link only when supplied by the integration. A remote timeout SHALL report unknown/degraded state without launching another agent or selecting another session. A transport failure SHALL NOT silently fall back to native control. Operator messages SHALL have verified receipt or an explicit unverified outcome without automatic duplicate resend. Authority, persona and model/effort SHALL reach the actual Codex backend through a verified interface.

#### Scenario: The operator opens the correct Happier session

- **WHEN** a managed Codex/happier orchestrator becomes ready
- **THEN** status identifies the exact remote session that operates its recorded Codex conversation
- **AND** a separate Happier session in the same repository remains distinct

#### Scenario: Happier is temporarily unreachable

- **WHEN** remote inspection times out while the owned runtime may still exist
- **THEN** status reports unknown remote reachability and the supervisor starts no replacement agent

#### Scenario: Requested authority is not propagated

- **WHEN** the adapter cannot verify the required effective backend policy
- **THEN** startup fails with evidence and does not claim FULL-ACCESS or readiness from a Happier permission label alone

### Requirement: Runtime selection and migration remain observable and installable

The installed payload SHALL include the Codex profile, shared persona, Codex orchestration entry point, validated helpers and both-runtime lifecycle documentation. Update SHALL preserve saved selection, exact checkpoints, user-global settings and locally modified managed files, and SHALL NOT start a service. Verified legacy Claude records SHALL migrate as Claude/native using their own ID. `orchestrator status` SHALL provide human-readable and versioned JSON runtime/control, ownership and readiness data; session listing, doctor and recovery SHALL expose consistent diagnostics and actual authority. Wrapped Codex token accounting SHALL remain source-attributed or explicitly unknown. Native Claude SHALL remain usable without Happier installed.

#### Scenario: Upgrade preserves a stopped Codex selection

- **WHEN** the package updates a repository with Codex selected and its service stopped
- **THEN** the selection/checkpoints are preserved, the compatible payload is installed and no agent is launched

#### Scenario: A legacy Claude record is verified

- **WHEN** a legacy record without an agent field has verified owned Claude identity
- **THEN** it is interpreted as Claude/native and its own exact conversation is retained

#### Scenario: Missing usage evidence is honest

- **WHEN** a wrapped Codex session has no attributable usage source
- **THEN** diagnostics report unknown usage rather than zero or another session's totals
