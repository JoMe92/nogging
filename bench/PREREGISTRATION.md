# Preregistration of the impact benchmark

This file fixes, before anything is measured, what the benchmark measures, which
results count as a difference, and how its tickets are chosen. It is committed
before any candidate ticket is collected and before any measured run. Nobody
edits it after the first measured run: every result line records this file's
git blob hash, and `nogg-bench report` refuses to mix runs made under two
versions of it.

`nogg-bench validate` checks the two fenced `yaml` blocks below, `thresholds`
and `selection`. The prose around them says how they are read. Where the prose
fixes a reading, that reading is part of the preregistration.

## What is measured

The question is whether Nogging's ceremony pays for itself: does an agent that
works under Nogging solve more tickets, or the same tickets for less, than the
same agent without it.

- **Tickets.** 30 real issues from three open-source repositories (two Python,
  one TypeScript), 10 in each size class `small`, `medium` and `large`. Each
  ticket is an issue text, the commit the fix was based on, and hidden tests
  taken from the fix. 12 of the 30 (4 per size class) form the pilot.
- **Arms.** A: Claude Code with plan mode, no Nogging (control). B: Codex, no
  Nogging (second-vendor control). C: Nogging v3.6.0 unchanged (baseline). D: a
  later, changed Nogging; it has no arm file yet, and its thresholds are fixed
  here because nothing may be added after the first measured run. The arm files
  under `bench/arms/` fix model, effort, time limit and prompt for each arm.
- **Runs.** The pilot: the 12 pilot tickets with arms A, B and C, seed 1, and a
  second seed of arms A and C. The full run: the 30 tickets with arms A, B and
  C, seeds 1 to 3. A seed is a repetition number; the agents cannot be seeded.
- **Pass or fail.** A run passes when every hidden test of the ticket passes
  after the agent has finished. With several seeds a ticket passes for an arm
  when more than half of its runs pass.
- **Cost.** The tokens of a run from the usage ledger, priced at the list
  prices in `bench/prices.yaml`. With several seeds a ticket's cost for an arm
  is the median of its runs. An **accepted ticket** for the cost metric is one
  whose hidden tests pass; cost per accepted ticket is the summed cost of all
  paired tickets divided by the number of accepted ones.
- **Tokens per run.** Every token of a run: input, output, cache-read and
  cache-write tokens over all models. With several seeds a ticket's value for
  an arm is the median of its runs.
- **Review metrics.** The merge decision, the defects by severity and the
  review minutes from the blinded review of the pilot (see the third deviation).

Runs that are smoke runs, that failed for an infrastructure reason, or that are
flagged as suspected contamination are listed in the report and counted in no
table and no threshold.

## Three deviations

The benchmark deviates from real use in one point and from the roadmap in two.
Each report states them.

1. **Nogging arms plan without human approval.** In real use a human approves
   the plan and the change. Here the issue text is the planning brief and
   nobody approves anything, so that a run needs no human. The results show
   what Nogging does unattended, not what a supervised team gets.
2. **Tickets are drawn mechanically instead of curated by hand.** The roadmap
   had the Product Owner choose the repositories and tickets and check the
   hidden tests by hand, so that nobody close to the arms could steer the
   benchmark. The Product Owner delegated this on 2026-11-17. It is replaced by
   a procedure that steers nothing either: fixed criteria, an automatic check of
   the hidden tests, and a draw from a seed fixed in this file (see Selection).
3. **The review covers the pilot only.** The Product Owner reviews one blinded
   pack of the 36 pilot runs (12 tickets, arms A, B and C, seed 1). The second
   pilot seed and the full run are not reviewed. Therefore the review metrics
   are reported for the pilot tickets only, the primary metrics come from the
   full run, and an accepted ticket for the cost metric is one whose hidden
   tests pass, without a review decision.

## Thresholds

