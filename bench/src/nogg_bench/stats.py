"""Exact tests for the paired report, without a statistics dependency.

Both tests reduce to the same binomial: among ``n`` pairs that differ, how
likely is a split at least as uneven as the one seen if each direction is as
likely as the other. Python integers keep the arithmetic exact.
"""

from __future__ import annotations

from math import comb
from statistics import median
from typing import Sequence


def binomial_two_sided(k: int, n: int) -> float:
    """Exact two-sided p-value of ``k`` successes in ``n`` fair trials.

    ``min(1, 2 * P(X <= min(k, n - k)))`` for ``X ~ Binomial(n, 1/2)``. With
    no trials the data say nothing and the p-value is 1.
    """
    if n < 0 or not 0 <= k <= n:
        raise ValueError(f"need 0 <= k <= n, got k={k}, n={n}")
    if n == 0:
        return 1.0
    tail = sum(comb(n, i) for i in range(min(k, n - k) + 1))
    return min(1, 2 * tail / 2**n)


def mcnemar_exact(treatment_only: int, control_only: int) -> float:
    """McNemar's exact test on the discordant pairs (pass/fail per ticket).

    ``treatment_only`` is the number of tickets only the treatment arm passed,
    ``control_only`` those only the control passed; concordant pairs do not
    enter the test.
    """
    return binomial_two_sided(treatment_only, treatment_only + control_only)


def sign_test(treatment: Sequence[float], control: Sequence[float]) -> tuple[int, int, int, float]:
    """Exact sign test on paired values, ties dropped.

    Returns ``(lower_in_treatment, lower_in_control, ties, p)``, where the
    first two count the pairs in which that arm's value is the smaller one
    (for cost: the cheaper arm).
    """
    if len(treatment) != len(control):
        raise ValueError("the two samples must have the same length")
    lower_t = sum(1 for t, c in zip(treatment, control) if t < c)
    lower_c = sum(1 for t, c in zip(treatment, control) if c < t)
    ties = len(treatment) - lower_t - lower_c
    return lower_t, lower_c, ties, binomial_two_sided(lower_t, lower_t + lower_c)


def majority_pass(passes: Sequence[bool]) -> bool:
    """A ticket passes for an arm when strictly more than half of its runs pass.

    An even split is a fail: the report does not credit a ticket the arm
    solved only half the time.
    """
    return 2 * sum(1 for p in passes if p) > len(passes)


def median_of(values: Sequence[float]) -> float | None:
    return float(median(values)) if values else None
