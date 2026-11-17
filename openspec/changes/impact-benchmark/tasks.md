## 1. Contracts first

- [x] TASK-BEN-001 [standard] [~550 loc] The benchmark package exists, and `nogg-bench validate` checks tasks, arms, results, reviews and thresholds against three example tasks.
  Per design Decisions 1 to 5 and 17 and the requirements on the separate package and the task format. Create the `bench/` package as Decision 3 lays it out (pyproject with the dev and harbor extras, the `bench/nogg-bench` wrapper, `bench/README.md` with the data layout and how to run the suite). Define and validate every shared record of Decision 4 (task, arm, result line, review record, thresholds block), each with `schema: 1`, and ship one valid and one invalid fixture of each kind under `bench/tests/fixtures/` for the later tasks. `validate` takes paths or validates all of `bench/`, names the file and field of each problem and exits non-zero on any. Build a small fixture repository as a git bundle under `bench/examples/` and three example tasks against it, one per size class, with real hidden tests and `curation.status: example`. Add `.github/workflows/bench.yml` (path filter `bench/**`, Python 3.11 and 3.13, actions pinned by SHA). Touch nothing outside Decision 1's list.
  Tests: small, one per rule: "A valid task passes", "A missing field is named", "An accepted task needs a recorded check", "A test cannot be both kinds", an invalid arm, result line, review record and thresholds block each named by field; medium (temporary directory): "Every record kind is checked" over a copied `bench/` tree, the three example tasks validate, their hidden tests fail on the base commit and pass on the fix commit inside the unpacked bundle; small "The package imports nothing from Nogging" (import every module with a clean path); medium "The published package does not contain the benchmark" (`npm pack --dry-run` lists no `bench/` path).
  Check: uv run --project bench --extra dev pytest bench/tests/test_validate.py bench/tests/test_examples.py bench/tests/test_isolation.py. Branch test/.

## 2. Runs (parallel after BEN-001)

