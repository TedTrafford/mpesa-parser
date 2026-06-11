"""Tests for fly_profiling and sp_populate_rejection_reasons business rules.

These tests run without a database. They validate the qualification matrix,
model_category alignment, rejection-reason thresholds, and that the SQL
procedure sources contain the expected wiring.
"""
from __future__ import annotations

import os
import re

import pytest

from tests.profiling_rules import (
    CREDIT_LIMIT_MATRIX,
    MIN_TURNOVER_BY_RISK,
    applies_high_credit_risk,
    applies_low_turnover,
    credit_limit,
    model_category,
)

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROCEDURES_DIR = os.path.join(PROJECT_ROOT, "db", "procedures")


def _read_procedure(name: str) -> str:
    path = os.path.join(PROCEDURES_DIR, name)
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# ---------------------------------------------------------------------------
# Credit limit matrix
# ---------------------------------------------------------------------------
class TestCreditLimitMatrix:
    @pytest.mark.parametrize(
        ("risk", "turnover", "expected"),
        [
            (8, 8, 8000),
            (8, 7, 7000),
            (8, 6, 6000),
            (8, 5, 5000),
            (7, 8, 8000),
            (7, 7, 6000),
            (7, 6, 5000),
            (6, 8, 6000),
            (6, 7, 5000),
            (5, 8, 5000),
        ],
    )
    def test_qualifying_combinations(self, risk, turnover, expected):
        assert credit_limit(90, risk, turnover) == expected

    @pytest.mark.parametrize(
        ("risk", "turnover"),
        [
            (3, 7),
            (3, 8),
            (4, 6),
            (4, 8),
            (5, 5),
            (5, 7),
            (6, 4),
            (6, 6),
            (7, 3),
            (7, 5),
            (8, 2),
            (8, 4),
        ],
    )
    def test_non_qualifying_combinations_return_zero(self, risk, turnover):
        assert credit_limit(90, risk, turnover) == 0

    def test_insufficient_history_returns_zero(self):
        assert credit_limit(89, 8, 8) == 0
        assert credit_limit(None, 8, 8) == 0


# ---------------------------------------------------------------------------
# model_category must mirror credit_limit (regression for misclassification)
# ---------------------------------------------------------------------------
class TestModelCategoryAlignment:
    def test_qualified_only_when_limit_is_non_zero(self):
        for (risk, turnover), limit in CREDIT_LIMIT_MATRIX.items():
            category = model_category(90, risk, turnover)
            assert category == "qualified", f"({risk}, {turnover}) limit={limit}"
            assert limit > 0

    @pytest.mark.parametrize(
        ("risk", "turnover"),
        [
            (3, 7),
            (3, 8),
            (4, 8),
            (5, 7),
            (6, 6),
            (7, 5),
            (8, 4),
        ],
    )
    def test_previously_misclassified_cases_are_not_qualified(self, risk, turnover):
        """Old model_category logic marked these qualified with limit 0."""
        assert credit_limit(90, risk, turnover) == 0
        assert model_category(90, risk, turnover) == "not_qualified"

    def test_dti_hard_gate_overrides_qualification(self):
        assert model_category(90, 8, 8, debt_to_income_ratio=0.51) == "not_qualified"

    def test_dti_at_threshold_does_not_override(self):
        assert model_category(90, 8, 8, debt_to_income_ratio=0.50) == "qualified"


# ---------------------------------------------------------------------------
# Rejection reason thresholds (sp_populate_rejection_reasons)
# ---------------------------------------------------------------------------
class TestRejectionReasonThresholds:
    @pytest.mark.parametrize(
        ("risk", "turnover"),
        [(5, 7), (6, 6), (7, 5), (8, 4)],
    )
    def test_low_turnover_applies_below_minimum(self, risk, turnover):
        assert applies_low_turnover(90, risk, turnover) is True

    @pytest.mark.parametrize(
        ("risk", "turnover"),
        [(5, 8), (6, 7), (7, 6), (8, 5)],
    )
    def test_low_turnover_does_not_apply_at_minimum(self, risk, turnover):
        assert applies_low_turnover(90, risk, turnover) is False

    @pytest.mark.parametrize("risk", [1, 2, 3, 4])
    def test_high_credit_risk_applies_for_risk_up_to_four(self, risk):
        assert applies_high_credit_risk(90, risk) is True

    @pytest.mark.parametrize("risk", [5, 6, 7, 8])
    def test_high_credit_risk_does_not_apply_from_risk_five(self, risk):
        assert applies_high_credit_risk(90, risk) is False

    def test_min_turnover_map_matches_credit_matrix(self):
        for risk, minimum in MIN_TURNOVER_BY_RISK.items():
            assert credit_limit(90, risk, minimum) > 0
            assert credit_limit(90, risk, minimum - 1) == 0


