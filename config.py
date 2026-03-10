#!/usr/bin/env python3
import os

# Base directory for the project
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# MySQL database connection settings
# ---------------------------------------------------------------------------
DB_HOST = os.environ.get("MPESA_DB_HOST", "139.84.243.180")
DB_PORT = int(os.environ.get("MPESA_DB_PORT", 3306))
DB_NAME = os.environ.get("MPESA_DB_NAME", "Data_Science")
DB_USER = os.environ.get("MPESA_DB_USER", "staging")
DB_PASSWORD = os.environ.get("MPESA_DB_PASSWORD", "gQTnYQ8Xwh1nl0di1rbz")
DB_TABLE = "tbl_raw_mpesa_statements"

# Directory paths
INPUT_DIR = os.path.join(BASE_DIR, "Mpesa_pdf_statement")
OUTPUT_DIR = os.path.join(BASE_DIR, "Mpesa_csv_Statement_Parsed")
FAILED_DIR = os.path.join(BASE_DIR, "Mpesa_csv_Statement_Failed")
DEBUG_DIR = os.path.join(BASE_DIR, "debug")
PARSER_SCRIPT = os.path.join(BASE_DIR, "parser", "mpesa_parser.py")

# Regex pattern for parsing MPESA transactions
TRANSACTION_PATTERN = r'([A-Z0-9]{10})\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+(.*?)(?:Completed|Failed)\s+(-?\d{1,3}(?:,\d{3})*(?:\.\d{2})?|-?\d+\.\d{2})\s+(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})'

# Transaction types mapping
TRANSACTION_TYPES = {
    "Transfer to": "SEND MONEY",
    "received from": "RECEIVED MONEY",
    "Withdrawal": "AGENT WITHDRAWAL",
    "Paybill": "LIPA NA M-PESA (PAYBILL)",
    "Pay Bill": "LIPA NA M-PESA (PAYBILL)",
    "Buy Goods": "LIPA NA M-PESA (BUY GOODS)",
    "Buy Bundles": "LIPA NA M-PESA (BUY GOODS)"
}

# Default transaction type if no match found
DEFAULT_TRANSACTION_TYPE = "OTHER"

# Date format for parsing timestamps
DATE_FORMAT = "%Y-%m-%d"

# Function to determine transaction type based on details
def get_transaction_type(details):
    """Determine transaction type from details text."""
    for keyword, trans_type in TRANSACTION_TYPES.items():
        if keyword in details:
            return trans_type
    return DEFAULT_TRANSACTION_TYPE 