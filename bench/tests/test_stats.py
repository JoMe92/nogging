"""The exact tests, checked against hand-computed binomial values."""

from __future__ import annotations

import pytest

from nogg_bench import stats


def test_discordant_pairs_decide_the_exact_p_value():
    # 9 vs 2 discordant pairs: n = 11, P(X <= 2) = (1 + 11 + 55) / 2048, doubled for two sides.
    assert stats.mcnemar_exact(9, 2) == 134 / 2048
    assert stats.mcnemar_exact(2, 9) == 134 / 2048  # the direction does not matter


@pytest.mark.parametrize(
    ("only_t", "only_c", "p"),
    [
        (0, 0, 1.0),  # no discordant pair: no evidence
        (5, 0, 2 / 32),
        (3, 3, 1.0),  # a balanced split is capped at 1, not 2 * 0.65625
        (1, 4, 2 * (1 + 5) / 32),
    ],
)
def test_mcnemar_hand_computed_values(only_t, only_c, p):
    assert stats.mcnemar_exact(only_t, only_c) == p


def test_the_sign_test_drops_ties():
    treatment = [1, 2, 3, 4, 5, 6]
    control = [2, 2, 1, 5, 6, 7]
    lower_t, lower_c, ties, p = stats.sign_test(treatment, control)
    assert (lower_t, lower_c, ties) == (4, 1, 1)
    assert p == 2 * (1 + 5) / 32  # five pairs remain, P(X <= 1) = 6 / 32


def test_the_sign_test_with_only_ties_says_nothing():
    assert stats.sign_test([1, 2], [1, 2]) == (0, 0, 2, 1.0)


def test_the_sign_test_needs_paired_samples():
    with pytest.raises(ValueError):
        stats.sign_test([1], [1, 2])


def test_the_binomial_rejects_impossible_counts():
    with pytest.raises(ValueError):
        stats.binomial_two_sided(3, 2)


def test_the_majority_is_strict_and_an_even_split_fails():
    assert stats.majority_pass([True, True, False])
    assert not stats.majority_pass([True, False])
    assert not stats.majority_pass([False])
    assert stats.majority_pass([True])


def test_the_median_across_seeds():
    assert stats.median_of([3.0, 1.0, 2.0]) == 2.0
    assert stats.median_of([1.0, 3.0]) == 2.0
    assert stats.median_of([]) is None
