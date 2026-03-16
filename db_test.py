#!/usr/bin/env python3
"""
db_test.py
----------
Run this directly on the server to diagnose DB upload failures.

    python db_test.py

Checks each step in isolation and prints a clear pass/fail for each.
"""

import os
import sys
import json
from datetime import date, time

# ── project root on sys.path ──────────────────────────────────────────────────
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

PASS = "\033[32m PASS\033[0m"
FAIL = "\033[31m FAIL\033[0m"


def step(label: str):
    print(f"\n{'─'*60}\n▶  {label}")


# ── 1. Config ─────────────────────────────────────────────────────────────────
step("1. Load config")
try:
    from config import DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_TABLE, LOG_DIR
    print(f"   host     : {DB_HOST}:{DB_PORT}")
    print(f"   database : {DB_NAME}")
    print(f"   user     : {DB_USER}")
    print(f"   table    : {DB_TABLE}")
    print(f"   log_dir  : {LOG_DIR}")
    print(PASS)
except Exception as e:
    print(f"{FAIL} — {e}")
    sys.exit(1)


# ── 2. pymysql import ─────────────────────────────────────────────────────────
step("2. Import pymysql")
try:
    import pymysql
    print(f"   version: {pymysql.__version__}")
    print(PASS)
except ImportError as e:
    print(f"{FAIL} — {e}")
    print("   Fix: pip install PyMySQL")
    sys.exit(1)


# ── 3. Raw TCP connection to DB host ─────────────────────────────────────────
step("3. Raw TCP connect to DB host")
import socket
try:
    sock = socket.create_connection((DB_HOST, DB_PORT), timeout=5)
    sock.close()
    print(f"   Reached {DB_HOST}:{DB_PORT}")
    print(PASS)
except Exception as e:
    print(f"{FAIL} — {e}")
    print("   Likely cause: firewall blocking port 3306, or wrong host/port.")
    sys.exit(1)


# ── 4. Authenticate with MySQL ────────────────────────────────────────────────
step("4. MySQL authentication")
try:
    conn = pymysql.connect(
        host=DB_HOST, port=DB_PORT,
        user=DB_USER, password=DB_PASSWORD,
        database=DB_NAME, charset="utf8mb4",
        connect_timeout=5,
    )
    conn.close()
    print(f"   Authenticated as {DB_USER}@{DB_HOST}/{DB_NAME}")
    print(PASS)
except Exception as e:
    print(f"{FAIL} — {e}")
    print("   Likely cause: wrong credentials, or user lacks access from this host.")
    sys.exit(1)


# ── 5. SQLAlchemy engine ──────────────────────────────────────────────────────
step("5. SQLAlchemy engine + pool_pre_ping")
try:
    from sqlalchemy import create_engine, text
    url = (
        f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}"
        f"@{DB_HOST}:{DB_PORT}/{DB_NAME}?charset=utf8mb4"
    )
    engine = create_engine(url, pool_pre_ping=True)
    with engine.connect() as c:
        version = c.execute(text("SELECT VERSION()")).scalar()
    print(f"   MySQL version: {version}")
    print(PASS)
except Exception as e:
    print(f"{FAIL} — {e}")
    sys.exit(1)


# ── 6. Table exists / create ──────────────────────────────────────────────────
step("6. Ensure table exists")
try:
    from db.uploader import ensure_table_exists
    ensure_table_exists()
    print(PASS)
except Exception as e:
    print(f"{FAIL} — {e}")
    sys.exit(1)


# ── 7. Full upload with a dummy row ───────────────────────────────────────────
step("7. INSERT a test row via upload_to_mysql")
try:
    import pandas as pd
    from db.uploader import upload_to_mysql

    dummy = pd.DataFrame([{
        "Record ID":        "db_test_probe",
        "Customer Name":    "DB Test",
        "Mobile Number":    "0700000000",
        "Email Address":    "test@test.com",
        "Statement Period": "2024-01-01 to 2024-01-31",
        "Request Date":     "2024-01-31",
        "Date":             date(2024, 1, 15),
        "Time":             "10:00:00",
        "Receipt No":       "DBTEST00001",
        "Transaction Type": "OTHER",
        "Details":          "db_test.py diagnostic probe — safe to delete",
        "Amount":           0.00,
        "Balance":          0.00,
    }])

    inserted = upload_to_mysql(dummy)
    if inserted == 1:
        print(f"   Inserted 1 row (receipt_no=DBTEST00001)")
        print(PASS)
    else:
        print(f"   Inserted {inserted} rows — row may already exist (INSERT IGNORE skipped it)")
        print(f"   This is normal on re-runs; check DB manually for receipt_no='DBTEST00001'")
        print(PASS)
except Exception as e:
    import traceback
    print(f"{FAIL} — {e}")
    traceback.print_exc()
    sys.exit(1)


# ── Summary ───────────────────────────────────────────────────────────────────
print(f"\n{'═'*60}")
print("  All checks passed. DB connectivity and upload are working.")
print(f"{'═'*60}\n")
print("Next steps:")
print("  • Delete the test row:  DELETE FROM tbl_raw_mpesa_statements WHERE receipt_no='DBTEST00001';")
print("  • Then check logs/db_errors.log and logs/processing_log.log for")
print("    errors from real parse_single.py runs.")
