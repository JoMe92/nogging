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
