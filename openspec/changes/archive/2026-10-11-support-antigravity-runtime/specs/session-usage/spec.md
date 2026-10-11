## ADDED Requirements

### Requirement: Antigravity quota uses the selected model group and each limiting bucket

The Antigravity usage adapter SHALL normalize the runtime read-only /usage result, select the chosen model group and evaluate weekly and short buckets independently. Unknown model/group mapping SHALL be unknown usage. Resume timing SHALL honor all exhausted applicable buckets; a headless response with denied_actions or error status SHALL not be accepted as success solely because exit status is zero.

#### Scenario: Independent quota pools

- **WHEN** the selected model belongs to a different group than another running model
- **THEN** admission uses the selected group buckets only

#### Scenario: Weekly bucket blocks resume

- **WHEN** weekly quota remains exhausted after short-window reset
- **THEN** resume waits for the limiting weekly reset rather than resuming immediately
