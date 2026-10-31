## ADDED Requirements

### Requirement: A usage limit is waited out and resumed once, never nudged

While a Lead is in the `limit` state from any source, the dispatcher SHALL send no nudge and SHALL queue no item for an idle, clean tree. When its reset time has passed, the dispatcher SHALL send exactly one resume per distinct limit error. A resume whose turn meets the limit again SHALL be treated as a new limit with its own reset time and its own resume key, so a limit that outlasts the reported reset cannot loop. A Codex limit read from the rollout or the pane SHALL follow this rule exactly as an event-sourced limit does. When a limit has no readable reset time, the dispatcher SHALL send nothing and SHALL queue one `stuck` item that names the usage limit and the missing reset time, which clears when the state leaves `limit`.

#### Scenario: No nudge while a Codex session is at its limit

- **WHEN** two passes run, a minute apart, on a Codex Lead at `limit` from the rollout, with a clean tree and no pull request
- **THEN** no nudge is sent and no `stuck` item with the reason `idle, clean, no pull request and no signal` is queued

#### Scenario: One resume after the reset

- **WHEN** a pass runs after the reset time of a rollout-sourced limit
- **THEN** one resume is sent, and a second pass on the same limit error sends none

#### Scenario: A resume that hits the limit again waits again

- **WHEN** the resumed turn ends in a newer limit error with a later reset time
- **THEN** no further resume is sent before that later time, and one is sent after it

#### Scenario: Unknown reset time

- **WHEN** a limit's message holds no readable time
- **THEN** no nudge and no resume is sent, and one `stuck` item names the usage limit and the unknown reset time
- **AND** the item is gone once the state leaves `limit`

### Requirement: The latest run of each check decides red and green

When the dispatcher or the session sweep reads a pull request's checks, it SHALL reduce the commit's check rollup to the newest run of each check, keyed by workflow and name for a check run and by context for a status, using the start time and falling back to the completion time. An older failed run of a check that a newer run replaced SHALL NOT count as failing. A newer failed run SHALL count as failing and a newer unfinished run as pending. Entries that tie or carry no usable time SHALL keep the worse outcome. The check fingerprint SHALL be computed over the reduced entries. The same reduction SHALL decide whether a closed or merged pull request's checks are resolved. A rollup that cannot be parsed SHALL still be `unknown`, never passing.

#### Scenario: A later success clears an earlier failure on the same commit

- **WHEN** a commit's rollup holds a failed `invariants` run started at 07:39 and a successful `invariants` run started at 07:58
- **THEN** the checks read `passing`, no check is listed as failed, and no CI nudge is sent

#### Scenario: A later failure still counts

- **WHEN** a successful run is followed by a newer failed run of the same check
- **THEN** the checks read `failing` and name that check

#### Scenario: A run from another pull request on the same commit

- **WHEN** a closed pull request's failed run and a newer successful run of the same check share the commit of the open pull request
- **THEN** the open pull request's checks read `passing`

#### Scenario: Merged-state checks use the same reduction

- **WHEN** a merged pull request's rollup holds a superseded failure and a newer success of that check
- **THEN** its checks are resolved and the pull request state is reported as merged

#### Scenario: Ties keep the failure

- **WHEN** two runs of one check carry the same start time and one failed
- **THEN** the check reads failing
