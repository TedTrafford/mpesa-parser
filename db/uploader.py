#!/usr/bin/env python3
"""
db/uploader.py
--------------
Handles uploading a parsed M-PESA DataFrame to `tbl_raw_mpesa_statements`
and writing processing audit logs to `tbl_file_processing_logs`.

Schema management (table creation, column additions, data migrations) is
handled entirely by db/migrate.py.  Call ensure_table_exists() once at
startup to apply any pending migrations and deploy the fly_profiling
stored procedure.

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
from config import (
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_TABLE, DB_LOGS_TABLE,
    LOG_DIR, MYSQL_CONNECT_ARGS,
)

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




def deploy_procedures() -> None:
    """Redeploy every .sql procedure body in db/procedures/ (excludes *_drop.sql)."""
    engine = get_engine()
    with engine.begin() as conn:
        _deploy_all_procedures(conn)


def ensure_table_exists() -> None:
    """Apply all pending database migrations and deploy the fly_profiling procedure.

    Safe to call on every startup — migrations are tracked in schema_migrations
    and each runs exactly once.  Subsequent calls are no-ops.
    """
    _db_dir = os.path.dirname(os.path.abspath(__file__))
    if _db_dir not in sys.path:
        sys.path.insert(0, _db_dir)
    from migrate import run_migrations  # db/migrate.py

    engine = get_engine()
    run_migrations(engine)
    deploy_procedures()

# ---------------------------------------------------------------------------
# Custom pandas to_sql method — INSERT IGNORE so duplicate receipt_no rows
# are silently skipped (aids duplicate and fraud identification).
# ---------------------------------------------------------------------------


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
        _engine = create_engine(
            url, pool_pre_ping=True, connect_args=MYSQL_CONNECT_ARGS
        )
    return _engine


_PROCEDURES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "db", "procedures",
)


def _deploy_all_procedures(conn) -> None:
    """Read every .sql file in db/procedures/ and (re)create each stored procedure.

    For each file the deployer:
      - Strips the DEFINER clause so the caller does not need SUPER / SET_USER_ID.
      - Strips any database-schema qualifier from the CREATE PROCEDURE line so the
        procedure is always created in the current database.
      - Extracts the procedure name from the CREATE PROCEDURE statement.
      - Issues DROP PROCEDURE IF EXISTS + CREATE PROCEDURE (idempotent).

    Adding a new .sql file to db/procedures/ and restarting the app is all that
    is needed to deploy a new stored procedure.
    """
    if not os.path.isdir(_PROCEDURES_DIR):
        print("  DB: procedures directory not found — skipping procedure deployment")
        return

    sql_files = sorted(
        f
        for f in os.listdir(_PROCEDURES_DIR)
        if f.endswith(".sql") and not f.endswith("_drop.sql")
    )
    if not sql_files:
        print("  DB: no procedure files found in db/procedures/")
        return

    for filename in sql_files:
        sql_path = os.path.join(_PROCEDURES_DIR, filename)
        with open(sql_path, "r", encoding="utf-8", errors="replace") as fh:
            proc_sql = fh.read().strip()

        # Strip client-only delimiter directives (DBeaver -- @delimiter / mysql
        # DELIMITER).  The MySQL wire protocol does not understand them; detect
        # the custom terminator (e.g. $$), remove directive lines, then strip
        # the trailing custom terminator so CREATE PROCEDURE...END is one statement.
        _delim_match = re.search(
            r"^\s*(?:--\s*@delimiter|DELIMITER)\s+(\S+)\s*$",
            proc_sql,
            re.IGNORECASE | re.MULTILINE,
        )
        if _delim_match:
            _custom_delim = re.escape(_delim_match.group(1))
            proc_sql = re.sub(
                r"^\s*(?:--\s*@delimiter|DELIMITER)\s+\S+\s*$",
                "",
                proc_sql,
                flags=re.IGNORECASE | re.MULTILINE,
            )
            proc_sql = re.sub(_custom_delim + r"\s*$", "", proc_sql.rstrip())

        # Strip any standalone DROP PROCEDURE statement.  The .sql files carry
        # one so they paste cleanly into clients like DBeaver, but the deployer
        # issues its own DROP below.  Leaving it would make proc_sql a
        # multi-statement string, which the DB driver rejects.
        proc_sql = re.sub(
            r"^\s*DROP\s+PROCEDURE\s+(?:IF\s+EXISTS\s+)?[^;]+;\s*",
            "",
            proc_sql,
            flags=re.IGNORECASE | re.MULTILINE,
        )

        # Strip DEFINER clause.
        proc_sql = re.sub(
            r"DEFINER\s*=\s*`[^`]+`@`[^`]+`\s*",
            "",
            proc_sql,
            flags=re.IGNORECASE,
        )

        # Strip database-schema qualifier from the procedure name.
        proc_sql = re.sub(
            r"(CREATE\s+PROCEDURE\s+)`[^`]+`\.",
            r"\1",
            proc_sql,
            flags=re.IGNORECASE,
        )

        # Extract procedure name from CREATE PROCEDURE line.
        m = re.search(r"CREATE\s+PROCEDURE\s+`([^`]+)`", proc_sql, re.IGNORECASE)
        if not m:
            print(f"  DB: could not parse procedure name from {filename} — skipping")
            continue
        proc_name = m.group(1)

        conn.execute(text(f"DROP PROCEDURE IF EXISTS `{proc_name}`"))
        conn.execute(text(proc_sql))
        print(f"  DB: procedure `{proc_name}` deployed")




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
    `status`            VARCHAR(20)      NOT NULL DEFAULT '',
    `profiling_status`  VARCHAR(255)     NOT NULL DEFAULT '',
    `phone_match`            VARCHAR(10)      NOT NULL DEFAULT '',
    `balance_check_pct`      DECIMAL(5, 2)    DEFAULT NULL,
    `supplied_phone_number`  VARCHAR(20)      NOT NULL DEFAULT '',
    `extracted_phone_number` VARCHAR(20)      NOT NULL DEFAULT '',
    `error`                  TEXT             NOT NULL,
    PRIMARY KEY (`id`),
    INDEX `idx_log_record_id`  (`record_id`),
    INDEX `idx_log_status`     (`status`),
    INDEX `idx_log_filename`   (`filename`),
    INDEX `idx_log_start_time` (`start_time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='File processing audit log for M-PESA PDF parsing jobs'
""".format(table=DB_LOGS_TABLE)


