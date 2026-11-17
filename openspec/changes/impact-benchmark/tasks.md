## 1. Contracts first

- [ ] TASK-BEN-001 [standard] [~550 loc] The benchmark package exists, and `nogg-bench validate` checks tasks, arms, results, reviews and thresholds against three example tasks.
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

## 4. Preregistration, curation and runs (revised 2026-11-17; see design Decision 22)

- [ ] TASK-BEN-006 [standard] [~250 loc: below the range on purpose; mostly the preregistration text, and it must land alone and early because its commit fixes the seed before any candidate exists] `bench/PREREGISTRATION.md` fixes the thresholds, the selection rule and its seed, and is committed before any candidate is collected.
  Per design Decisions 11, 18, 19, 21 and 22 and the requirements on preregistration and the seeded draw. Since the 2026-11-17 revision an agent task, no longer `po-only`. Write `bench/PREREGISTRATION.md`: prose on what is measured and on the three deviations from real use and from the roadmap (Nogging arms plan without human approval; tickets are drawn mechanically instead of curated by hand; the review covers the pilot only); the thresholds block with Decision 22 item 2 (the roadmap's thresholds for D against A, the Phase 0 comparisons C against A and C against B, an accepted ticket is one whose hidden tests pass, minimum effect 15 percentage points, significance level 0.05, the reproducibility criterion, and the Phase 1 gate of the `adaptive-ceremony` change as its own comparison: on the 10 small tickets arm D with `ceremony.mode: adaptive` uses fewer tokens per run than arm C by the exact sign test at the significance level, and passes the hidden tests not less often than C; for that, add a tokens-per-run threshold metric to the schema and to `report`'s threshold evaluation); and the new `selection` block of Decision 19 (method `seeded-draw`, one integer seed stated with how it was chosen, 10 per size class and 4 of them for the pilot, the training-cutoff date of every arm model with its source URL, and every criterion of Decision 18 with its number), plus `bench/curation/exclude.yaml`, the exclusion list with a source URL per list. Extend the schema and `validate` with the selection block, and make `report` state the mechanical selection in `report.md` when the method is `seeded-draw`. Commit the preregistration in its own commit; nobody edits it after the first measured run. Document both blocks in `bench/README.md`.
  Tests: small the tokens-per-run metric evaluated as met, not met and tie from fixture result lines; small "The selection block is checked" (missing seed, unknown method, a count that is not a positive integer, a cutoff without a source), a valid selection block passes; small "The report names the deviation" (report text from a fixture preregistration with `seeded-draw`); medium: the committed `bench/PREREGISTRATION.md` and `bench/curation/exclude.yaml` validate.
  Check: uv run --project bench --extra dev pytest bench/tests/test_validate.py bench/tests/test_report.py; bench/nogg-bench validate bench/PREREGISTRATION.md. Branch docs/impact-benchmark.

- [ ] TASK-BEN-008 [complex] [~850 loc] `nogg-bench candidates`, `verify` and `select` collect, check and draw benchmark tickets mechanically.
  Per design Decisions 5, 18 and 19 and the requirements on mechanical collection and the seeded draw. Implement `candidates repos` (GitHub search through the `gh` command line, read-only; pool snapshot with query and time; every criterion of the preregistration's selection block; skipped repositories with their reason in a pool log), `candidates issues` (closed as completed, exactly one linked merged pull request by a non-bot author touching test and non-test files, fix URL and diffs absent from the issue text, size class from the non-test changes, hidden patch from the test-file changes, base from the pull request's base; written as `candidate` tasks in the BEN-001 format with an environment recipe per repository), `verify` (in the task container through the BEN-002 docker layer: the suite with the hidden patch at the base and at the fix, twice each; fail-to-pass and pass-to-pass derived; verifier and date recorded; dropped candidates with reasons; the repository suite time limit), and `select` (the SHA-256 rank of Decision 19, post-cutoff first, 10 accepted and 4 pilot per class, `bench/curation/selection.json`, the refusal on a short class and on a seed committed after the pool, idempotent). Extend the task schema with `curation.pilot` and make `validate` refuse an `accepted` task that `selection.json` does not list. The commands read the criteria only from the committed preregistration. Document the curation procedure in `bench/README.md`.
  Tests: small criteria per rule (licence, activity window, star range, exclusion list, bot author, size class boundaries 2/3 and 5/6 files and 300 lines, fix URL in the issue text), the rank function against hand-computed SHA-256 values, post-cutoff ordering, "A short size class stops the draw", "The draw is reproducible", "Nobody accepts a ticket by hand"; medium (stub `gh` on PATH replaying recorded API responses, stub `docker` from BEN-002, a temporary repository with commits for "The seed was fixed before the pool"): "A bot's pull request is not a candidate", "The size class follows the fix", "Verification fills in the tests" and "A flaky test drops the candidate" against the example fixture repository, a setup failure dropped with its reason; large (only with `NOGG_BENCH_DOCKER=1`, not in CI) `verify` on one example task in a real container.
  Check: uv run --project bench --extra dev pytest bench/tests/test_candidates.py bench/tests/test_verify.py bench/tests/test_select.py bench/tests/test_validate.py. Branch chore/impact-benchmark-curation-tools.

