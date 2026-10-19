## MODIFIED Requirements

### Requirement: The orchestrator classifies every launch into a complexity tier

Before every sub-session launch of any role, the Orchestration Agent SHALL take three steps. It SHALL classify the task into one tier of the model-selection table (`routine`, `standard` or `complex`). It SHALL record a one-line reason in the Bead note or operator update. It SHALL launch with `--tier <tier>`. It SHALL take model and effort from the table, not from live research. It SHALL apply the documented escalation rules: when unsure, choose the higher tier, and on a relaunch after a failed or stalled attempt, escalate one tier. It SHALL NOT lower a tier because of quota pressure. A quota denial SHALL be handled by waiting for the limiting reset or by choosing another agent's entry for the same tier. A Product Owner preference about a tier's effort SHALL be recorded as a project `tier_overrides` entry in `.nogging/config.json`, made through the project's normal tracked change flow (for example a `routine` Bead) and checked with `scripts/nogg models check`; it SHALL NOT be handled by launching without `--tier` or by repeating a standing `--model`/`--effort` in place of the override. The orchestrator SHALL NOT edit `.nogging/model-selection.json` or `.nogging/config.json` itself. Until an override has landed, an explicit `--tier <tier> --effort <level>` on Product Owner instruction is the interim form. Explicit `--model` or `--effort` overrides SHALL be used only on Product Owner instruction, and SHALL be passed together with the honest `--tier` so attribution stays correct. When the Product Owner's Codex cost policy is in force (Codex defaults to `gpt-6-luna`; `gpt-6.1-sol` only with effort `low` and only for extremely hard tasks), the orchestrator SHALL launch Codex with `--model gpt-6-luna --effort <level>` by default, and with `--model gpt-6.1-sol --effort low` only for such a task. This procedure and these command spellings SHALL be stated in the orchestrator launch prompt, the `/orchestrate` command and the operating model, so a fresh orchestrator session applies it without memory of earlier conversations.

#### Scenario: Fresh orchestrator launches a Lead session

- **WHEN** a newly started orchestrator with no prior conversation launches a Lead session for a Bead
- **THEN** it records a tier with a reason and the launch carries `--tier`, which `session list` shows

#### Scenario: Quota pressure does not downgrade

- **WHEN** a task classified `complex` would exceed an account limit
- **THEN** the orchestrator waits for the reset or uses another agent's `complex` entry, and never launches the task at a lower tier

#### Scenario: Codex cost policy is applied

- **WHEN** a fresh orchestrator launches a Codex Lead for a `complex` task under the Product Owner's Codex policy
- **THEN** the launch carries `--tier complex --model gpt-6-luna --effort <level>`, and the prompt names `--model gpt-6.1-sol --effort low` as the only Sol spelling, reserved for extremely hard tasks

#### Scenario: Effort preference becomes a project override

- **WHEN** the Product Owner tells the orchestrator that `complex` Claude work should run at medium effort from now on
- **THEN** the orchestrator files the `tier_overrides` change as tracked work and keeps launching with `--tier complex`
- **AND** it does not launch with a standing `--model`/`--effort` pair instead of the tier

#### Scenario: Interim explicit effort keeps the tier

- **WHEN** the override has not landed yet and the Product Owner asks for one launch at medium effort
- **THEN** the launch carries `--tier complex --effort medium`, so `session list` still shows `tier=complex`