```yaml
schema: 1
primary_comparisons:
  - {treatment: D, control: A}
  - {treatment: C, control: A}
  - {treatment: C, control: B}
  - {treatment: D, control: C}
accepted_ticket: tests_pass
thresholds:
  # The roadmap's thresholds: the changed Nogging (D) against Claude Code alone (A).
  - {id: d-vs-a-tests, comparison: {treatment: D, control: A}, metric: hidden_tests_passed, size_class: all, requirement: not_worse}
  - {id: d-vs-a-cost, comparison: {treatment: D, control: A}, metric: cost_per_accepted_ticket, size_class: all, requirement: not_worse}
  - {id: d-vs-a-tests-medium, comparison: {treatment: D, control: A}, metric: hidden_tests_passed, size_class: medium, requirement: not_worse}
  - {id: d-vs-a-tests-large, comparison: {treatment: D, control: A}, metric: hidden_tests_passed, size_class: large, requirement: not_worse}
  # Phase 0, the baseline: Nogging unchanged (C) against both controls, on the same tests.
  - {id: c-vs-a-tests, comparison: {treatment: C, control: A}, metric: hidden_tests_passed, size_class: all, requirement: not_worse}
  - {id: c-vs-a-cost, comparison: {treatment: C, control: A}, metric: cost_per_accepted_ticket, size_class: all, requirement: not_worse}
  - {id: c-vs-a-tests-medium, comparison: {treatment: C, control: A}, metric: hidden_tests_passed, size_class: medium, requirement: not_worse}
  - {id: c-vs-a-tests-large, comparison: {treatment: C, control: A}, metric: hidden_tests_passed, size_class: large, requirement: not_worse}
  - {id: c-vs-b-tests, comparison: {treatment: C, control: B}, metric: hidden_tests_passed, size_class: all, requirement: not_worse}
  - {id: c-vs-b-cost, comparison: {treatment: C, control: B}, metric: cost_per_accepted_ticket, size_class: all, requirement: not_worse}
  - {id: c-vs-b-tests-medium, comparison: {treatment: C, control: B}, metric: hidden_tests_passed, size_class: medium, requirement: not_worse}
  - {id: c-vs-b-tests-large, comparison: {treatment: C, control: B}, metric: hidden_tests_passed, size_class: large, requirement: not_worse}
  # The Phase 1 gate of the adaptive-ceremony change: D with `ceremony.mode: adaptive` against C, small tickets.
  - {id: d-vs-c-tokens-small, comparison: {treatment: D, control: C}, metric: tokens_per_run, size_class: small, requirement: fewer}
  - {id: d-vs-c-tests-small, comparison: {treatment: D, control: C}, metric: hidden_tests_passed, size_class: small, requirement: not_worse}
minimum_effect:
  pass_rate_points: 15
  cost_ratio: 1.0
significance_level: 0.05
reproducibility:
  min_pass_agreement: 0.83
  max_cost_ratio: 1.25
```

### How a threshold is evaluated

Runs are paired per ticket across the two arms of a comparison. `report` gives
each threshold one of the verdicts `met`, `not met`, `tie`, or `unknown` when
there is nothing to evaluate.

- **Hidden tests passed.** The observation is the treatment's pass rate minus
  the control's, in percentage points, over the paired tickets of the size
  class. The minimum effect is 15 points: a lead of 15 points or more is `met`,
  a deficit of 15 points or more is `not met`, anything in between is a `tie`,
  which means no difference was shown. With 10 tickets in a size class one
  ticket is 10 points, so a difference needs at least 2 tickets; over all 30
  tickets it needs at least 5. McNemar's exact test on the discordant tickets
  is reported with each comparison, two-sided, at the significance level 0.05.
  Its p-value is stated next to the verdict and does not change it.
- **Cost per accepted ticket.** The observation is the treatment's cost per
  accepted ticket divided by the control's. A ratio of at most 1 is `met`, a
  ratio above 1 is `not met`. The roadmap names no band in which two costs
  count as equal, so there is none (`cost_ratio: 1.0`). The exact sign test on
  the per-ticket costs, ties dropped, two-sided, is reported with its p-value
  and does not change the verdict.
