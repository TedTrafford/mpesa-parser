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
DB_TABLE      = "tbl_raw_mpesa_statements"
DB_LOGS_TABLE = "tbl_file_processing_logs"

# Directory paths
INPUT_DIR = os.path.join(BASE_DIR, "Mpesa_pdf_statement")
OUTPUT_DIR = os.path.join(BASE_DIR, "Mpesa_csv_Statement_Parsed")
FAILED_DIR = os.path.join(BASE_DIR, "Mpesa_csv_Statement_Failed")
LOG_DIR = os.path.join(BASE_DIR, "logs")
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

# ---------------------------------------------------------------------------
# Mobile number normalisation
# ---------------------------------------------------------------------------
# ISO 3166-1 numeric country code prepended after stripping the local trunk
# prefix ('0').  Override with the MOBILE_COUNTRY_CODE environment variable
# when deploying outside Kenya.
MOBILE_COUNTRY_CODE = os.environ.get("MOBILE_COUNTRY_CODE", "254")


def normalize_mobile_number(number: str) -> str:
    """Return *number* in international format using MOBILE_COUNTRY_CODE.

    Handles the three forms seen in practice:
        '0722123456'       ->  '254722123456'   (local with trunk prefix)
        '+254722123456'    ->  '254722123456'   (E.164 with '+')
        '254722123456'     ->  '254722123456'   (already normalised — no-op)
        '722123456'        ->  '722123456'      (no recognised prefix — unchanged)
    """
    number = number.strip()
    if number.startswith("+"):
        number = number[1:]
    elif number.startswith("0"):
        number = MOBILE_COUNTRY_CODE + number[1:]
    return number


# Function to determine transaction type based on details
def get_transaction_type(details):
    """Determine transaction type from details text."""
    for keyword, trans_type in TRANSACTION_TYPES.items():
        if keyword in details:
            return trans_type
    return DEFAULT_TRANSACTION_TYPE 