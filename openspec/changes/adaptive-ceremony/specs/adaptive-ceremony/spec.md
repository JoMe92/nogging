## ADDED Requirements

### Requirement: The ceremony switch defaults to today's behaviour

`.nogging/config.json` SHALL accept `ceremony.mode` with the values `always-full`, `adaptive` and
`always-fast`, plus the fast-lane file and line limits and the lite minimum score. An unset block
SHALL mean `always-full`. An unknown mode or a non-positive limit SHALL fall back to the default,
and `doctor` SHALL warn and name the key. Under `always-full` every behaviour of this capability
SHALL be inactive.

#### Scenario: No configuration changes nothing

- **WHEN** a repository has no `ceremony` block and an operator runs `nogg quick "Fix typo" --accept a --accept b --accept c`
- **THEN** the command refuses, names `ceremony.mode` as `always-full`, and creates no Bead

#### Scenario: An unknown mode falls back

- **WHEN** `ceremony.mode` is `sometimes`
- **THEN** `doctor` prints a WARN naming `ceremony.mode` and the mode in effect is `always-full`

### Requirement: Triage picks a lane by fixed rules

`nogg triage <description>` SHALL pick the full spec when the stated kind is feature or pipeline,
a public interface, security or high ambiguity is stated, or the description holds a full-spec
trigger word; otherwise a lite spec for 3 or more files; otherwise the fast lane for a bug,
refactoring, test or configuration task of 1 or 2 files; otherwise a lite spec. It SHALL print every
rule that fired, and the same input SHALL always give the same output.

#### Scenario: A security word forces the full spec

- **WHEN** an operator runs `nogg triage "Rotate the API token on expiry" --kind bug --files 1`
- **THEN** the rules' lane is full and the reason names the trigger word

#### Scenario: A small bug is fast

- **WHEN** an operator runs `nogg triage "Off-by-one in the page counter" --kind bug --files 2`
- **THEN** the rules' lane is the fast lane

#### Scenario: Missing facts never give the fast lane

- **WHEN** an operator runs `nogg triage "Tidy the help text"` with no kind and no file estimate
- **THEN** the rules' lane is lite and the reason names the missing facts

### Requirement: The mode decides the effective lane

Triage SHALL report the mode, the rules' lane and the effective lane: under `always-full` the
effective lane SHALL be full, under `adaptive` it SHALL be the rules' lane, and under `always-fast`
it SHALL be the fast lane. With `--bead <id>` triage SHALL append one line with the effective lane,
the mode, the rules' lane and the reasons to that Bead's note.

#### Scenario: The default keeps the full spec

- **WHEN** the mode is `always-full` and triage's rules pick the fast lane
- **THEN** the output shows the rules' lane as fast and the effective lane as full

#### Scenario: The reasons land on the Bead

- **WHEN** an operator runs triage with `--bead SPEC-ab12` under `adaptive`
- **THEN** the Bead's note gains one triage line naming the effective lane, the mode and the reasons

### Requirement: Fast-lane Beads are created without a change

`nogg quick "<title>" --accept "<criterion>"` SHALL create one Bead labelled `ceremony:fast`, with
3 to 5 acceptance criteria in its acceptance field, the triage line in its note and no `openspec:`
label, and print its ID. It SHALL refuse under `always-full`, when the effective lane is not fast
(naming the lane and the next step), and with fewer than 3 or more than 5 criteria.

#### Scenario: A fast-lane Bead is created

- **WHEN** under `adaptive` an operator runs `nogg quick` for a one-file bug with three criteria
- **THEN** one Bead with the label `ceremony:fast`, the three criteria and a triage note exists, and
  it carries no `openspec:` label

#### Scenario: Too few criteria are refused

- **WHEN** an operator runs `nogg quick` with two `--accept` criteria
- **THEN** the command refuses, names the count and the range 3 to 5, and creates no Bead

#### Scenario: A lane other than fast is refused

- **WHEN** an operator runs `nogg quick` for a task triage puts in the lite lane
- **THEN** the command refuses, names the lite lane, and points to a planning session

### Requirement: The mapping layer accepts fast-lane Beads

`nogg validate`, `materialize`, `sync`, the completion check and the archive readiness SHALL treat
a `ceremony:fast` Bead as a valid unmapped Bead. `task-done` SHALL finish a closed fast-lane Bead
within its limits without ticking any task, directly and through the sandbox broker.

#### Scenario: Validation and sync ignore the fast-lane Bead

