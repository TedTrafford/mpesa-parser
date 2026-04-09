"""Tests for parser/mpesa_parser.py — pure parsing logic (no DB, no real PDFs)."""
import os
import sys
import hashlib
import json
import tempfile
from datetime import datetime
from unittest.mock import patch, MagicMock

import pytest
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from parser.mpesa_parser import (
    extract_customer_info,
    get_pdf_password,
    compute_manifest_hash,
    _attach_metadata,
    parse_mpesa_statement,
)


# ---------------------------------------------------------------------------
# compute_manifest_hash
# ---------------------------------------------------------------------------
class TestComputeManifestHash:
    def test_returns_32_char_hex(self, tmp_path):
        pdf = tmp_path / "123456.pdf"
        pdf.write_bytes(b"dummy content")
        h = compute_manifest_hash(str(pdf))
        assert len(h) == 32
        assert all(c in "0123456789abcdef" for c in h)

    def test_different_content_different_hash(self, tmp_path):
        a = tmp_path / "file.pdf"
        b = tmp_path / "file.pdf"
        a.write_bytes(b"content A")
        h1 = compute_manifest_hash(str(a))
        a.write_bytes(b"content B")
        h2 = compute_manifest_hash(str(a))
        assert h1 != h2

    def test_different_filename_different_hash(self, tmp_path):
        a = tmp_path / "alpha.pdf"
        b = tmp_path / "beta.pdf"
        a.write_bytes(b"same content")
        b.write_bytes(b"same content")
        assert compute_manifest_hash(str(a)) != compute_manifest_hash(str(b))


# ---------------------------------------------------------------------------
# get_pdf_password
# ---------------------------------------------------------------------------
class TestGetPdfPassword:
    def test_pure_number_filename(self):
        assert get_pdf_password("/some/path/123456.pdf") == "123456"

    def test_text_prefix_filename(self):
        assert get_pdf_password("/path/Maniga123456.pdf") == "123456"

    def test_underscore_old_format(self):
        assert get_pdf_password("/path/123456_somename.pdf") == "123456"

    def test_no_six_digit_uses_full_stem(self):
        # No 6-digit group, no underscore → use entire basename without extension
        assert get_pdf_password("/path/ABCDEF.pdf") == "ABCDEF"

    def test_global_password_override(self):
        import parser.mpesa_parser as mp
        original = mp.PASSWORD
        mp.PASSWORD = "override_pw"
        try:
            assert get_pdf_password("/path/123456.pdf") == "override_pw"
        finally:
            mp.PASSWORD = original


# ---------------------------------------------------------------------------
# extract_customer_info
# ---------------------------------------------------------------------------
SAMPLE_HEADER = """
Customer Name: John Doe
Mobile Number: 0722123456
Email Address: john@example.com
Statement Period: 01/01/2024 - 31/01/2024
Request Date: 01/02/2024
"""


class TestExtractCustomerInfo:
    def test_all_fields_extracted(self):
        info = extract_customer_info(SAMPLE_HEADER)
        assert info["Customer Name"] == "John Doe"
        assert info["Mobile Number"] == "254722123456"   # normalised
        assert info["Email Address"] == "john@example.com"
        assert info["Statement Period"] == "01/01/2024 - 31/01/2024"
        assert info["Request Date"] == "01/02/2024"

    def test_missing_fields_return_empty(self):
        info = extract_customer_info("No relevant fields here")
        assert info["Customer Name"] == ""
        assert info["Mobile Number"] == ""

    def test_mobile_already_international(self):
        text = "Mobile Number: 254722123456\n"
        info = extract_customer_info(text)
        assert info["Mobile Number"] == "254722123456"


# ---------------------------------------------------------------------------
# parse_mpesa_statement — transaction parsing
# ---------------------------------------------------------------------------
SAMPLE_STATEMENT = """
Customer Name: Jane Smith
Mobile Number: 0711000000
Email Address: jane@example.com
Statement Period: 01/03/2024 - 31/03/2024
Request Date: 01/04/2024

QA1234567X 2024-03-01 10:00:00 Transfer to Bob Completed -500.00 4,500.00
QB9876543Y 2024-03-02 11:30:00 received from Alice Completed 1,000.00 5,500.00
QC1111111Z 2024-03-03 09:15:00 Paybill KPLC Completed -200.00 5,300.00
"""


class TestParseMpesaStatement:
    def test_transaction_count(self):
        transactions = parse_mpesa_statement(SAMPLE_STATEMENT, "/fake/path/test.pdf")
        assert len(transactions) == 3

    def test_transaction_fields(self):
        transactions = parse_mpesa_statement(SAMPLE_STATEMENT, "/fake/path/test.pdf")
        t = transactions[0]
        assert t["Receipt No"] == "QA1234567X"
        assert t["Amount"] == -500.00
        assert t["Balance"] == 4500.00
        assert t["Transaction Type"] == "SEND MONEY"
        assert isinstance(t["Date"], datetime)

    def test_customer_info_populated(self):
        transactions = parse_mpesa_statement(SAMPLE_STATEMENT, "/fake/path/test.pdf")
        t = transactions[0]
        assert t["Customer Name"] == "Jane Smith"
        assert t["Mobile Number"] == "254711000000"

    def test_empty_text_returns_empty_list(self):
        assert parse_mpesa_statement("No transactions here", "/fake/test.pdf") == []


# ---------------------------------------------------------------------------
# _attach_metadata
# ---------------------------------------------------------------------------
class TestAttachMetadata:
    def _make_df(self):
        return pd.DataFrame([{"Receipt No": "QA1234567X", "Amount": -100.0}])

    def test_metadata_column_added(self, tmp_path):
        pdf = tmp_path / "123456.pdf"
        pdf.write_bytes(b"pdf bytes")
        csv = tmp_path / "output.csv"
        df = self._make_df()
        result = _attach_metadata(df, str(pdf), str(csv))
        assert "metadata" in result.columns

    def test_metadata_is_valid_json(self, tmp_path):
        pdf = tmp_path / "123456.pdf"
        pdf.write_bytes(b"pdf bytes")
        csv = tmp_path / "output.csv"
        df = self._make_df()
        result = _attach_metadata(df, str(pdf), str(csv))
        for raw in result["metadata"]:
            parsed = json.loads(raw)
            assert "manifest_hash" in parsed
            assert "record_uuid" in parsed
            assert "output_file_path" in parsed

    def test_each_row_unique_uuid(self, tmp_path):
        pdf = tmp_path / "123456.pdf"
        pdf.write_bytes(b"pdf bytes")
        csv = tmp_path / "output.csv"
        df = pd.DataFrame([{"A": 1}, {"A": 2}, {"A": 3}])
        result = _attach_metadata(df, str(pdf), str(csv))
        uuids = [json.loads(m)["record_uuid"] for m in result["metadata"]]
        assert len(set(uuids)) == 3
