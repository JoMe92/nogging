## ADDED Requirements

### Requirement: The benchmark is a separate package that uses Nogging only from outside

The benchmark SHALL live in `bench/` as its own Python package with its own pytest suite and its
own command line, `nogg-bench` (run from a checkout as `bench/nogg-bench`). The package SHALL NOT
import any module of Nogging; it SHALL reach Nogging only by running Nogging's command line or by
reading files Nogging writes, apart from the single usage helper process of the usage requirement.
`bench/` SHALL NOT be part of the published npm package and SHALL NOT be copied by the installer.
The change SHALL NOT modify Nogging's production code: `scripts/`, `bin/`, `templates/`,
`.claude/`, `.codex/`, `.pi/`, `.agents/`, `.nogging/`, `package.json` or the docs site.

#### Scenario: The bench suite runs on its own

- **WHEN** a developer runs the bench pytest suite with the package's dev extra installed
- **THEN** the tests run without a Docker daemon, an agent CLI, Harbor or network access

#### Scenario: The package imports nothing from Nogging

- **WHEN** the bench package is imported in a Python process whose path does not contain
  Nogging's `scripts/` or `scripts/lib/`
- **THEN** every bench module imports without error

#### Scenario: The published package does not contain the benchmark

- **WHEN** the Nogging npm package is packed
- **THEN** no path under `bench/` is in it

### Requirement: Benchmark tasks have a validated format

Each benchmark task SHALL be a directory `bench/tasks/<id>/` with a `task.yaml` that names the
repository, the full base commit, the issue text file, the issue and fix pull request URLs, the
issue's closing date, the language and licence, the size class (`small`, `medium` or `large`), the
environment (base image, setup commands, test command and test timeout), the hidden tests (a patch
under `hidden/` plus fail-to-pass and pass-to-pass test identifiers) and a curation status
(`example`, `candidate` or `accepted`). `nogg-bench validate` SHALL check task files, arm files,
result lines, review records and the preregistration thresholds block, report each problem with
the file and the field, and exit non-zero on any problem. Three example tasks, one per size class,
SHALL run against a fixture repository shipped in `bench/examples/`.

#### Scenario: A valid task passes

- **WHEN** the operator runs `nogg-bench validate bench/tasks/<id>` on a complete task
- **THEN** the command exits zero and prints no problem

#### Scenario: A missing field is named

- **WHEN** a `task.yaml` has no `base_commit`
- **THEN** `validate` exits non-zero and names the file and the `base_commit` field

#### Scenario: An accepted task needs a recorded check

- **WHEN** a task has `curation.status: accepted` but no `hidden_tests_verified_by` or no
  `verified_on`
- **THEN** `validate` refuses it and names the missing field

#### Scenario: A test cannot be both kinds

- **WHEN** one test identifier appears in both `fail_to_pass` and `pass_to_pass`
- **THEN** `validate` refuses the task and names the identifier

#### Scenario: Every record kind is checked

- **WHEN** `nogg-bench validate` runs with no argument
- **THEN** it checks every task, arm, result line, review record and the thresholds block under
  `bench/`

### Requirement: Arms are declared files with comparable settings

Each arm SHALL be a file `bench/arms/<arm>.yaml` naming its ID, kind (`claude-code`, `codex` or
`nogging`), agent CLI and version, model, effort, timebox, prompt template, disabled tools and
credential reference; a `nogging` arm SHALL also name its Nogging ref. Arms A (Claude Code with plan
mode, no Nogging), B (Codex, no Nogging) and C (Nogging v3.6.0 unchanged) SHALL exist. Every
Claude-based arm SHALL use the same model and effort, and every arm the same timebox. Inside a
`nogging` arm every Nogging session SHALL launch with the arm's model and effort.

#### Scenario: Mismatched timeboxes are refused

- **WHEN** `nogg-bench report` is asked to pair two arms whose timeboxes differ
- **THEN** it refuses and names the arms and the field

#### Scenario: Same-vendor arms must match

- **WHEN** two Claude-based arms name different models or efforts
- **THEN** `report` refuses to pair them and names the field

### Requirement: A run isolates the agent and applies hidden tests only afterwards

`nogg-bench run --arm <arm> --task <task> --seed <n>` SHALL start a fresh container from the task's
environment, check out the base commit with every later ref and every remote removed, and run the
arm's agent with the issue text as its only brief, its disabled tools, and its timebox. A `nogging`
arm SHALL be driven unattended: the issue text is the planning brief, planning proceeds without
human approval, and a full-access Lead executes the planned change. After the agent has ended, the
run SHALL save the diff against the base commit and the agent's transcripts, and only then copy the
hidden tests into the container and run them. The hidden tests SHALL NOT be mounted into or
reachable from the container before that point. A run SHALL pass only when every fail-to-pass and
every pass-to-pass test passes. `run` SHALL accept several arms, tasks and seeds and SHALL skip a
combination that already has a result line unless `--rerun` is given.