# ---------------------------------------------------------------------------
# SQL procedure source checks
# ---------------------------------------------------------------------------
class TestProcedureSources:
    @pytest.fixture(scope="class")
    def fly_profiling_sql(self):
        return _read_procedure("fly_profiling.sql")

    @pytest.fixture(scope="class")
    def rejection_sql(self):
        return _read_procedure("sp_populate_rejection_reasons.sql")

    def test_fly_profiling_calls_fraud_rules_procedure(self, fly_profiling_sql):
        assert "CALL sp_populate_fraud_rules(ip_mobile_number)" in fly_profiling_sql

    def test_fraud_rules_calls_rejection_procedure(self):
        fraud_sql = _read_procedure("sp_populate_fraud_rules.sql")
        assert "CALL sp_populate_rejection_reasons(p_mobile_number)" in fraud_sql

    def test_rejection_includes_fraud_critical(self, rejection_sql):
        assert "FRAUD_CRITICAL" in rejection_sql
        assert "tbl_fraud_rules" in rejection_sql

    def test_credit_limit_enhancement_procedure_exists(self):
        enhancement_sql = _read_procedure("sp_apply_credit_limit_enhancement.sql")
        assert "tbl_credit_limit_enhancements" in enhancement_sql
        assert "aleza.loans" in enhancement_sql
        assert "enhancement_pct" in enhancement_sql

    def test_enhancement_calls_lem_rejection_procedure(self):
        enhancement_sql = _read_procedure("sp_apply_credit_limit_enhancement.sql")
        assert "CALL sp_populate_LEM_rejection_reasons(p_mobile_number)" in enhancement_sql

    def test_lem_rejection_reason_codes(self):
        lem_sql = _read_procedure("sp_populate_LEM_rejection_reasons.sql")
        for code in (
            "LEM_FRAUD_FLAG",
            "LEM_EXCESSIVE_ARREARS",
            "LEM_NO_CLOSED_LOAN",
            "LEM_LATE_LOAN_REPAYMENT",
            "LEM_HIGH_DEBT_TO_INCOME",
            "LEM_LIMIT_TENURE_INSUFFICIENT",
            "LEM_NO_MATRIX_CELL",
        ):
            assert code in lem_sql
        assert "tbl_LEM_rejection_reasons" in lem_sql

    def test_fly_profiling_model_category_uses_credit_limit(
        self, fly_profiling_sql
    ):
        assert "WHEN var_credit_limit > 0 THEN 'qualified'" in fly_profiling_sql
        assert "risk_segment = 3 AND turnover_segment IN (7, 8)" not in fly_profiling_sql

    def test_fly_profiling_credit_limit_matrix_in_sql(self, fly_profiling_sql):
        for (risk, turnover), limit in CREDIT_LIMIT_MATRIX.items():
            pattern = (
                rf"risk_segment\s*=\s*{risk}\s+AND\s+turnover_segment\s*=\s*"
                rf"{turnover}\s+THEN\s+{limit}"
            )
            assert re.search(pattern, fly_profiling_sql), (
                f"missing ({risk}, {turnover}) -> {limit}"
            )

    def test_rejection_procedure_accepts_mobile_parameter(self, rejection_sql):
        assert "IN p_mobile_number VARCHAR(20)" in rejection_sql
        assert "p_mobile_number IS NULL OR sp2.mobile_number = p_mobile_number" in (
            rejection_sql
        )

    def test_rejection_low_turnover_thresholds_in_sql(self, rejection_sql):
        for risk, minimum in MIN_TURNOVER_BY_RISK.items():
            assert f"WHEN {risk} THEN {minimum}" in rejection_sql

    def test_rejection_high_credit_risk_threshold_in_sql(self, rejection_sql):
        assert "risk_segment <= 4" in rejection_sql
        assert "minimum risk segment of 5" in rejection_sql
        assert "risk_segment <= 2" not in rejection_sql