- **WHEN** a repository holds a closed `ceremony:fast` Bead and runs `nogg validate` and
  `nogg sync --now`
- **THEN** neither reports a mapping defect for it and no `tasks.md` or execution log changes

#### Scenario: task-done finishes a fast-lane Bead

- **WHEN** a Lead runs `nogg task-done` for a closed fast-lane Bead within its limits
- **THEN** the command exits zero and states that there is no task to tick

### Requirement: A fast-lane Lead works from its acceptance criteria

The Lead kickoff for a `ceremony:fast` Bead SHALL name its title, its acceptance criteria and the
fast-lane rules: a reproducing test first for a bug, the file and line limits, and `needs-spec` on
overflow. Its branch SHALL be `<type>/fast-<bead-id>`; the branch rule SHALL accept that form only
when the configured mode is not `always-full`, reading the mode from the configuration file, and
`worktree implement` SHALL allocate it.

#### Scenario: The kickoff names the criteria

- **WHEN** a Lead is kicked off on a fast-lane Bead with three acceptance criteria
- **THEN** the kickoff message lists the three criteria and the file and line limits

#### Scenario: A fast-lane branch needs the switch

- **WHEN** the branch rule checks `fix/fast-spec-ab12`
- **THEN** it passes under `adaptive` and fails under `always-full`, naming the mode

### Requirement: A fast-lane Bead that outgrows its limits stops with needs-spec

The limits SHALL count production files and changed production lines from the branch's merge point
with `develop` plus staged changes; test files SHALL NOT count. Over a limit, the commit hook SHALL
refuse a commit whose token names a fast-lane Bead, `nogg test commit` and `nogg test bead` SHALL
report it, and `task-done` SHALL refuse; each SHALL print `needs-spec`, the counts and the limit.

#### Scenario: A third production file is refused

- **WHEN** a fast-lane branch already changes two production files and a commit adds a third
- **THEN** the commit hook refuses with `needs-spec` and names the three files and the limit of 2

#### Scenario: Tests do not count

- **WHEN** a fast-lane branch changes one production file and two test files
- **THEN** the hook allows the commit

#### Scenario: task-done is the backstop

- **WHEN** a fast-lane Bead's branch exceeds the line limit and its Lead runs `task-done`
- **THEN** `task-done` refuses with `needs-spec` and the counts

### Requirement: The escalation tells the Lead what to do

The `needs-spec` refusal SHALL name the Lead's next steps: stop implementing, add the `needs-spec`
and `discovery` labels with a prose note, set the Bead `blocked`, and signal blocked with
`needs-spec`. When `bd` cannot be reached, the commit hook SHALL warn and allow the commit.

#### Scenario: The refusal names the steps

- **WHEN** the commit hook refuses a fast-lane commit over its limit
- **THEN** its message names the `needs-spec` label, the blocked status and the blocked signal

#### Scenario: No bd, no block in the hook

- **WHEN** the commit hook cannot reach `bd` for a commit's Bead
- **THEN** it prints a warning and allows the commit

### Requirement: Lite specs pass strict OpenSpec validation

A scaffold command SHALL write a lite change from a shipped template during a planning session: a
`proposal.md` with why, what and the eight completeness sections, an `.openspec.yaml` that marks the
change lite and needs no spec deltas, and a `tasks.md` with a task line, so that `openspec validate
<change> --strict` and `materialize` accept it. It SHALL refuse under `always-full` and when the
installed OpenSpec cannot validate a lite change, naming the version it needs.

#### Scenario: A scaffolded lite change validates

- **WHEN** a planner scaffolds a lite change under `adaptive` and fills in its sections
- **THEN** `openspec validate <change> --strict --no-interactive` exits zero and `materialize`
  creates its Bead

#### Scenario: A lite change under the default is refused

- **WHEN** `nogg validate` finds a lite change while the mode is `always-full`
- **THEN** it refuses and names the change and `ceremony.mode`

### Requirement: A lite spec under 6 of 8 points goes back

`nogg validate` SHALL score a lite change's eight sections (goal, non-goals, acceptance criteria,
edge cases, constraints, affected areas, validation, risks); a section SHALL count when it holds a
line that is neither empty nor the template's placeholder. A score under the configured minimum
(default 6) SHALL be a refusal naming the missing points. A full change SHALL NOT be scored.

#### Scenario: Five points are sent back

- **WHEN** a lite change fills five of the eight sections
- **THEN** `nogg validate` refuses it and names the three missing sections