#### Scenario: Hidden tests arrive only after the agent

- **WHEN** a run's agent is still running
- **THEN** no hidden test file has been mounted or copied into the container

#### Scenario: The agent changed a hidden test path

- **WHEN** the agent modified a file that the hidden test patch also writes
- **THEN** the hidden version replaces it before the tests run and the result line lists the path

#### Scenario: The timebox ends a run

- **WHEN** the agent is still running when its timebox expires
- **THEN** the run stops it, saves the diff and transcripts, runs the hidden tests and records
  `status: timeout`

#### Scenario: The fix is not in the container's history

- **WHEN** the agent lists the repository's refs and remotes inside the container
- **THEN** it finds no commit after the base commit and no remote

#### Scenario: A batch resumes

- **WHEN** `run` is started again for arms, tasks and seeds of which some already have result lines
- **THEN** it runs only the missing combinations

### Requirement: Every run leaves one result line

Each run SHALL append exactly one JSON line to `bench/results/<batch>.jsonl`, including failed,
timed-out and infrastructure-failed runs. The line SHALL record the run's identity (arm, task, seed,
size class, source, start, end, wall-clock seconds), its outcome (status, passed, per-test results,
overwritten hidden paths, contamination suspicion), the size of its work (diff statistics, added
Markdown lines, number of integrated implementation branches), its token usage per model, and its
provenance (arm file and prompt hashes, agent version, Nogging ref, image digest, bench commit,
preregistration hash, smoke flag). A run SHALL suspect contamination when its transcripts show a
web tool call or the issue or fix pull request URL.

#### Scenario: The container does not start

- **WHEN** the task image fails to build or the container fails to start
- **THEN** the run appends a line with `status: infra_error` and the reason, and exits non-zero

#### Scenario: A web lookup is flagged

- **WHEN** a transcript contains the task's fix pull request URL
- **THEN** the result line has `contamination_suspect: true`

### Requirement: Token usage comes from Nogging's collector for every arm

The run SHALL copy every agent transcript out of the container, for every arm, and SHALL count tokens
with Nogging's own Claude and Codex transcript adapters, run in one bench-owned helper process that
receives the transcripts and returns per-model input, output, cache-read and cache-write counts. The
result line SHALL record the Nogging commit the helper used. In a `nogging` arm, the transcripts of
every planning, Lead and specialist session SHALL be counted.

#### Scenario: Both vendors are counted the same way

- **WHEN** the helper receives a recorded Claude Code transcript and a recorded Codex transcript
- **THEN** it returns the counts Nogging's adapters produce for them

#### Scenario: The adapters moved

- **WHEN** the helper cannot load Nogging's adapters from the configured checkout
- **THEN** the run records `status: infra_error` naming the helper, rather than a zero token count

### Requirement: Credentials never leave their reference

An arm SHALL name its credentials by reference only (an environment variable name or a credential
directory). The run SHALL pass them into the container through a file or read-only mount with mode
`0600` that it removes after the run. No credential value SHALL appear on a command line, in a result
line, in a log, in a report or in a fixture.

#### Scenario: The docker invocation holds no secret

- **WHEN** a run starts a container for an arm whose API key is in the named environment variable
- **THEN** the recorded docker argv does not contain the key, and the result line and the run log do
  not either

### Requirement: Measured runs follow a committed preregistration

A run without `--smoke` SHALL refuse when `bench/PREREGISTRATION.md` is missing, has uncommitted
changes or has no valid thresholds block, and when the task's curation status is not `accepted`. The
result line SHALL record the preregistration's blob hash. A `--smoke` run SHALL work on example and
candidate tasks without a preregistration and SHALL be marked `smoke: true`. The thresholds block
SHALL name the primary comparisons, the definition of an accepted ticket for the cost metric, the
thresholds, the minimum difference treated as an effect, the significance level and the
reproducibility criterion.

#### Scenario: No preregistration, no measurement

- **WHEN** the operator runs a measured run while `bench/PREREGISTRATION.md` has uncommitted changes
- **THEN** the run refuses before starting a container and names the file

#### Scenario: A candidate task is not measured

- **WHEN** a measured run names a task with `curation.status: candidate`
- **THEN** the run refuses and names the task's status

#### Scenario: A smoke run is kept out of the data

