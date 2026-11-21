# Preregistration (fixture)

Prose describing the plan goes here. The thresholds block below is the part
that `nogg-bench validate` checks and `nogg-bench report` evaluates.

```yaml
schema: 1
primary_comparisons:
  - {treatment: C, control: A}
  - {treatment: C, control: B}
accepted_ticket: tests_pass_and_review_merge
thresholds:
  - id: c-vs-a-tests
    comparison: {treatment: C, control: A}
    metric: hidden_tests_passed
    size_class: all
    requirement: not_worse
  - id: c-vs-a-tests-medium-large
    comparison: {treatment: C, control: A}
    metric: hidden_tests_passed
    size_class: medium
    requirement: lead_by
    margin: 15
  - id: c-vs-a-cost
    comparison: {treatment: C, control: A}
    metric: cost_per_accepted_ticket
    size_class: all
    requirement: not_worse
minimum_effect:
  pass_rate_points: 5
  cost_ratio: 1.1
significance_level: 0.05
reproducibility:
  min_pass_agreement: 0.8
  max_cost_ratio: 1.5
```

The selection block fixes how the tickets are drawn.

```yaml
selection:
  method: seeded-draw
  seed: 20261117
  counts:
    per_size_class: 10
    pilot_per_size_class: 4
  training_cutoffs:
    - {model: claude-opus-5-5, cutoff: 2026-01-31, source: "https://example.org/models/claude"}
    - {model: gpt-6.1-sol, cutoff: 2026-02-28, source: "https://example.org/models/codex"}
  criteria:
    repositories:
      languages: {Python: 2, TypeScript: 1}
      licences: [MIT, Apache-2.0]
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