- **Tokens per run.** Decided by the exact sign test alone, ties dropped,
  two-sided: `met` when the treatment used fewer tokens on more tickets than
  the control and the p-value is below 0.05, `not met` when the control did,
  and `tie` when the p-value is 0.05 or more. When all 10 tickets differ, a
  `met` needs the treatment to use fewer tokens on at least 9 of them.

### What each criterion needs

| Criterion | Thresholds | Holds when |
| --- | --- | --- |
| D is at least as good as A on hidden tests | `d-vs-a-tests` | `met` or `tie` |
| D's cost per accepted ticket is at most A's | `d-vs-a-cost` | `met` |
| On medium and large tickets D is at least 15 points ahead of A | `d-vs-a-tests-medium`, `d-vs-a-tests-large` | both `met` |
| Phase 1 gate: D uses fewer tokens per run than C on the 10 small tickets | `d-vs-c-tokens-small` | `met` |
| Phase 1 gate: D does not pass less often than C on the 10 small tickets | `d-vs-c-tests-small` | `met` or `tie` |

The thresholds for C against A and C against B decide nothing. They describe
the baseline with the same tests, so that the later comparison with D has a
fixed reference. Arm D in the Phase 1 gate is the arm with the switch
`ceremony.mode: adaptive`; the gate's limits on a fast-lane change are checked
by the adaptive-ceremony change itself and are not a threshold here.

### Readings fixed here

- "At least 15 points ahead" is written as `not_worse` and must be `met`. With a
  minimum effect of 15 points, `met` means a lead of 15 points or more, which is
  the roadmap's threshold. Written as `lead_by` with a margin of 15, `report`
  would ask for the margin plus the minimum effect, a lead of 30 points.
- "On medium and large tickets" is evaluated per size class, 10 tickets each,
  and both classes must be `met`. A threshold names one size class.
- "At least as good" and "not less often" hold on a `tie`: a difference under
  15 points is not treated as a difference in either direction.

### Reproducibility

The full run starts only when the pilot meets this criterion, for arm A and for
arm C separately, on the 12 pilot tickets with their two seeds:

- the two seeds agree on pass or fail for at least 10 of the 12 tickets
  (`min_pass_agreement: 0.83`; 10 of 12 is 0.833, 9 of 12 is 0.75); and
- the median over the 12 tickets of the relative cost difference between the
  two seeds is at most 25 percent. A ticket's relative cost difference is the
  difference between its two costs divided by the smaller one, so 25 percent is
  a ratio of 1.25 between the dearer and the cheaper run (`max_cost_ratio`).

`report` prints the pass agreement per arm and the number of tickets whose two
costs are further apart than 1.25. A miss stops the full run and goes back to
planning.

## Selection

```yaml
selection:
  method: seeded-draw
  seed: 3234295649
  counts:
    per_size_class: 10
    pilot_per_size_class: 4
  training_cutoffs:
    - model: claude-opus-5-5
      cutoff: 2026-06-30
      source: https://platform.claude.com/docs/en/models/opus-5-5/overview
    - model: gpt-6.1-sol
      cutoff: 2026-04-30
      source: https://developers.openai.com/api/docs/models/gpt-6.1-sol
  criteria:
    repositories:
      languages: {Python: 2, TypeScript: 1}
      licences: [MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC]
      last_commit_within_days: 90
      min_merged_pull_requests: 10
      merged_pull_requests_within_days: 180
      min_stars: 300
      max_stars: 20000
      exclusion_list: curation/exclude.yaml
      suite_time_limit_minutes: 10
    issues:
      linked_merged_pull_requests: 1
      small_max_files: 2
      medium_max_files: 5
      large_min_lines: 300
    verification:
      runs_per_side: 2
```

### The seed