- **WHEN** a `--smoke` run completes on an example task
- **THEN** its line carries `smoke: true` and no report table counts it

### Requirement: The same arms run on Harbor datasets

A Harbor agent class in the bench package, loaded by import path, SHALL run any arm file inside a
Harbor task environment: it installs the arm's agent (and Nogging at the arm's ref for a `nogging`
arm), runs it with the task instruction as the brief and the arm's timebox, captures usage through
the same helper, and writes the same result line with `source: harbor:<dataset>`. Harbor's verifier
SHALL decide pass or fail for Harbor datasets.

#### Scenario: A FeatureBench task runs with arm A

- **WHEN** Harbor runs a FeatureBench task with the adapter and arm A
- **THEN** a result line with `source: harbor:featurebench`, the verifier's verdict and the token
  usage is appended

#### Scenario: The arm file is invalid

- **WHEN** the adapter is given an arm file that `validate` refuses
- **THEN** it fails before installing anything and names the problem

### Requirement: Diffs are reviewed blind

`nogg-bench review-pack` SHALL write, for the completed runs of a batch, one item per run in random
order under a random label, holding the issue text and the diff with Nogging process artefacts
removed (`openspec/`, `.beads/`, `.nogging/`, `.claude/`, `.codex/`, `.pi/`, `.agents/`,
`AGENTS.md`, `CLAUDE.md`, Bead tokens and Nogging commit trailers), plus a record sheet for the
merge decision (`merge`, `merge-after-changes`, `reject`), defects by severity and review minutes.
The key from label to run SHALL be written outside the pack. `--import` SHALL validate a filled
sheet and append review records.

#### Scenario: The pack does not reveal the arm

- **WHEN** a pack is built from runs of arms A and C
- **THEN** no item contains an `openspec/` path, a Bead token, a `Nogging-Writer:` line, an arm ID
  or a run ID, and the key file is not inside the pack directory

#### Scenario: A marker survives anonymisation

- **WHEN** a diff still contains a stripped marker after anonymisation
- **THEN** `review-pack` refuses to write the pack and names the run

#### Scenario: A filled sheet is imported

- **WHEN** the reviewer's sheet has a row with an unknown merge decision
- **THEN** `--import` refuses and names the row and the value

### Requirement: The report pairs runs per ticket

`nogg-bench report` SHALL pair runs per ticket across arms, apply McNemar's exact test to
pass/fail and the exact sign test to cost, tabulate per size class and overall, show the spread
between seeds of one arm on one ticket, evaluate each preregistered threshold as met, not met or
tie, list contamination-suspect and infrastructure-failed runs separately, and convert tokens to
cost with list prices from `bench/prices.yaml`. It SHALL export every run, failed and smoke runs
flagged, to `runs.csv`, and SHALL write the bench commit, arm files, prompts, the `AGENTS.md` of each
Nogging ref, model IDs, effort levels and agent versions to `metadata.json`. A model without a price
SHALL be reported as unknown cost, never as zero. The report SHALL state that Nogging arms plan
without human approval.

#### Scenario: Discordant pairs decide

- **WHEN** arm A passes 9 tickets that arm C fails and arm C passes 2 tickets that arm A fails
- **THEN** the report's McNemar line uses those 11 discordant pairs and prints the exact p-value

#### Scenario: A missing price stays visible

- **WHEN** a run used a model that `bench/prices.yaml` does not list
- **THEN** that run's cost is shown as unknown and the cost comparison names the model

#### Scenario: Failed runs are exported

- **WHEN** a batch contains a timeout and an infrastructure failure
- **THEN** both appear in `runs.csv` with their status

#### Scenario: Mixed preregistrations are refused

- **WHEN** the batches given to `report` carry two different preregistration hashes
- **THEN** the report refuses and names both hashes

### Requirement: Curation and measured runs stay with the Product Owner

Choosing the benchmark tickets, checking their hidden tests, writing `bench/PREREGISTRATION.md`,
and starting the pilot and the full run SHALL be the Product Owner's work. Those tasks SHALL be
marked `po-only`; a Lead or specialist SHALL NOT claim them, and the Orchestration Agent SHALL NOT
launch a Lead for them. An agent MAY propose candidate tickets, written with
`curation.status: candidate`; only the Product Owner SHALL set `accepted`.

#### Scenario: A Lead looks for work

- **WHEN** a Lead lists ready work with `bd ready --exclude-label po-only`
- **THEN** BEN-006 and BEN-007 are not listed

#### Scenario: An agent proposes tickets

- **WHEN** an agent is asked to suggest benchmark tickets
- **THEN** it writes them as `candidate` tasks and the Product Owner decides which become
  `accepted`
