# Preregistration (fixture, invalid)

```yaml
schema: 1
primary_comparisons:
  - {treatment: C, control: C}
accepted_ticket: whatever
thresholds:
  - id: c-vs-a-tests
    comparison: {treatment: C, control: A}
    metric: hidden_tests_passed
    size_class: all
    requirement: lead_by
significance_level: 1.5
```