#### Scenario: Placeholders do not count

- **WHEN** a lite change's `## Risks` section still holds only the template's placeholder
- **THEN** the score does not count risks

### Requirement: The planner routes by lane and writes behaviour

When the mode is not `always-full`, the `/plan` prompts for Claude Code, Codex and Pi and the
planning launch prompt SHALL start with triage and route the fast lane to `nogg quick`, the lite lane
to the lite scaffold and the full lane to the full flow, and SHALL tell the planner that task text
describes behaviour and checks, not function names or constants. The prompts SHALL state that the
section is inactive under `always-full`.

#### Scenario: The prompts carry the lane routing

- **WHEN** the installed `/plan` prompts of Claude Code, Codex and Pi are read
- **THEN** each names `nogg triage`, `nogg quick` and the lite scaffold, and says the section
  applies only when the mode is not `always-full`

### Requirement: Validation notes code identifiers in task text

When the mode is not `always-full`, `nogg validate` SHALL print a NOTE, never a refusal, for a task
line whose text outside its `Tests:` and `Check:` fields holds a function call, a `snake_case` or
`CamelCase` name in backticks, or an `UPPER_CASE` constant. Paths, command lines, flags and dotted
lower-case configuration keys SHALL NOT be flagged.

#### Scenario: A function name is noted

- **WHEN** a task line under `adaptive` says "make `parse_config()` reject an empty file"
- **THEN** `nogg validate` prints a NOTE naming the task and `parse_config()` and still exits zero

#### Scenario: Paths and commands are not noted

- **WHEN** a task line names `scripts/lib/ceremony.py`, `nogg quick` and `ceremony.mode`
- **THEN** no code-identifier NOTE is printed for it

### Requirement: The installer writes lean instructions when the switch is on

When the target's mode is not `always-full`, `init` and `update` SHALL write a lean agents block of
under 150 lines, a Claude block that only points to `AGENTS.md`, and the Nogging skills to
`.claude/skills/` and `.agents/skills/`. Under `always-full` they SHALL write today's blocks
byte-identical and no new skill. `doctor` SHALL warn when the installed block does not match the
mode.

#### Scenario: The default install is unchanged

- **WHEN** `init` runs in a repository without a `ceremony` block
- **THEN** the installed agents and Claude blocks equal today's templates and no new skill exists

#### Scenario: The lean install is short

- **WHEN** `init` runs in a repository whose mode is `adaptive`
- **THEN** the installed agents block has fewer than 150 lines and every skill it names exists

#### Scenario: A mode change is noticed

- **WHEN** the mode is switched to `adaptive` and `update` has not run yet
- **THEN** `doctor` warns that the installed block does not match the mode

### Requirement: The lean block keeps every hard rule

The lean agents block SHALL state the `openspec/` write boundary, working only on a claimed Bead,
commits with the Bead token within the configured range, the staged test commands and the
test-integrity rule, discoveries with the label and a prose note, the progress breadcrumb, the
end-of-run signal and `recover` before `bd ready`, and SHALL name each skill's path and when to
read it.

#### Scenario: The hard rules survive the diet

- **WHEN** the lean block is compared with today's block
- **THEN** every hard-rule phrase of today's block is in the lean block or in a skill it names, and
  the write boundary, the Bead token and the test commands are in the lean block itself

### Requirement: Arm D measures the Phase 1 gate

The benchmark SHALL have an arm D equal to arm C apart from its Nogging ref and the switch
`ceremony.mode: adaptive`, which the driver SHALL write into the container's configuration. When
planning ends with a fast-lane Bead instead of a change, the driver SHALL launch the Lead on that
Bead. The result line SHALL record the lane chosen, each fast-lane Bead's production files and
lines, and any `needs-spec` escalation.

#### Scenario: The switch reaches the container

- **WHEN** a run of arm D initialises Nogging in its container
- **THEN** the container's `.nogging/config.json` holds `ceremony.mode: adaptive` before the
  planning session starts

#### Scenario: A fast-lane outcome is driven to the end

- **WHEN** arm D's planning session ends with a `ceremony:fast` Bead and no new change
- **THEN** the driver launches the Lead on that Bead and the result line records the fast lane

#### Scenario: An unnoticed overflow fails the gate

- **WHEN** a fast-lane Bead in arm D changed three production files and carries no `needs-spec`
  label
- **THEN** the gate verdict is not met and names the run
