## ADDED Requirements

### Requirement: The benchmark is a separate package that uses Nogging only from outside

The benchmark SHALL live in `bench/` as its own Python package with its own pytest suite and its
own command line, `nogg-bench` (run from a checkout as `bench/nogg-bench`). The package SHALL NOT
import any module of Nogging; it SHALL reach Nogging only by running Nogging's command line or by
reading files Nogging writes, apart from the single usage helper process of the usage requirement.

#### Scenario: The bench suite runs on its own

- **WHEN** a developer runs the bench pytest suite with the package's dev extra installed
- **THEN** the tests run without a Docker daemon, an agent CLI, Harbor or network access

#### Scenario: The package imports nothing from Nogging

- **WHEN** the bench package is imported in a Python process whose path does not contain
  Nogging's `scripts/` or `scripts/lib/`
- **THEN** every bench module imports without error

### Requirement: The benchmark is not shipped and changes no Nogging production code

`bench/` SHALL NOT be part of the published npm package and SHALL NOT be copied by the installer.
The change SHALL NOT modify Nogging's production code: `scripts/`, `bin/`, `templates/`,
`.claude/`, `.codex/`, `.pi/`, `.agents/`, `.nogging/`, `package.json` or the docs site.

#### Scenario: The published package does not contain the benchmark

- **WHEN** the Nogging npm package is packed
- **THEN** no path under `bench/` is in it

### Requirement: Benchmark tasks have a defined format

Each benchmark task SHALL be a directory `bench/tasks/<id>/` with a `task.yaml` naming the
repository, the full base commit, the issue text file, the issue and fix pull request URLs, the
closing date, language and licence, the size class (`small`, `medium`, `large`), the environment
(base image, setup and test commands, test timeout), the hidden tests (a patch under `hidden/` with
fail-to-pass and pass-to-pass identifiers) and a curation status (`example`, `candidate`,
`accepted`).

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

### Requirement: The validator checks every record kind

`nogg-bench validate` SHALL check task files, arm files, result lines, review records and the
preregistration's blocks, report each problem with the file and the field, and exit non-zero on any
problem. Three example tasks, one per size class, SHALL run against a fixture repository shipped in
`bench/examples/`.

#### Scenario: Every record kind is checked

- **WHEN** `nogg-bench validate` runs with no argument
- **THEN** it checks every task, arm, result line, review record and the preregistration's blocks
  under `bench/`

### Requirement: Arms are declared files with comparable settings

Each arm SHALL be a file `bench/arms/<arm>.yaml` naming its ID, kind, agent CLI and version,
model, effort, timebox, prompt template, disabled tools and credential reference, plus the Nogging
ref for a `nogging` arm. Arms A (Claude Code, plan mode), B (Codex) and C (Nogging v3.6.0) SHALL
exist. Claude-based arms SHALL share model and effort, all arms the timebox, and every Nogging
session in a `nogging` arm SHALL launch with the arm's model and effort.

#### Scenario: Mismatched timeboxes are refused

- **WHEN** `nogg-bench report` is asked to pair two arms whose timeboxes differ
- **THEN** it refuses and names the arms and the field

#### Scenario: Same-vendor arms must match

- **WHEN** two Claude-based arms name different models or efforts
- **THEN** `report` refuses to pair them and names the field

### Requirement: A run isolates the agent

`nogg-bench run --arm <arm> --task <task> --seed <n>` SHALL start a fresh container from the task's
environment, check out the base commit with every later ref and every remote removed, and run the
arm's agent with the issue text as its only brief, its disabled tools and its timebox. A `nogging`
arm SHALL be driven unattended: the issue is the planning brief, planning needs no human approval,
and a full-access Lead executes the planned change.

#### Scenario: The fix is not in the container's history

- **WHEN** the agent lists the repository's refs and remotes inside the container
- **THEN** it finds no commit after the base commit and no remote

#### Scenario: The timebox ends a run

- **WHEN** the agent is still running when its timebox expires
- **THEN** the run stops it, saves the diff and transcripts, runs the hidden tests and records
  `status: timeout`

### Requirement: Hidden tests are applied only after the agent

After the agent has ended, the run SHALL save the diff against the base commit and the agent's
transcripts, and only then copy the hidden tests into the container and run them. The hidden tests
SHALL NOT be mounted into or reachable from the container before that point. A run SHALL pass only
when every fail-to-pass and every pass-to-pass test passes.

