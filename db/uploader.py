#!/usr/bin/env python3
"""
db/uploader.py
--------------
Handles creating the MySQL table (if it does not exist) and uploading a
parsed M-PESA DataFrame to `tbl_raw_mpesa_statements`.

Duplicate rows are silently skipped thanks to INSERT IGNORE — re-running the
parser against the same PDF will not create duplicate records.
"""

import os
import sys
import traceback
from datetime import datetime, timezone
import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.dialects.mysql import insert as mysql_insert

# Allow imports from the project root
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_TABLE, LOG_DIR

_DB_ERROR_LOG = os.path.join(LOG_DIR, "db_errors.log")


def _log_db_error(context: str, exc: Exception) -> None:
    """Append a timestamped error entry to db_errors.log."""
    os.makedirs(LOG_DIR, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(_DB_ERROR_LOG, "a") as fh:
        fh.write(f"\n[{ts}] {context}\n")
        fh.write(traceback.format_exc())
        fh.write("\n")

# ---------------------------------------------------------------------------
# Column rename map: DataFrame column  →  MySQL column
# ---------------------------------------------------------------------------
COLUMN_MAP = {
    "Record ID":        "record_id",
    "Customer Name":    "customer_name",
    "Mobile Number":    "mobile_number",
    "Email Address":    "email_address",
    "Statement Period": "statement_period",
    "Request Date":     "request_date",
    "Date":             "transaction_date",
    "Time":             "transaction_time",
    "Receipt No":       "receipt_no",
    "Transaction Type": "transaction_type",
    "Details":          "details",
    "Amount":           "amount",
    "Balance":          "balance",
    "metadata":         "metadata",
}

# ---------------------------------------------------------------------------
# DDL — kept in sync with db/schema.sql
# ---------------------------------------------------------------------------
_CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS `{table}` (
    `id`                BIGINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    `record_id`         VARCHAR(255)        NOT NULL DEFAULT '',
    `customer_name`     VARCHAR(255)        NOT NULL DEFAULT '',
    `mobile_number`     VARCHAR(20)         NOT NULL DEFAULT '',
    `email_address`     VARCHAR(255)        NOT NULL DEFAULT '',
    `statement_period`  VARCHAR(100)        NOT NULL DEFAULT '',
    `request_date`      VARCHAR(50)         NOT NULL DEFAULT '',
    `transaction_date`  DATE                NOT NULL,
    `transaction_time`  TIME                NOT NULL,
    `receipt_no`        VARCHAR(20)         NOT NULL,
    `transaction_type`  VARCHAR(100)        NOT NULL DEFAULT '',
    `details`           TEXT                NOT NULL,
    `amount`            DECIMAL(15, 2)      NOT NULL,
    `balance`           DECIMAL(15, 2)      NOT NULL,
    `metadata`          JSON                NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY  `uq_receipt_no`        (`receipt_no`),
    INDEX       `idx_record_id`        (`record_id`),
    INDEX       `idx_mobile_number`    (`mobile_number`),
    INDEX       `idx_transaction_date` (`transaction_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Raw M-PESA statement transactions parsed from PDF files'
""".format(table=DB_TABLE)

def _migrate_record_id(conn) -> None:
    """
    Add the record_id column and its index to an existing table.

    Uses INFORMATION_SCHEMA checks so this is safe to call on every startup —
    it is a no-op when the column / index already exist.  Avoids
    ADD COLUMN IF NOT EXISTS / ADD INDEX IF NOT EXISTS, which are MariaDB-only
    syntax and raise a syntax error on MySQL.
    """
    col_exists = conn.execute(text("""
        SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME   = :tbl
          AND COLUMN_NAME  = 'record_id'
    """), {"tbl": DB_TABLE}).scalar()

    if not col_exists:
        conn.execute(text(f"""
            ALTER TABLE `{DB_TABLE}`
                ADD COLUMN `record_id` VARCHAR(255) NOT NULL DEFAULT ''
                    COMMENT 'Caller-supplied unique identifier from parse_single.py'
                    AFTER `id`
        """))

    idx_exists = conn.execute(text("""
        SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME   = :tbl
          AND INDEX_NAME   = 'idx_record_id'
    """), {"tbl": DB_TABLE}).scalar()

    if not idx_exists:
        conn.execute(text(f"""
            ALTER TABLE `{DB_TABLE}` ADD INDEX `idx_record_id` (`record_id`)
        """))


# ---------------------------------------------------------------------------
# Engine (module-level singleton — one connection pool per process)
# ---------------------------------------------------------------------------
_engine = None


def get_engine():
    global _engine
    if _engine is None:
        url = (
            f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}"
            f"@{DB_HOST}:{DB_PORT}/{DB_NAME}?charset=utf8mb4"
        )
        _engine = create_engine(url, pool_pre_ping=True)
    return _engine


def ensure_table_exists():
    """Create tbl_raw_mpesa_statements if it does not already exist,
    and add record_id to tables that predate that column."""
    engine = get_engine()
    with engine.begin() as conn:
        conn.execute(text(_CREATE_TABLE_SQL))
        _migrate_record_id(conn)
    print(f"  DB: table `{DB_TABLE}` is ready")


# ---------------------------------------------------------------------------
# Custom pandas to_sql method — uses INSERT IGNORE for idempotent uploads
# ---------------------------------------------------------------------------
def _insert_ignore(table, conn, keys, data_iter):
    rows = [dict(zip(keys, row)) for row in data_iter]
    stmt = mysql_insert(table.table).prefix_with("IGNORE").values(rows)
    conn.execute(stmt)


def _row_count(engine) -> int:
    with engine.connect() as conn:
        return conn.execute(text(f"SELECT COUNT(*) FROM `{DB_TABLE}`")).scalar()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
def upload_to_mysql(df: pd.DataFrame) -> int:
    """
    Upload *df* to tbl_raw_mpesa_statements.

    - Renames DataFrame columns to their SQL equivalents.
    - Creates the table if it does not exist.
    - Uses INSERT IGNORE so duplicate receipt numbers are silently skipped.

    Returns the number of new rows inserted.
    Raises on any DB error after writing the full traceback to logs/db_errors.log.
    """
    try:
        engine = get_engine()
        ensure_table_exists()

        # Rename + keep only known columns
        df_upload = df.rename(columns=COLUMN_MAP)
        sql_cols = [c for c in COLUMN_MAP.values() if c in df_upload.columns]
        df_upload = df_upload[sql_cols].copy()

        # Coerce Date column to Python date so SQLAlchemy maps it to MySQL DATE
        if "transaction_date" in df_upload.columns:
            df_upload["transaction_date"] = pd.to_datetime(
                df_upload["transaction_date"]
            ).dt.date

        before = _row_count(engine)

        df_upload.to_sql(
            DB_TABLE,
            con=engine,
            if_exists="append",
            index=False,
            method=_insert_ignore,
            chunksize=500,
        )

        after = _row_count(engine)
        inserted = after - before
        skipped = len(df_upload) - inserted
        print(
            f"  DB: {inserted} new row(s) inserted into `{DB_TABLE}`"
            + (f", {skipped} duplicate(s) skipped" if skipped else "")
        )
        return inserted

    except Exception as exc:
        _log_db_error(f"upload_to_mysql failed: {exc}", exc)
        raise