def _ensure_logs_table_exists(conn) -> None:
    """Ensure tbl_file_processing_logs exists with the current schema.

    Uses CREATE TABLE IF NOT EXISTS so it is safe to call on every startup.
    Column additions are handled by db/migrations/ (run via ensure_table_exists).
    """
    conn.execute(text(_CREATE_LOGS_TABLE_SQL))


def insert_processing_log(entry: dict) -> None:
    """Insert one row into tbl_file_processing_logs.

    *entry* uses the same keys produced by the ``_write_log`` helpers in
    ``parse_single.py`` and ``process_all_pdfs.py``:

        filename, md5, manifest_hash, source, source_path, destination,
        record_id, rows_inserted, rows_skipped,
        start_timestamp, end_timestamp,   ← "%Y-%m-%d %H:%M:%S" strings
        status, profiling_status, phone_match, balance_check_pct,
        supplied_phone_number, extracted_phone_number, error
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
        "status":             entry.get("status",             ""),
        "profiling_status":  entry.get("profiling_status",  ""),
        "phone_match":             entry.get("phone_match",             ""),
        "balance_check_pct":       entry.get("balance_check_pct"),        # None → SQL NULL
        "supplied_phone_number":   entry.get("supplied_phone_number",     ""),
        "extracted_phone_number":  entry.get("extracted_phone_number",    ""),
        "error":                   entry.get("error",                     "") or "",
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
                         status, profiling_status, phone_match, balance_check_pct,
                         supplied_phone_number, extracted_phone_number, error)
                    VALUES
                        (:filename, :md5, :manifest_hash, :source, :source_path,
                         :destination, :record_id, :rows_inserted, :rows_skipped,
                         :start_time, :end_time, :duration_seconds,
                         :status, :profiling_status, :phone_match, :balance_check_pct,
                         :supplied_phone_number, :extracted_phone_number, :error)
                """),
                row,
            )
        print(f"  DB: processing log written to `{DB_LOGS_TABLE}`")
    except Exception as exc:
        _log_db_error(f"insert_processing_log failed: {exc}", exc)