#### Scenario: Hidden tests arrive only after the agent

- **WHEN** a run's agent is still running
- **THEN** no hidden test file has been mounted or copied into the container

#### Scenario: The agent changed a hidden test path

- **WHEN** the agent modified a file that the hidden test patch also writes
- **THEN** the hidden version replaces it before the tests run and the result line lists the path

### Requirement: Batches resume

`run` SHALL accept several arms, tasks and seeds and SHALL skip a combination that already has a
result line unless `--rerun` is given.

#### Scenario: A batch resumes

- **WHEN** `run` is started again for arms, tasks and seeds of which some already have result lines
- **THEN** it runs only the missing combinations

### Requirement: Every run leaves one result line

Each run SHALL append exactly one JSON line to `bench/results/<batch>.jsonl`, including failed,
timed-out and infrastructure-failed runs, recording its identity (arm, task, seed, size class,
source, timing), outcome (status, pass, per-test results), size of work (diff statistics, added
Markdown lines, integrated branches), token usage per model, and provenance (arm, prompt and
preregistration hashes, versions, Nogging ref, image digest, bench commit, smoke flag).

#### Scenario: The container does not start

- **WHEN** the task image fails to build or the container fails to start
- **THEN** the run appends a line with `status: infra_error` and the reason, and exits non-zero

### Requirement: A run flags suspected contamination

A run SHALL mark its result line `contamination_suspect` when its transcripts show a web tool call
or the issue or fix pull request URL.

#### Scenario: A web lookup is flagged

- **WHEN** a transcript contains the task's fix pull request URL
- **THEN** the result line has `contamination_suspect: true`

### Requirement: Token usage comes from Nogging's collector for every arm

The run SHALL copy every agent transcript out of the container, for every arm, and SHALL count
tokens with Nogging's own Claude and Codex transcript adapters, run in one bench-owned helper
process that returns per-model input, output, cache-read and cache-write counts. The result line
SHALL record the Nogging commit the helper used. In a `nogging` arm, every planning, Lead and
specialist session SHALL be counted.

#### Scenario: Both vendors are counted the same way

- **WHEN** the helper receives a recorded Claude Code transcript and a recorded Codex transcript
- **THEN** it returns the counts Nogging's adapters produce for them

#### Scenario: The adapters moved

- **WHEN** the helper cannot load Nogging's adapters from the configured checkout
- **THEN** the run records `status: infra_error` naming the helper, rather than a zero token count

### Requirement: Credentials never leave their reference

An arm SHALL name its credentials by reference only (an environment variable name or a credential
directory). The run SHALL pass them into the container through a file or read-only mount with mode
`0600` that it removes after the run. No credential value SHALL appear on a command line, in a
result line, in a log, in a report or in a fixture.

#### Scenario: The docker invocation holds no secret

- **WHEN** a run starts a container for an arm whose API key is in the named environment variable
- **THEN** the recorded docker argv does not contain the key, and the result line and the run log
  do not either

### Requirement: Measured runs follow a committed preregistration

A run without `--smoke` SHALL refuse when `bench/PREREGISTRATION.md` is missing, uncommitted or
changed, or has no valid thresholds block, and when the task's curation status is not `accepted`;
its result line SHALL record the preregistration's blob hash. A `--smoke` run SHALL work on example
and candidate tasks without a preregistration and SHALL be marked `smoke: true`.

#### Scenario: No preregistration, no measurement

- **WHEN** the operator runs a measured run while `bench/PREREGISTRATION.md` has uncommitted changes
- **THEN** the run refuses before starting a container and names the file

#### Scenario: A candidate task is not measured

- **WHEN** a measured run names a task with `curation.status: candidate`
- **THEN** the run refuses and names the task's status

#### Scenario: A smoke run is kept out of the data

- **WHEN** a `--smoke` run completes on an example task
- **THEN** its line carries `smoke: true` and no report table counts it

### Requirement: The preregistration fixes the thresholds and the selection

The thresholds block SHALL name the primary comparisons, the definition of an accepted ticket for
the cost metric, the thresholds, the minimum difference treated as an effect, the significance
level and the reproducibility criterion. The `selection` block SHALL name the method, the seed, the
counts per size class and for the pilot, each arm model's training cutoff with its source, and the
curation criteria. `validate` SHALL check both blocks.

#### Scenario: The selection block is checked

- **WHEN** `PREREGISTRATION.md` has a `selection` block without a `seed`
- **THEN** `validate` refuses it and names the `selection.seed` field