- [ ] TASK-BEN-002 [complex] [security] [~850 loc: one slice from container start to result line; the arm C driver is the larger half and has no seam worth a separate Bead] `nogg-bench run --arm --task --seed` runs arm A, B or C on a task in a container and appends one result line.
  Per design Decisions 6 to 11 and the requirements on arms, isolation, result lines, usage, credentials and preregistration. Write the arm files for A, B and C and their prompt templates (same Claude model and effort for A and C, the matching Codex tier for B, one timebox; start from the current `complex` entries of `scripts/nogg models` for Claude and Codex, which the Product Owner confirms or changes before the pilot in BEN-007). Implement the run of Decision 7: fresh container from the task environment, base commit with later refs and remotes removed, the arm's agent with the issue as its only brief and web tools disabled, the unattended driver for a `nogging` arm (planning kickoff from the issue, no approval, full-access Lead, wait for its done signal or the timebox, every session launched with the arm's model and effort), diff and transcripts saved, hidden tests copied in only afterwards, pass rule, contamination scan. Implement the usage helper of Decision 10 and its recorded Nogging commit, credential passing of Decision 8 with redaction, the result line of Decision 9 (including `infra_error`), the preregistration and curation gate of Decision 11 with `--smoke`, and batch resumption (several arms, tasks and seeds; skip recorded combinations unless `--rerun`). Document `run` in `bench/README.md`.
  Tests: small "Mismatched timeboxes are refused" and "Same-vendor arms must match" at arm-load level, the pass rule, the contamination scan ("A web lookup is flagged"), result-line assembly for every status; medium (stub `docker` on PATH recording argv, stub agent CLIs writing transcript fixtures and diffs, injected clock, temporary repository): "Hidden tests arrive only after the agent" (no hidden path in any docker call before the agent's exit), "The agent changed a hidden test path", "The timebox ends a run", "The fix is not in the container's history", "A batch resumes", "The container does not start", "The docker invocation holds no secret", "No preregistration, no measurement", "A candidate task is not measured", "A smoke run is kept out of the data", the arm C driver against a stub `nogg` that plans, leads and signals done; medium usage helper "Both vendors are counted the same way" (recorded Claude and Codex transcript fixtures through the host checkout's adapters) and "The adapters moved"; large (only with `NOGG_BENCH_DOCKER=1`, not in CI) one smoke run of arm A's stub agent on an example task in a real container.
  Check: uv run --project bench --extra dev pytest bench/tests/test_arms.py bench/tests/test_run.py bench/tests/test_usage.py bench/tests/test_driver.py. Branch feat/.

- [ ] TASK-BEN-004 [standard] [~300 loc: below the range on purpose; the blinding is kept in its own small module so a review of it is a review of the whole anonymisation] `nogg-bench review-pack` writes a blinded review pack and imports the filled record sheet.
  Per design Decision 13 (review pack) and the requirement on blind review. Build items from the completed runs of a batch, using the BEN-001 result-line fixtures until BEN-002 lands: random labels, shuffled order, issue text plus the anonymised diff with the listed process artefacts and markers removed, refusal when a marker survives, a record sheet (merge decision, defects by severity, review minutes, comment), and the key written outside the pack. `--import` validates a filled sheet against the key and appends review records in the BEN-001 schema. Document the review procedure for the reviewer in `bench/README.md`, including that the reviewer times each item with a stopwatch and records minutes.
  Tests: small anonymisation per artefact kind, "A marker survives anonymisation", label randomness independent of arm order (fixed random source); medium (temporary results directory with fixture lines of arms A and C): "The pack does not reveal the arm", key outside the pack, "A filled sheet is imported" with an unknown decision refused, a valid sheet appended as review records that `validate` accepts.
  Check: uv run --project bench --extra dev pytest bench/tests/test_review_pack.py. Branch refactor/.

- [ ] TASK-BEN-005 [standard] [~450 loc] `nogg-bench report` pairs runs per ticket, checks the preregistered thresholds and exports every run.
  Per design Decisions 6, 11 and 13 (report) and the requirement on the paired report. Pair runs per ticket across arms (majority pass and median cost across seeds, with the spread shown), McNemar's exact test on discordant pairs, the exact sign test on cost with ties dropped, tables per size class and overall, threshold evaluation as met, not met or tie, separate lists for contamination-suspect and infrastructure-failed runs, refusal on mixed preregistration hashes and on mismatched arm settings, the deviation note for Nogging arms. Add `bench/prices.yaml` with list prices for the models the arm files name, each with its source URL and date; an unlisted model is unknown cost. Write `report.md`, `runs.csv` and `metadata.json` under `bench/reports/<name>/`. Use the BEN-001 fixtures until BEN-002 and BEN-004 land; implement the exact tests in the package, without a statistics dependency.
  Tests: small "Discordant pairs decide" (exact p-value against a hand-computed binomial), sign test with ties, majority and median across seeds, cost per accepted ticket under both definitions the thresholds block allows, "A missing price stays visible", threshold verdicts at the tie boundary; medium (temporary directory with fixture result lines and review records): "Failed runs are exported", "Mixed preregistrations are refused", "Mismatched timeboxes are refused" at report level, a full report from fixtures whose `metadata.json` lists every arm file and prompt hash.
  Check: uv run --project bench --extra dev pytest bench/tests/test_stats.py bench/tests/test_report.py. Branch perf/.

## 3. External tasks (after BEN-002)

- [ ] TASK-BEN-003 [complex] [~400 loc] The same arms run Harbor datasets such as FeatureBench through a Harbor agent loaded by import path.
  Per design Decision 12 and the requirement on Harbor datasets. First check the installed Harbor's custom-agent interface against its documentation and pin the version in the harbor extra; record a mismatch with Decision 12 as a discovery before writing code against it. Implement the agent class: load and validate an arm file, install the arm's agent (and Nogging at the arm's ref for a `nogging` arm) into Harbor's environment, run it with the task instruction and the arm's timebox, copy the transcripts out through BEN-002's usage helper, map Harbor's verifier verdict onto the result line, and append it with `source: harbor:<dataset>`. Document in `bench/README.md` the exact `harbor run` invocation with the import path, and how to choose a FeatureBench subset.
  Tests: medium (fake Harbor environment object recording exec and upload calls, stub agent CLI, transcript fixtures): "A FeatureBench task runs with arm A" yields a valid result line with the verdict and usage, "The arm file is invalid" fails before any install call, a `nogging` arm installs Nogging at its ref, a timeout maps to `status: timeout`; large (only with `NOGG_BENCH_HARBOR=1`, not in CI) one real Harbor run of a single task with arm A's stub agent.
  Check: uv run --project bench --extra dev pytest bench/tests/test_harbor.py. Branch test/.

## 4. Product Owner work (no Lead claims these)

- [ ] TASK-BEN-006 [po-only] [~0 loc: Product Owner hand work, no production code] The Product Owner curates 30 benchmark tickets and preregisters the thresholds in bench/PREREGISTRATION.md.
  Per design Decisions 5, 11 and 14 and the requirement on Product Owner curation. Needs answers to open questions 1 (which three repositories) and 3 (who reviews blind). From three foreign repositories (two Python, one TypeScript, good test suites), pick 30 closed issues with a merged human pull request, preferably closed after the models' training cutoff, 10 per size class. For each, write `bench/tasks/<id>/` in the BEN-001 format, check by hand that the fail-to-pass tests fail at the base commit and that all hidden tests pass on the original fix, and set `curation.status: accepted` with `hidden_tests_verified_by` and `verified_on`. Mark the 12 pilot tickets (4 per size class). Write `bench/PREREGISTRATION.md` with its thresholds block (primary comparisons, the definition of an accepted ticket, the thresholds the roadmap proposes or the Product Owner's own, the minimum effect, the significance level, the reproducibility criterion) and commit it before any measured run. An agent may propose candidate tickets as `curation.status: candidate` on request; the selection and the hidden-test check stay with the Product Owner.
  Tests: none (Product Owner curation; `nogg-bench validate` is the mechanical check).
  Check: bench/nogg-bench validate bench/tasks bench/PREREGISTRATION.md. Branch docs/.

- [ ] TASK-BEN-007 [po-only] [~0 loc: benchmark runs and the committed baseline report, no production code] The pilot (12 tickets, arms A, B and C) runs unattended, then the full run, and the baseline report for A, B and C is in the repository.
  Per design Decisions 7, 9, 11, 13 and 14 and the proposal's acceptance. Needs answers to open questions 2 (subscription or API) and 4 (Docker host), and the blind reviewer of open question 3. The Product Owner, or the Orchestration Agent on an explicit `/orchestrate takeover code` instruction for this Bead, starts the batches; no Lead. First, the Product Owner confirms or changes the model, effort and timebox in the arm files of BEN-002 and commits them. Pilot: 12 tickets times arms A, B and C, seed 1, with no manual intervention during the batch. Then a second seed of at least one arm on the pilot tickets to check the preregistered reproducibility criterion; the full run starts only when it holds. Full run: 30 tickets, arms A, B and C, 3 seeds. One real Harbor run of arm A on a few FeatureBench tasks proves the adapter. Blind review of every completed run through `review-pack`, then `report`. Commit `bench/results/`, the review records and `bench/reports/baseline/` (report, CSV, metadata). Acceptance: the pilot ran without manual intervention; two runs of one arm on one ticket are comparable by the preregistered criterion; the baseline report for A, B and C is committed. The feature freeze in AGENTS.md ends only when the Product Owner lifts it in a planning session.
  Tests: large (the real pilot and full run on the Docker host; the automated scenarios are in BEN-001 to BEN-005).
  Check: bench/nogg-bench validate bench/results; baseline report committed under bench/reports/baseline/. Branch chore/impact-benchmark-runs.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A depends on B):