- [ ] TASK-BEN-009 [po-only] [~40 loc: one workflow file, held back because no agent credential has the workflow scope] The bench CI workflow `.github/workflows/bench.yml` runs the bench suite on every change under `bench/`.
  Per design Decisions 1, 3 and 22 item 7. The file is ready in the main checkout as `.nogging/state/bench.yml.pending` (path filter `bench/**`, Python 3.11 and 3.13, actions pinned by SHA, `pytest bench/tests` and `bench/nogg-bench validate`). The Product Owner either pushes it on a branch and opens the pull request against develop, or grants the agents' GitHub credential the `workflow` scope and tells the Orchestration Agent, which then has a Lead push it. No Lead claims this Bead.
  Tests: none (one CI workflow; its first run on the pull request is the check).
  Check: the Bench workflow runs green on its own pull request. Branch chore/bench-workflow.

- [ ] TASK-BEN-010 [complex] [security] [~250 loc: below the range on purpose; a discovery follow-up that changes container options and is reviewed on its own] Arm C finishes unattended in the run container: a local forge stand-in records its pull requests, and every arm gets the same container options.
  Per design Decision 20 and the requirement on arm C finishing unattended, following the discovery on BEN-002 (SPEC-ihi0). Add the `gh` stand-in the driver puts on the container's `PATH` for a `nogging` arm (`pr create`, `pr view`, `pr checks`, `pr merge` against the local bare origin; each pull request recorded in the run directory; checks reported as passed; no network), count `pr_count` from it, and give every arm's container the same security options, the least that `unshare --user --mount` needs, never `--privileged`, recorded in the result's provenance and in `metadata.json`. Then prove the discovery's open checks with real smoke runs on an example task (`--smoke`, the Raspberry Pi is allowed): arm C finishes with a done signal (`bd` and `dolt` without the host's Dolt server, Claude in tmux without onboarding or trust prompts), and arm B starts with web search disabled. A failing check is a blocking discovery naming it. Document the container options and the stand-in in `bench/README.md`.
  Tests: small the stand-in's answers per call and its refusal of anything else; medium (stub `docker` recording argv, stub `nogg` that plans and leads and calls `gh pr create`): "The Lead's pull request is recorded", "Every arm gets the same container", the provenance carries the options; large (only with `NOGG_BENCH_DOCKER=1`, not in CI) the arm C smoke run on an example task.
  Check: uv run --project bench --extra dev pytest bench/tests/test_driver.py bench/tests/test_run.py bench/tests/test_forge.py. Branch chore/impact-benchmark-arm-c.

- [ ] TASK-BEN-011 [standard] [~0 loc: the curation run on the run host; commits task data, no production code] The 30 benchmark tickets and the 12 pilot tickets are drawn from mechanically verified candidates and committed.
  Per design Decisions 18, 19 and 22 and the requirements on mechanical collection and the seeded draw. On the x86_64 run host with Docker: run `candidates repos` and commit the pool snapshot and log before anything else; take two Python and one TypeScript repository in draw order, writing an environment recipe for each and skipping one only for a recorded reason; run `candidates issues` and `verify`; commit the candidates and the verification records; then run `select` and commit the drawn tasks with `selection.json`. Set no status by hand and edit no criterion. A class with fewer than 10 verified candidates is a blocking discovery.
  Tests: none (a curation run; `nogg-bench validate` and the `select` refusals are the mechanical checks).
  Check: bench/nogg-bench validate bench/tasks bench/curation. Branch chore/impact-benchmark-curation.

- [ ] TASK-BEN-007 [standard] [~0 loc: the pilot runs and the review pack, no production code] The pilot (12 tickets, arms A, B and C) runs unattended on the run host, meets the reproducibility criterion, and its blinded review pack is ready for the Product Owner.
  Per design Decisions 7, 9, 11, 13, 21 and 22 and the proposal's acceptance. Since the 2026-11-17 revision an agent task, no longer `po-only`. Change the arm files' credential reference to the subscription logins on the run host (model, effort and timebox stay as committed) and commit it. Optionally smoke one or two tickets on the Raspberry Pi first (`--smoke`). Then on the x86_64 PC: the 12 pilot tickets times arms A, B and C, seed 1, as one batch with no manual intervention; a run that needs intervention is a blocking discovery, and the batch is repeated after the fix. Then seed 2 of arms A and C on the pilot tickets, and evaluate the preregistered reproducibility criterion; a miss is a blocking discovery that stops the full run. Write the blinded review pack of the 36 seed-1 pilot runs to a directory the Product Owner can open and the key to a separate one, name both in the Bead note, and commit neither. Commit `bench/results/` for the pilot batches.
  Tests: large (the real pilot on the run host; the automated scenarios are in BEN-001 to BEN-005, BEN-008 and BEN-010).
  Check: bench/nogg-bench validate bench/results. Branch chore/impact-benchmark-pilot.

- [ ] TASK-BEN-012 [po-only] [~0 loc: the Product Owner's blinded review] The Product Owner reviews the 36 blinded pilot diffs and fills in the record sheet.
  Per design Decisions 13, 21 and 22 item 4 and the requirement on blind review. The Product Owner opens the pack BEN-007 named, times each item with a stopwatch, and records per item the merge decision, the defects by severity, the review minutes and a comment, without opening the key. The filled sheet goes where the BEN-007 note says; BEN-014 imports it. This is the Product Owner's only hand work in the benchmark. No Lead claims this Bead.
  Tests: none (human review; `review-pack --import` in BEN-014 is the mechanical check).
  Check: the filled record sheet has one row per pack item. Branch none (no commit by the Product Owner).

- [ ] TASK-BEN-013 [standard] [~0 loc: the full run, no production code] The full run (30 tickets, arms A, B and C, 3 seeds) and one Harbor proof run complete on the run host.
  Per design Decisions 7, 9, 12 and 22 and the proposal's acceptance. Starts only after BEN-007 has met the reproducibility criterion. On the x86_64 PC with the subscription logins: 30 tickets times arms A, B and C, seeds 1 to 3, in resumable batches (a stopped batch resumes; no combination is rerun without `--rerun` and a recorded reason). If the subscription's limits block the run, record a blocking discovery naming the limit; the Orchestration Agent decides on the API, and a switch happens only between batches, changing only the credential reference. Then one real Harbor run of arm A on a few FeatureBench tasks proves the adapter (`source: harbor:featurebench`). Commit `bench/results/` for every batch, failed runs included.
  Tests: large (the real full run; the automated scenarios are in BEN-001 to BEN-005).
  Check: bench/nogg-bench validate bench/results. Branch chore/impact-benchmark-full-run.

- [ ] TASK-BEN-014 [standard] [~0 loc: report generation and the committed baseline, no production code] The baseline report for arms A, B and C, with the pilot's review metrics, is committed.
  Per design Decisions 13, 21 and 22 and the proposal's acceptance. Import the Product Owner's filled sheet with `review-pack --import` against the key of BEN-007, commit the review records and the key, write `bench/reports/pilot/` from the pilot batch with its review records and `bench/reports/baseline/` from the full-run batches, and commit both with their `runs.csv` and `metadata.json`. The baseline report names the pilot report for the review metrics and states every preregistered threshold as met, not met or tie. Acceptance: the pilot ran without manual intervention; two runs of one arm on one ticket are comparable by the preregistered criterion; the baseline report for A, B and C is committed. The feature freeze in AGENTS.md ends only when the Product Owner lifts it in a planning session.
  Tests: none (report generation over committed data; `report`'s own tests are in BEN-005).
  Check: bench/nogg-bench validate bench/results; bench/reports/baseline/ and bench/reports/pilot/ committed. Branch chore/impact-benchmark-baseline.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A depends on B):
002<-001; 004<-001; 005<-001; 006<-001; 003<-002; 007<-002; 007<-004; 007<-005; 007<-006;
008<-001; 010<-002; 011<-006; 011<-008; 007<-010; 007<-011; 012<-007; 013<-007; 013<-003;
014<-012; 014<-013. BEN-009 has no edge. The edge 007<-003 of the first plan is removed: the Harbor
proof run moved from BEN-007 to BEN-013.

- 002, 004 and 005 build on the contracts and fixtures of 001 and run in parallel (done).
- 003 reuses the agent launch and the usage helper of 002 (done).
- 006, 008 and 010 run in parallel now; 009 is the Product Owner's, whenever convenient.
- 011 needs the seed committed by 006 and the tools of 008.
- 007 needs the drawn tasks of 011 and the unattended arm C of 010.
- 012 (the Product Owner's review) and 013 (the full run) both start after 007 and run in parallel.
- 014 needs the review records of 012 and the results of 013.

Branches: the first wave used `<type>/impact-benchmark` (test/ 001, feat/ 002, refactor/ 004,
perf/ 005, fix/ 003); those worktrees and branches are not yet retired, so the revised tasks use
`docs/impact-benchmark` for 006 and `chore/impact-benchmark-<topic>` for the rest, as each task
names. Before allocating a dependent worktree, verify that every prerequisite execution commit is
integrated into develop. A closed Bead alone is not enough.

## Execution contract

**Scope.** A task's first line is its Bead title. Its full slice is that line plus the indented
paragraph under it, the design Decisions it names, and the matching requirements in specs/.

**Boundary.** Write only `bench/` (design Decision 1); `.github/workflows/bench.yml` is BEN-009's,
the Product Owner's. The bench
package imports nothing from Nogging and reaches it only through its command line, apart from the
one usage helper of Decision 10. A task that would need any other file records a blocking discovery
instead of editing it.

**Product Owner tasks.** Since the 2026-11-17 revision only BEN-009 (the bench workflow) and BEN-012
(the blinded review) are labelled `po-only` and assigned to `product-owner`. No Lead or specialist
claims them, and the Orchestration Agent launches no Lead for them. Leads list their work with
`bd ready --exclude-label po-only`. No agent fills in a review sheet, sets `accepted` other than
through `select`, edits the selection criteria or the thresholds, or edits `PREREGISTRATION.md`
after the first measured run.

**Run host.** BEN-008's large test, BEN-011, BEN-007 and BEN-013 need the x86_64 PC with Docker and
the subscription logins of Claude Code and Codex there. The kickoff of those Beads names how the
Lead reaches it (a Lead session on that host, or `bench/nogg-bench` run there over SSH from a
trusted session). Smoke runs (`--smoke`) may use the Raspberry Pi. A Lead that cannot reach the run
host records a blocking discovery and does not run measured batches anywhere else.

**Work.** The Main Worker claims each task and implements it only in its own allocated worktree, in
several commits within the configured commit range. Write the tier classification to the Bead note
on every launch.

**Security review.** BEN-002 and BEN-010 are marked [security]: BEN-002 moves credentials into
containers, BEN-010 changes the containers' security options. Each gets a code-reviewer pass before each commit and a reviewed pull request. On a Codex or Pi Lead, the
Orchestration Agent's PR review is that review.

**Testing.** Small and medium tests are offline: no Docker daemon, no Harbor, no agent CLI, no
network, no `bd` and no Dolt; `docker` and the agents are stubs on PATH, Harbor's environment is a
fake object, clocks are injected and nothing sleeps. A large test runs only behind its explicit
environment variable. Test in stages: the changed test files while working, those plus lint before
each commit, and the files the task's `Check:` names once per Bead. The full CI matrix is CI's job.
Run a long command as one blocking call (`./scripts/nogg run-quiet -- <command>`), and never poll
it.

**Closing.** Push the branch and open the pull request against develop (a run task's pull request
carries its committed data). Only then run bd close and
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