### Requirement: The same arms run on Harbor datasets

A Harbor agent class in the bench package, loaded by import path, SHALL run any arm file inside a
Harbor task environment: it installs the arm's agent (and Nogging at the arm's ref for a `nogging`
arm), runs it with the task instruction and the arm's timebox, captures usage through the same
helper, and writes the same result line with `source: harbor:<dataset>`. Harbor's verifier SHALL
decide pass or fail for Harbor datasets.

#### Scenario: A FeatureBench task runs with arm A

- **WHEN** Harbor runs a FeatureBench task with the adapter and arm A
- **THEN** a result line with `source: harbor:featurebench`, the verifier's verdict and the token
  usage is appended

#### Scenario: The arm file is invalid

- **WHEN** the adapter is given an arm file that `validate` refuses
- **THEN** it fails before installing anything and names the problem

### Requirement: Diffs are reviewed blind

`nogg-bench review-pack` SHALL write one item per completed run of a batch, in random order under a
random label, holding the issue text and the diff with Nogging process artefacts removed
(`openspec/`, `.beads/`, `.nogging/`, `.claude/`, `.codex/`, `.pi/`, `.agents/`, `AGENTS.md`,
`CLAUDE.md`, Bead tokens and Nogging commit trailers), and SHALL write the key from label to run
outside the pack.

#### Scenario: The pack does not reveal the arm

- **WHEN** a pack is built from runs of arms A and C
- **THEN** no item contains an `openspec/` path, a Bead token, a `Nogging-Writer:` line, an arm ID
  or a run ID, and the key file is not inside the pack directory

#### Scenario: A marker survives anonymisation

- **WHEN** a diff still contains a stripped marker after anonymisation
- **THEN** `review-pack` refuses to write the pack and names the run

### Requirement: Review sheets are imported only when valid

The pack SHALL hold a record sheet for the merge decision (`merge`, `merge-after-changes`,
`reject`), defects by severity and review minutes. `review-pack --import` SHALL validate a filled
sheet against the key and append review records.

#### Scenario: A filled sheet is imported

- **WHEN** the reviewer's sheet has a row with an unknown merge decision
- **THEN** `--import` refuses and names the row and the value

### Requirement: The report pairs runs per ticket

`nogg-bench report` SHALL pair runs per ticket across arms, apply McNemar's exact test to
pass/fail and the exact sign test to cost, tabulate per size class and overall, show the spread
between seeds of one arm on one ticket, evaluate each preregistered threshold as met, not met or
tie, and list contamination-suspect and infrastructure-failed runs separately. The report SHALL
state that Nogging arms plan without human approval.

#### Scenario: Discordant pairs decide

- **WHEN** arm A passes 9 tickets that arm C fails and arm C passes 2 tickets that arm A fails
- **THEN** the report's McNemar line uses those 11 discordant pairs and prints the exact p-value

#### Scenario: Mixed preregistrations are refused

- **WHEN** the batches given to `report` carry two different preregistration hashes
- **THEN** the report refuses and names both hashes

### Requirement: The report prices tokens and exports every run

The report SHALL convert tokens to cost with list prices from `bench/prices.yaml` and SHALL report
a model without a price as unknown cost, never as zero. It SHALL export every run, failed and smoke
runs flagged, to `runs.csv`, and SHALL write the bench commit, arm files, prompts, the `AGENTS.md`
of each Nogging ref, model IDs, effort levels and agent versions to `metadata.json`.

#### Scenario: A missing price stays visible

- **WHEN** a run used a model that `bench/prices.yaml` does not list
- **THEN** that run's cost is shown as unknown and the cost comparison names the model

#### Scenario: Failed runs are exported

- **WHEN** a batch contains a timeout and an infrastructure failure
- **THEN** both appear in `runs.csv` with their status

### Requirement: Candidates are collected by fixed criteria

`nogg-bench candidates` SHALL collect repositories and issues only by the criteria of the
preregistration's `selection` block, SHALL derive each candidate's size class from its fix pull
request's non-test changes, SHALL write every candidate as a `curation.status: candidate` task, and
SHALL record every repository it skipped with the reason.

#### Scenario: A bot's pull request is not a candidate

- **WHEN** an issue's only linked merged pull request was opened by a bot account
- **THEN** `candidates` writes no task for it

#### Scenario: The size class follows the fix