Nobody picked the seed. It is the first eight hexadecimal digits of the ID of
the commit on `develop` from which this file's branch was started,
`c0c76f611557a83ec600495038eb860ea8f1698a` (a merge commit of 2026-11-18), read
as an integer: `0xc0c76f61` is 3234295649. That commit existed before this file
was written. No candidate pool existed when the seed was fixed, so no outcome of
the draw could be known. `nogg-bench select` refuses to draw when the commit
that introduced this block is not an ancestor of the commit that first added the
pool.

### The draw

The draw is a function of the seed and the committed pool and needs no random
number generator. The rank key of an item is the SHA-256, in hexadecimal, of the
text `<seed>:<key>`, with the seed in decimal and the key a repository's full
name or a candidate's task ID; items are sorted by rank key, ascending. For
example the rank key of `example/widgets` is the SHA-256 of
`3234295649:example/widgets`, which starts with `ffe54f13`.

- Repositories are taken per primary language in rank order: 2 Python, 1
  TypeScript. A repository whose test suite the curating agent cannot make run
  within the time limit is skipped, with the reason in the committed pool log.
  Skipping is the only freedom in the procedure.
- Tickets are drawn per size class from the verified candidates: first those
  whose issue was closed after the latest training cutoff below, then the
  others, each group in rank order. The first 10 of a class are accepted, and
  the first 4 of those 10 are the pilot tickets.
- A size class with fewer than 10 verified candidates stops the draw.

### Training cutoffs

Read on 2026-11-21 from the vendors' model pages named in the block.

- `claude-opus-5-5` (arms A and C): the page gives the training data cutoff as
  "Jun 2026", a month. The last day of that month, 2026-06-30, is used, so that
  no issue closed within the month counts as later than the cutoff.
- `gpt-6.1-sol` (arm B): the page gives a knowledge cutoff of "Apr 30, 2026".
  The vendor publishes no separate training cutoff; this date is used.

The latest cutoff is 2026-06-30. An issue counts as closed after it when it was
closed on 2026-07-01 or later.

### Criteria

**Repositories.** A repository enters the pool when, at the time of the pool
snapshot, it:

- has Python or TypeScript as its primary language;
- carries one of the licences MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause or
  ISC, by SPDX identifier;
- has a commit on its default branch in the last 90 days and at least 10 merged
  pull requests in the last 180 days;
- has between 300 and 20,000 stars, both included;
- is on none of the lists in `bench/curation/exclude.yaml`: the repositories of
  SWE-bench, SWE-bench Verified, the public SWE-bench Pro set, SWE-Gym and
  FeatureBench, each list with the source it was read from. Names are compared
  without regard to case.

A drawn repository must also have a test suite that installs and runs green at
its default branch head in the task container in under 10 minutes on the run
host.

**Issues.** An issue of a chosen repository becomes a candidate when:

- it was closed as completed and is linked to exactly 1 merged pull request,
  whose author is not a bot account;
- that pull request changes both test files and other files. The changes to
  test files become the hidden tests; the pull request's base becomes the
  ticket's base commit;
- the issue text contains neither the URL of that pull request nor a diff.

The size class follows the pull request's changes outside test files: `large`
with 6 or more files or 300 or more changed lines (added plus removed);
otherwise `small` with 1 or 2 files and `medium` with 3 to 5 files.

**Verification.** In the task container, the test suite runs with the hidden
tests on the base commit and on the original fix, 2 times each. A candidate is
verified when at least one test fails on the base and passes on the fix, and
both runs of each side give the same outcome. A test that changes its outcome
between the two runs, a failed setup, or a suite over the time limit drops the
candidate, with the reason recorded. No status is set by hand.

## What stays as it is

The arm files' model, effort and time limit stay as committed. Before the pilot
only their credential reference changes. Arm D's file arrives with the
adaptive-ceremony change and uses arm C's model, effort and time limit. A change
to an arm's model would need a new training cutoff in this file and is therefore
not possible after the first measured run.
