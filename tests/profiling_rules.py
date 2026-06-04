"""Reference implementation of fly_profiling qualification rules for testing.

The stored procedures in db/procedures/ are the runtime source of truth.
This module mirrors their business logic so tests can validate behaviour
without a live MySQL connection.
"""

from __future__ import annotations

# (risk_segment, turnover_segment) -> credit limit (KES)
CREDIT_LIMIT_MATRIX: dict[tuple[int, int], int] = {
    (8, 8): 8000,
    (8, 7): 7000,
    (8, 6): 6000,
    (8, 5): 5000,
    (7, 8): 8000,
    (7, 7): 6000,
    (7, 6): 5000,
    (6, 8): 6000,
    (6, 7): 5000,
    (5, 8): 5000,
}

# Minimum turnover segment required to qualify at each risk segment.
MIN_TURNOVER_BY_RISK: dict[int, int] = {
    5: 8,
    6: 7,
    7: 6,
    8: 5,
}


def credit_limit(
    age_days: float | None,
    risk_segment: int,
    turnover_segment: int,
) -> int:
    """Return the credit limit for a risk/turnover combination."""
    if age_days is None or age_days < 90:
        return 0
    return CREDIT_LIMIT_MATRIX.get((risk_segment, turnover_segment), 0)


def model_category(
    age_days: float | None,
    risk_segment: int,
    turnover_segment: int,
    debt_to_income_ratio: float | None = None,
) -> str:
    """Return qualified when a non-zero limit applies and DTI gate passes."""
    limit = credit_limit(age_days, risk_segment, turnover_segment)
    if (
        debt_to_income_ratio is not None
        and debt_to_income_ratio > 0.5000
    ):
        return "not_qualified"
    return "qualified" if limit > 0 else "not_qualified"


def applies_low_turnover(
    age_days: float | None,
    risk_segment: int,
    turnover_segment: int,
) -> bool:
    """True when turnover is below the minimum for this risk segment."""
    if age_days is None or age_days < 90:
        return False
    minimum = MIN_TURNOVER_BY_RISK.get(risk_segment)
    if minimum is None:
        return False
    return turnover_segment < minimum


def applies_high_credit_risk(
    age_days: float | None,
    risk_segment: int,
) -> bool:
    """True when risk is too low for any credit-limit assignment."""
    if age_days is None or age_days < 90:
        return False
    return risk_segment <= 4
