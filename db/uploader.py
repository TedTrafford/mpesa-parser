#!/usr/bin/env python3
"""
db/uploader.py
--------------
Handles creating the MySQL table (if it does not exist) and uploading a
parsed M-PESA DataFrame to `tbl_raw_mpesa_statements`.

Duplicate rows are silently skipped thanks to INSERT IGNORE — re-running the
parser against the same PDF will not create duplicate records, and skipped
rows are preserved for duplicate and fraud identification.
"""

import json
import os
import re
import sys
import traceback
from collections import namedtuple
from datetime import datetime, timezone
import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.dialects.mysql import insert as mysql_insert

UploadResult = namedtuple("UploadResult", ["inserted", "skipped", "manifest_hash"])

# Allow imports from the project root
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_TABLE, DB_LOGS_TABLE, LOG_DIR

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
    UNIQUE KEY  `uq_receipt_amount`    (`receipt_no`, `amount`),
    INDEX       `idx_record_id`        (`record_id`),
    INDEX       `idx_mobile_number`    (`mobile_number`),
    INDEX       `idx_transaction_date` (`transaction_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Raw M-PESA statement transactions parsed from PDF files'
""".format(table=DB_TABLE)

def _migrate_unique_key(conn) -> None:
    """
    Replace the old single-column unique key on receipt_no with a composite
    key on (receipt_no, amount).

    This allows M-PESA service charges to be stored alongside their parent
    transactions — both rows share a receipt_no but carry different amounts,
    so they are NOT duplicates.  True duplicates (identical receipt_no AND
    amount) are still blocked by INSERT IGNORE.
    """
    # Check whether the old single-column key still exists
    old_key_exists = conn.execute(text("""
        SELECT COUNT(*) FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA    = DATABASE()
          AND TABLE_NAME      = :tbl
          AND CONSTRAINT_NAME = 'uq_receipt_no'
          AND COLUMN_NAME     = 'receipt_no'
    """), {"tbl": DB_TABLE}).scalar()

    if old_key_exists:
        conn.execute(text(
            f"ALTER TABLE `{DB_TABLE}` DROP INDEX `uq_receipt_no`"
        ))

    # Add the composite key if it does not yet exist
    new_key_exists = conn.execute(text("""
        SELECT COUNT(*) FROM INFORMATION_SCHEMA.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME   = :tbl
          AND INDEX_NAME   = 'uq_receipt_amount'
    """), {"tbl": DB_TABLE}).scalar()

    if not new_key_exists:
        conn.execute(text(
            f"ALTER TABLE `{DB_TABLE}` "
            f"ADD UNIQUE KEY `uq_receipt_amount` (`receipt_no`, `amount`)"
        ))


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


_PROCEDURES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "db", "procedures",
)


def _deploy_fly_profiling_procedure(conn) -> None:
    """Read db/procedures/fly_profiling.sql and (re)create the stored procedure.

    The DEFINER clause is stripped so the deploying DB user does not need
    SUPER / SET_USER_ID privilege.  The DROP + CREATE pair is idempotent —
    safe to call on every startup.  Edit fly_profiling.sql and restart the
    app to pick up changes automatically.
    """
    sql_path = os.path.join(_PROCEDURES_DIR, "fly_profiling.sql")
    if not os.path.exists(sql_path):
        print("  DB: fly_profiling.sql not found — skipping procedure deployment")
        return

    with open(sql_path, "r", encoding="utf-8") as fh:
        proc_sql = fh.read().strip()

    # Strip DEFINER clause — MySQL rejects it unless the caller has
    # SUPER or SET_USER_ID; the procedure will be owned by the session user.
    proc_sql = re.sub(
        r"DEFINER\s*=\s*`[^`]+`@`[^`]+`\s*",
        "",
        proc_sql,
        flags=re.IGNORECASE,
    )

    conn.execute(text("DROP PROCEDURE IF EXISTS `fly_profiling`"))
    conn.execute(text(proc_sql))
    print("  DB: procedure `fly_profiling` deployed")


def ensure_table_exists():
    """Create tbl_raw_mpesa_statements if it does not already exist,
    and run any pending schema migrations including procedure deployment."""
    engine = get_engine()
    with engine.begin() as conn:
        conn.execute(text(_CREATE_TABLE_SQL))
        _migrate_record_id(conn)
        _migrate_unique_key(conn)
        _deploy_fly_profiling_procedure(conn)
    print(f"  DB: table `{DB_TABLE}` is ready")


# ---------------------------------------------------------------------------
# Custom pandas to_sql method — INSERT IGNORE so duplicate receipt_no rows
# are silently skipped (aids duplicate and fraud identification).
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
def upload_to_mysql(df: pd.DataFrame) -> UploadResult:
    """
    Upload *df* to tbl_raw_mpesa_statements.

    - Renames DataFrame columns to their SQL equivalents.
    - Creates the table if it does not exist.
    - Uses INSERT IGNORE so duplicate receipt numbers are silently skipped,
      preserving them for duplicate and fraud identification.

    Returns an UploadResult(inserted, skipped, manifest_hash).
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

        # Extract manifest_hash from the metadata column for logging
        manifest_hash = ""
        if "metadata" in df_upload.columns and len(df_upload) > 0:
            try:
                manifest_hash = json.loads(df_upload["metadata"].iloc[0]).get(
                    "manifest_hash", ""
                )
            except (ValueError, KeyError, TypeError):
                pass

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
        return UploadResult(inserted=inserted, skipped=skipped, manifest_hash=manifest_hash)

    except Exception as exc:
        _log_db_error(f"upload_to_mysql failed: {exc}", exc)
        raise


# ---------------------------------------------------------------------------
# Processing-log table
# ---------------------------------------------------------------------------
_CREATE_LOGS_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS `{table}` (
    `id`               BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `filename`         VARCHAR(255)     NOT NULL DEFAULT '',
    `md5`              VARCHAR(32)      NOT NULL DEFAULT '',
    `manifest_hash`    VARCHAR(32)      NOT NULL DEFAULT '',
    `source`           VARCHAR(100)     NOT NULL DEFAULT '',
    `source_path`      TEXT             NOT NULL,
    `destination`      TEXT             NOT NULL,
    `record_id`        VARCHAR(255)     NOT NULL DEFAULT '',
    `rows_inserted`    INT              NOT NULL DEFAULT 0,
    `rows_skipped`     INT              NOT NULL DEFAULT 0,
    `start_time`       DATETIME         NOT NULL,
    `end_time`         DATETIME         NOT NULL,
    `duration_seconds` DECIMAL(10, 2)   NOT NULL DEFAULT 0.00,
    `status`           VARCHAR(20)      NOT NULL DEFAULT '',
    `profiling_status` VARCHAR(255)     NOT NULL DEFAULT '',
    `error`            TEXT             NOT NULL,
    PRIMARY KEY (`id`),
    INDEX `idx_log_record_id`  (`record_id`),
    INDEX `idx_log_status`     (`status`),
    INDEX `idx_log_filename`   (`filename`),
    INDEX `idx_log_start_time` (`start_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='File processing audit log for M-PESA PDF parsing jobs'
""".format(table=DB_LOGS_TABLE)


def _migrate_profiling_status_column(conn) -> None:
    """Add profiling_status column to tbl_file_processing_logs on existing tables.

    Safe to call on every startup — no-op when the column already exists.
    """
    col_exists = conn.execute(text("""
        SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME   = :tbl
          AND COLUMN_NAME  = 'profiling_status'
    """), {"tbl": DB_LOGS_TABLE}).scalar()

    if not col_exists:
        conn.execute(text(f"""
            ALTER TABLE `{DB_LOGS_TABLE}`
                ADD COLUMN `profiling_status` VARCHAR(255) NOT NULL DEFAULT ''
                    AFTER `status`
        """))


def _ensure_logs_table_exists(conn) -> None:
    conn.execute(text(_CREATE_LOGS_TABLE_SQL))
    _migrate_profiling_status_column(conn)


def insert_processing_log(entry: dict) -> None:
    """Insert one row into tbl_file_processing_logs.

    *entry* uses the same keys produced by the ``_write_log`` helpers in
    ``parse_single.py`` and ``process_all_pdfs.py``:

        filename, md5, manifest_hash, source, source_path, destination,
        record_id, rows_inserted, rows_skipped,
        start_timestamp, end_timestamp,   ← "%Y-%m-%d %H:%M:%S" strings
        status, profiling_status, error
    """
    _fmt = "%Y-%m-%d %H:%M:%S"

    def _to_dt(val):
        if isinstance(val, datetime):
            return val
        try:
            return datetime.strptime(str(val).strip(), _fmt)
        except (ValueError, TypeError):
            return datetime.now(timezone.utc).replace(tzinfo=None)

    start_dt = _to_dt(entry.get("start_timestamp", ""))
    end_dt   = _to_dt(entry.get("end_timestamp",   ""))
    duration = (end_dt - start_dt).total_seconds()

    def _int(val):
        try:
            return int(val)
        except (TypeError, ValueError):
            return 0

    row = {
        "filename":          entry.get("filename",          ""),
        "md5":               entry.get("md5",               ""),
        "manifest_hash":     entry.get("manifest_hash",     ""),
        "source":            entry.get("source",            ""),
        "source_path":       entry.get("source_path",       ""),
        "destination":       entry.get("destination",       ""),
        "record_id":         entry.get("record_id",         ""),
        "rows_inserted":     _int(entry.get("rows_inserted", 0)),
        "rows_skipped":      _int(entry.get("rows_skipped",  0)),
        "start_time":        start_dt,
        "end_time":          end_dt,
        "duration_seconds":  round(duration, 2),
        "status":            entry.get("status",            ""),
        "profiling_status":  entry.get("profiling_status",  ""),
        "error":             entry.get("error",             "") or "",
    }

    try:
        engine = get_engine()
        with engine.begin() as conn:
            _ensure_logs_table_exists(conn)
            conn.execute(
                text(f"""
                    INSERT INTO `{DB_LOGS_TABLE}`
                        (filename, md5, manifest_hash, source, source_path,
                         destination, record_id, rows_inserted, rows_skipped,
                         start_time, end_time, duration_seconds,
                         status, profiling_status, error)
                    VALUES
                        (:filename, :md5, :manifest_hash, :source, :source_path,
                         :destination, :record_id, :rows_inserted, :rows_skipped,
                         :start_time, :end_time, :duration_seconds,
                         :status, :profiling_status, :error)
                """),
                row,
            )
        print(f"  DB: processing log written to `{DB_LOGS_TABLE}`")
    except Exception as exc:
        _log_db_error(f"insert_processing_log failed: {exc}", exc)
