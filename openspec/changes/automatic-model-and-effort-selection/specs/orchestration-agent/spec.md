## ADDED Requirements

### Requirement: The orchestrator classifies every launch into a complexity tier

Before every sub-session launch of any role, the Orchestration Agent SHALL take three steps. It SHALL classify the task into one tier of the model-selection table (`routine`, `standard` or `complex`). It SHALL record a one-line reason in the Bead note or operator update. It SHALL launch with `--tier <tier>`. It SHALL take model and effort from the table, not from live research. It SHALL apply the documented escalation rules: when unsure, choose the higher tier, and on a relaunch after a failed or stalled attempt, escalate one tier. It SHALL NOT lower a tier because of quota pressure. A quota denial SHALL be handled by waiting for the limiting reset or by choosing another agent's entry for the same tier. Explicit model or effort overrides SHALL be used only on Product Owner instruction. This procedure SHALL be stated in the orchestrator launch prompt, the `/orchestrate` command and the operating model, so a fresh orchestrator session applies it without memory of earlier conversations.

#### Scenario: Fresh orchestrator launches a Lead session

- **WHEN** a newly started orchestrator with no prior conversation launches a Lead session for a Bead
- **THEN** it records a tier with a reason and the launch carries `--tier`, which `session list` shows

#### Scenario: Quota pressure does not downgrade

- **WHEN** a task classified `complex` would exceed an account limit
- **THEN** the orchestrator waits for the reset or uses another agent's `complex` entry, and never launches the task at a lower tier
