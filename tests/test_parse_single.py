"""Tests for parse_single.py — validation helpers (no DB, no real PDFs)."""
import os
import sys
import json

import pytest
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from parse_single import _validate_phone_number, _check_balance_continuity


# ---------------------------------------------------------------------------
# _validate_phone_number
# ---------------------------------------------------------------------------
class TestValidatePhoneNumber:
    def _df(self, mobile):
        return pd.DataFrame([{"Mobile Number": mobile, "Amount": 0, "Balance": 0}])

    def test_match(self):
        result = _validate_phone_number("254722123456", self._df("254722123456"))
        assert result == "MATCH"

    def test_match_normalises_both_sides(self):
        # caller passes local format, PDF has international
        result = _validate_phone_number("0722123456", self._df("254722123456"))
        assert result == "MATCH"

    def test_no_match(self):
        result = _validate_phone_number("254722123456", self._df("254733999999"))
        assert result == "NO_MATCH"

    def test_empty_phone_number_returns_na(self):
        result = _validate_phone_number("", self._df("254722123456"))
        assert result == "N/A"

    def test_none_df_returns_na(self):
        result = _validate_phone_number("254722123456", None)
        assert result == "N/A"

    def test_empty_df_returns_na(self):
        result = _validate_phone_number("254722123456", pd.DataFrame())
        assert result == "N/A"


# ---------------------------------------------------------------------------
# _check_balance_continuity
# ---------------------------------------------------------------------------
class TestCheckBalanceContinuity:
    def _make_df(self, rows):
        """rows: list of (date_str, time_str, amount, balance)"""
        return pd.DataFrame(
            [
                {"Date": d, "Time": t, "Amount": a, "Balance": b}
                for d, t, a, b in rows
            ]
        )

    def test_perfect_continuity(self):
        df = self._make_df([
            ("2024-01-01", "10:00:00", 1000.0,  1000.0),
            ("2024-01-02", "11:00:00", -200.0,   800.0),
            ("2024-01-03", "12:00:00",  500.0,  1300.0),
        ])
        pct = _check_balance_continuity(df)
        assert pct == 100.0

    def test_partial_continuity(self):
        # pair 1→2: 1000 + (-200) = 800, but balance is 900 → fails
        # pair 2→3: 900 + 500 = 1400, balance is 1400 → passes
        # 1 out of 2 pairs match → 50 %
        df = self._make_df([
            ("2024-01-01", "10:00:00", 1000.0, 1000.0),
            ("2024-01-02", "11:00:00", -200.0,  900.0),   # wrong — should be 800
            ("2024-01-03", "12:00:00",  500.0, 1400.0),   # correct given prev=900
        ])
        pct = _check_balance_continuity(df)
        assert pct == 50.0

    def test_single_row_returns_none(self):
        df = self._make_df([("2024-01-01", "10:00:00", 100.0, 100.0)])
        assert _check_balance_continuity(df) is None

    def test_none_returns_none(self):
        assert _check_balance_continuity(None) is None

    def test_empty_df_returns_none(self):
        assert _check_balance_continuity(pd.DataFrame()) is None

    def test_tolerance_accepted(self):
        # Difference of 0.009 should still count as match
        df = self._make_df([
            ("2024-01-01", "10:00:00", 1000.00, 1000.000),
            ("2024-01-02", "11:00:00", -200.00,  800.009),  # within 0.01
        ])
        pct = _check_balance_continuity(df)
        assert pct == 100.0
