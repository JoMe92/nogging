## MODIFIED Requirements

### Requirement: The orchestrator classifies every launch into a complexity tier

Before every sub-session launch of any role, the Orchestration Agent SHALL take three steps. It SHALL classify the task into one tier of the model-selection table (`routine`, `standard` or `complex`). It SHALL record a one-line reason in the Bead note or operator update. It SHALL launch with `--tier <tier>`. It SHALL take model and effort from the table, from a project `tier_overrides` entry or from the project's agent routing entry, not from live research. It SHALL apply the documented escalation rules: when unsure, choose the higher tier, and on a relaunch after a failed or stalled attempt, escalate one tier. It SHALL NOT lower a tier because of quota pressure. A quota denial SHALL be handled by waiting for the limiting reset or by another agent's entry for the same tier, which a routed launch does mechanically. When the project's agent routing file has a list for the launch role, the orchestrator SHALL launch without `--agent` so the routing decides, SHALL copy the printed `routing=` line into the Bead note next to the tier reason, and MAY preview the decision with `scripts/nogg route`. It SHALL pass `--agent` only on Product Owner instruction, for an exact resume, or to use an allow-listed alternative model whose entry `note` condition holds, recording why. A relaunch after a provider runtime limit SHALL keep the tier and add `--skip-agent <agent>`. A Product Owner preference about a tier's effort SHALL be recorded as a project `tier_overrides` entry in `.nogging/config.json`, made through the project's normal tracked change flow (for example a `routine` Bead) and checked with `scripts/nogg models check`; it SHALL NOT be handled by launching without `--tier` or by repeating a standing `--model`/`--effort` in place of the override. A Product Owner preference about agent order, backend or per-agent models SHALL be recorded in the agent routing file: a tracked file through a `routine` Bead, a host-local file by the orchestrator on that explicit instruction, each followed by `scripts/nogg route check`. The orchestrator SHALL NOT edit `.nogging/model-selection.json` or `.nogging/config.json` itself, and SHALL NOT change the routing file on its own initiative. Until an override has landed, an explicit `--tier <tier> --effort <level>` on Product Owner instruction is the interim form. Explicit `--model` or `--effort` overrides SHALL be used only on Product Owner instruction or for an allow-listed alternative as above, and SHALL be passed together with the honest `--tier` so attribution stays correct. The shipped procedure SHALL NOT name a fixed agent order or a fixed model for any agent. This procedure and these command spellings SHALL be stated in the orchestrator launch prompt, the `/orchestrate` command and the operating model, so a fresh orchestrator session applies it without memory of earlier conversations.

#### Scenario: Fresh orchestrator launches a Lead session

- **WHEN** a newly started orchestrator with no prior conversation launches a Lead session for a Bead
- **THEN** it records a tier with a reason and the launch carries `--tier`, which `session list` shows

#### Scenario: Quota pressure does not downgrade

- **WHEN** a task classified `complex` would exceed an account limit
- **THEN** the orchestrator waits for the reset or uses another agent's `complex` entry, and never launches the task at a lower tier

#### Scenario: Codex cost policy is applied

- **WHEN** a project's routing file maps the Codex `complex` entry to `gpt-6-luna` and allow-lists `gpt-6.1-sol` only at effort `low` with the note "extremely hard tasks only", and a fresh orchestrator launches a Codex Lead for a `complex` task
- **THEN** the routed launch carries `--tier complex` and Codex receives `gpt-6-luna` from the entry, and `gpt-6.1-sol` is launched only pinned with `--effort low` when the note's condition holds
- **AND** the policy comes from the project's routing file, and the shipped prompt names no Codex model

#### Scenario: Routing decides the agent

- **WHEN** a fresh orchestrator launches a Lead for a `standard` task in a project whose routing file lists Pi, Codex and Claude for `lead`
- **THEN** the launch carries `--tier standard` and no `--agent`, and the Bead note gains the tier reason and the `routing=` line

#### Scenario: An allow-listed alternative is used only under its note

- **WHEN** a task meets the condition in the `note` of an allow-listed Codex model at effort `low`
- **THEN** the orchestrator launches `--agent codex --tier <tier> --model <that model> --effort low` and records why in the Bead note

#### Scenario: A runtime limit relaunch skips the limited agent

- **WHEN** a routed Pi Lead stops in the `limit` state
- **THEN** the relaunch keeps the tier and passes `--skip-agent pi`

#### Scenario: Effort preference becomes a project override

- **WHEN** the Product Owner tells the orchestrator that `complex` Claude work should run at medium effort from now on
- **THEN** the orchestrator files the `tier_overrides` change as tracked work and keeps launching with `--tier complex`
- **AND** it does not launch with a standing `--model`/`--effort` pair instead of the tier

#### Scenario: Agent order preference goes into the routing file

- **WHEN** the Product Owner asks for a different agent order from now on
- **THEN** the change lands in the routing file through the documented path and `scripts/nogg route check` passes, and the orchestrator does not keep the order only in its memory or prompt

#### Scenario: Interim explicit effort keeps the tier

- **WHEN** the override has not landed yet and the Product Owner asks for one launch at medium effort
- **THEN** the launch carries `--tier complex --effort medium`, so `session list` still shows `tier=complex`