- **WHEN** a fix pull request changes 4 non-test files with 120 changed lines
- **THEN** the candidate's `size_class` is `medium`

### Requirement: Hidden tests are verified automatically

`nogg-bench verify` SHALL run each candidate's suite with the hidden test patch at the base commit
and at the original fix, twice each, derive fail-to-pass and pass-to-pass from the outcomes, and
record itself, the bench commit and the date as the verification. It SHALL drop a candidate whose
fail-to-pass set is empty, whose two runs disagree, whose setup fails or whose suite exceeds the
timeout, naming the reason. It SHALL NOT set `curation.status: accepted`.

#### Scenario: Verification fills in the tests

- **WHEN** a hidden test fails at the base commit and passes on the fix, and another passes on both
- **THEN** `verify` lists the first under `fail_to_pass`, the second under `pass_to_pass`, and
  records `hidden_tests_verified_by` and `verified_on`

#### Scenario: A flaky test drops the candidate

- **WHEN** the two runs of the suite on the original fix disagree on one test
- **THEN** `verify` drops the candidate and names the test

### Requirement: A seeded draw selects the tickets

`nogg-bench select` SHALL rank repositories and verified candidates by the SHA-256 of
`"<seed>:<key>"`, take repositories per language and tickets per size class in rank order (those
closed after the arm models' latest training cutoff first), mark the first 10 tickets per class
`accepted` and the first 4 of those `pilot: true`, and write the ranked lists with the seed, the
preregistration hash and the pool hash to `bench/curation/selection.json`.

#### Scenario: The draw is reproducible

- **WHEN** `select` runs twice on the same committed pool and preregistration
- **THEN** both runs write the same `selection.json` and the same task statuses

### Requirement: The draw cannot be steered

`select` SHALL refuse when a size class has fewer than 10 verified candidates, and when the commit
that introduced the preregistration's selection block is not an ancestor of the commit that first
added the candidate pool. `validate` SHALL refuse an `accepted` task that `selection.json` does not
list as drawn.

#### Scenario: The seed was fixed before the pool

- **WHEN** the preregistration's selection block was committed after the candidate pool was first
  committed
- **THEN** `select` refuses and names both commits

#### Scenario: A short size class stops the draw

- **WHEN** only 8 verified candidates are `large`
- **THEN** `select` refuses, names the `large` class and its count, and changes no task

#### Scenario: Nobody accepts a ticket by hand

- **WHEN** a commit sets `curation.status: accepted` on a task that `selection.json` does not list
  as drawn
- **THEN** `validate` refuses the task and names it

### Requirement: The report names the mechanical selection

When the preregistration's selection method is `seeded-draw`, `report.md` SHALL state that the
tickets were drawn mechanically, deviating from the roadmap's rule that the Product Owner curates
them by hand.

#### Scenario: The report names the deviation

- **WHEN** `report` runs with a preregistration whose selection method is `seeded-draw`
- **THEN** `report.md` states that the tickets were drawn mechanically instead of curated by hand

### Requirement: Arm C finishes unattended in the run container

For a `nogging` arm the run SHALL provide, inside the container, a local forge stand-in on `PATH`
for the pull-request calls the Nogging Lead makes, which records each pull request in the run
directory, reports checks as passed and makes no network call. Every arm's container SHALL get the
same container options, enough for Nogging's user and mount namespaces and without `--privileged`,
recorded in the result's provenance.

#### Scenario: The Lead's pull request is recorded

- **WHEN** the Nogging Lead in a `nogging` arm runs `gh pr create` inside the container
- **THEN** the call succeeds without network access and the run directory holds the recorded pull
  request

#### Scenario: Every arm gets the same container

- **WHEN** runs of arms A and C start their containers
- **THEN** both docker invocations carry the same security options and neither carries
  `--privileged`

### Requirement: Only the blinded review stays with the Product Owner

The blinded review of the pilot runs SHALL be the Product Owner's only benchmark task, apart from
adding the bench CI workflow, which needs a credential no agent holds. Both SHALL be marked
`po-only`; no Lead or specialist SHALL claim them, and the Orchestration Agent SHALL NOT launch a
Lead for them. No agent SHALL fill in a review sheet or edit the preregistration after the first
measured run.

#### Scenario: A Lead looks for work

- **WHEN** a Lead lists ready work with `bd ready --exclude-label po-only`
- **THEN** the review task and the workflow task are not listed, and the curation and run tasks
  are once their dependencies are closed
