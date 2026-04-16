"""Tests for config.py — normalisation helpers and transaction-type mapping."""
import os
import sys

import pytest

# Ensure the project root is importable
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from config import (
    normalize_mobile_number,
    get_transaction_type,
    TRANSACTION_TYPES,
    DEFAULT_TRANSACTION_TYPE,
)


# ---------------------------------------------------------------------------
# normalize_mobile_number
# ---------------------------------------------------------------------------
class TestNormalizeMobileNumber:
    def test_local_trunk_prefix(self):
        assert normalize_mobile_number("0722123456") == "254722123456"

    def test_already_international(self):
        assert normalize_mobile_number("254722123456") == "254722123456"

    def test_e164_with_plus(self):
        assert normalize_mobile_number("+254722123456") == "254722123456"

    def test_no_recognised_prefix_unchanged(self):
        # 9-digit number with no trunk / country prefix
        assert normalize_mobile_number("722123456") == "722123456"

    def test_strips_whitespace(self):
        assert normalize_mobile_number("  0722123456  ") == "254722123456"

    def test_empty_string(self):
        assert normalize_mobile_number("") == ""


# ---------------------------------------------------------------------------
# get_transaction_type
# ---------------------------------------------------------------------------
class TestGetTransactionType:
    @pytest.mark.parametrize("keyword, expected", [
        ("Transfer to John", "SEND MONEY"),
        ("received from Jane", "RECEIVED MONEY"),
        ("Withdrawal at Agent", "AGENT WITHDRAWAL"),
        ("Paybill payment", "LIPA NA M-PESA (PAYBILL)"),
        ("Pay Bill to KRA", "LIPA NA M-PESA (PAYBILL)"),
        ("Buy Goods at Supermarket", "LIPA NA M-PESA (BUY GOODS)"),
        ("Buy Bundles Safaricom", "LIPA NA M-PESA (BUY GOODS)"),
    ])
    def test_known_keywords(self, keyword, expected):
        assert get_transaction_type(keyword) == expected

    def test_unknown_returns_default(self):
        assert get_transaction_type("Some random detail") == DEFAULT_TRANSACTION_TYPE

    def test_empty_returns_default(self):
        assert get_transaction_type("") == DEFAULT_TRANSACTION_TYPE

    def test_case_sensitive_mismatch(self):
        # "transfer to" (lower) should NOT match "Transfer to" keyword
        assert get_transaction_type("transfer to someone") == DEFAULT_TRANSACTION_TYPE