002<-001; 004<-001; 005<-001; 006<-001; 003<-002; 007<-002; 007<-003; 007<-004; 007<-005; 007<-006.

- 002, 004 and 005 build on the contracts and fixtures of 001 and run in parallel.
- 006 curates in the 001 format with `nogg-bench validate`, in parallel with 002, 004 and 005.
- 003 reuses the agent launch and the usage helper of 002.
- 007 needs every tool and the curated tasks with their preregistration.

Branches are `<type>/impact-benchmark`, one prefix per task so parallel worktrees never share a
branch: test/ 001, feat/ 002, refactor/ 004, perf/ 005, test/ 003 (001 is integrated and its branch
gone before 003 starts), docs/ 006, chore/impact-benchmark-runs 007. The type is only a namespace
here. Before allocating a dependent worktree, verify that every prerequisite execution commit is
integrated into develop. A closed Bead alone is not enough.

## Execution contract

**Scope.** A task's first line is its Bead title. Its full slice is that line plus the indented
paragraph under it, the design Decisions it names, and the matching requirements in specs/.

**Boundary.** Write only `bench/` and `.github/workflows/bench.yml` (design Decision 1). The bench
package imports nothing from Nogging and reaches it only through its command line, apart from the
one usage helper of Decision 10. A task that would need any other file records a blocking discovery
instead of editing it.

**Product Owner tasks.** BEN-006 and BEN-007 are labelled `po-only` and assigned to
`product-owner`. No Lead or specialist claims them, and the Orchestration Agent launches no Lead for
them. Leads list their work with `bd ready --exclude-label po-only`. An agent may help on the
Product Owner's request (candidate tickets as `candidate`, a draft preregistration) and never sets
`accepted`, never edits the thresholds on its own and never starts a measured run.

**Work.** The Main Worker claims each task and implements it only in its own allocated worktree, in
several commits within the configured commit range. Write the tier classification to the Bead note
on every launch.

**Security review.** BEN-002 is marked [security]: it moves credentials into containers. It gets a
code-reviewer pass before each commit and a reviewed pull request. On a Codex or Pi Lead, the
Orchestration Agent's PR review is that review.

**Testing.** Small and medium tests are offline: no Docker daemon, no Harbor, no agent CLI, no
network, no `bd` and no Dolt; `docker` and the agents are stubs on PATH, Harbor's environment is a
fake object, clocks are injected and nothing sleeps. A large test runs only behind its explicit
environment variable. Test in stages: the changed test files while working, those plus lint before
each commit, and the files the task's `Check:` names once per Bead. The full CI matrix is CI's job.
Run a long command as one blocking call (`./scripts/nogg run-quiet -- <command>`), and never poll
it.

**Closing.** Push the branch and open the pull request against develop. Only then run bd close and
`scripts/nogg task-done`, and append every SHA and the evidence to the Bead. A Codex Lead needs
--full-access or --profile trusted to reach the shared Dolt server.

**Limits.**
- Agents never hand-edit OpenSpec.
- Discoveries carry the discovery label and prose.
- Prompts, fixtures, transcripts and docs contain no email address, no real token and no
  credential; transcript fixtures are synthetic or scrubbed.
- The feature freeze in AGENTS.md holds for every task: no new features in dispatch, loops, session
  wake or Antigravity.
- Nobody signs human acceptance.
