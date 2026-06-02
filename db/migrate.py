#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
db/migrate.py
-------------
Lightweight SQL migration runner for the M-PESA statement parser.

Each .sql file in db/migrations/ is a numbered migration that is applied
exactly once.  Applied migrations are recorded in the schema_migrations
table so subsequent runs are no-ops for already-applied files.

Usage
-----
Apply all pending migrations (normal startup / CI):
    python db/migrate.py

Show which migrations have been applied and which are still pending:
    python db/migrate.py --status

Mark all migrations as applied WITHOUT running them (run this ONCE on an
existing database that was set up before the migration system existed):
    python db/migrate.py --baseline

Error handling
--------------
Certain MySQL errors indicate that a DDL statement is already in the
desired state and can be safely skipped:
    1060  ER_DUP_FIELDNAME          -- ADD COLUMN on an already-existing column
    1061  ER_DUP_KEYNAME            -- ADD INDEX / ADD KEY on an already-existing key
    1091  ER_CANT_DROP_FIELD_OR_KEY -- DROP INDEX / DROP COLUMN that doesn't exist

This lets migration SQL stay clean and declarative without needing
per-statement conditional guards.
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from typing import List, Optional, Set

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

# ---------------------------------------------------------------------------
# Project root on path so config.py is importable from anywhere
# ---------------------------------------------------------------------------
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD  # noqa: E402

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
MIGRATIONS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "migrations")

# ---------------------------------------------------------------------------
# MySQL error codes that mean "already in desired state" for DDL statements
# ---------------------------------------------------------------------------
_IGNORABLE_ERRORS = {
    1060,  # ER_DUP_FIELDNAME          -- ADD COLUMN: column already exists
    1061,  # ER_DUP_KEYNAME            -- ADD INDEX / ADD KEY: key already exists
    1091,  # ER_CANT_DROP_FIELD_OR_KEY -- DROP INDEX / DROP COLUMN: doesn't exist
}

# ---------------------------------------------------------------------------
# schema_migrations tracking table DDL
# ---------------------------------------------------------------------------
_CREATE_TRACKING_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS `schema_migrations` (
    `id`         BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    `version`    VARCHAR(255)     NOT NULL,
    `applied_at` DATETIME         NOT NULL,
    PRIMARY KEY  (`id`),
    UNIQUE KEY   `uq_version` (`version`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci
  COMMENT='Tracks applied database migrations'
"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _get_engine() -> Engine:
    url = (
        f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}"
        f"@{DB_HOST}:{DB_PORT}/{DB_NAME}?charset=utf8mb4"
    )
    return create_engine(url, pool_pre_ping=True)


def _mysql_error_code(exc: Exception) -> Optional[int]:
    """Return the MySQL numeric error code embedded in *exc*, or None."""
    orig = getattr(exc, "orig", None)
    if orig and hasattr(orig, "args") and orig.args:
        try:
            return int(orig.args[0])
        except (TypeError, ValueError):
            pass
    return None


def _split_statements(sql_text: str) -> List[str]:
    """Split *sql_text* into individual executable statements.

    Strips single-line ``--`` comments then splits on ``;`` that fall outside
    single-quoted string literals (so semicolons inside COMMENT text are safe).
    Does not handle stored-procedure bodies or DELIMITER overrides (those live
    in db/procedures/ and are deployed separately).
    """
    lines = []  # type: List[str]
    for line in sql_text.splitlines():
        if "--" in line:
            line = line[: line.index("--")]
        lines.append(line)
    text = "\n".join(lines)

    statements = []  # type: List[str]
    current = []  # type: List[str]
    in_string = False
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "'" and not in_string:
            in_string = True
            current.append(ch)
        elif ch == "'" and in_string:
            if i + 1 < len(text) and text[i + 1] == "'":
                current.append("''")
                i += 1
            else:
                in_string = False
                current.append(ch)
        elif ch == ";" and not in_string:
            stmt = "".join(current).strip()
            if stmt:
                statements.append(stmt)
            current = []
        else:
            current.append(ch)
        i += 1

    stmt = "".join(current).strip()
    if stmt:
        statements.append(stmt)
    return statements


def _migration_files() -> List[str]:
    """Return sorted list of .sql filenames from the migrations directory."""
    if not os.path.isdir(MIGRATIONS_DIR):
        return []
    return sorted(
        f
        for f in os.listdir(MIGRATIONS_DIR)
        if f.endswith(".sql") and f[0].isdigit()
    )


def _applied_versions(conn) -> Set[str]:
    rows = conn.execute(text("SELECT version FROM schema_migrations")).fetchall()
    return {row[0] for row in rows}


def _is_applied(engine, version):
    # type: (Engine, str) -> bool
    with engine.connect() as conn:
        count = conn.execute(
            text("SELECT COUNT(*) FROM schema_migrations WHERE version = :v"),
            {"v": version},
        ).scalar()
    return bool(count)


def _apply_migration(conn, version, filepath):
    # type: (object, str, str) -> None
    """Execute every statement in *filepath* then record *version* as applied."""
    with open(filepath, "r", encoding="utf-8") as fh:
        content = fh.read()

    for stmt in _split_statements(content):
        try:
            conn.execute(text(stmt))
        except Exception as exc:
            if _mysql_error_code(exc) in _IGNORABLE_ERRORS:
                continue  # already in desired state -- skip silently
            raise

    conn.execute(
        text(
            "INSERT INTO schema_migrations (version, applied_at) "
            "VALUES (:v, :at)"
        ),
        {"v": version, "at": datetime.now(timezone.utc).replace(tzinfo=None)},
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def run_migrations(engine=None):
    # type: (Optional[Engine]) -> int
    """Apply all pending migrations in order.

    Parameters
    ----------
    engine:
        An existing SQLAlchemy engine.  When None a new engine is created
        from the values in config.py.

    Returns
    -------
    int
        Number of migrations applied in this call.
    """
    if engine is None:
        engine = _get_engine()

    # Ensure tracking table exists
    with engine.begin() as conn:
        conn.execute(text(_CREATE_TRACKING_TABLE_SQL))

    files = _migration_files()
    count = 0

    for filename in files:
        version = filename[:-4]  # strip .sql

        if _is_applied(engine, version):
            continue

        filepath = os.path.join(MIGRATIONS_DIR, filename)
        with engine.begin() as conn:
            _apply_migration(conn, version, filepath)

        print("  Migrations: [ok] %s" % version)
        count += 1

    if count == 0:
        print("  Migrations: all up to date")
    else:
        print("  Migrations: %d migration(s) applied" % count)

    return count


# ---------------------------------------------------------------------------
# CLI commands
# ---------------------------------------------------------------------------

def _cmd_status(engine):
    # type: (Engine) -> None
    """Print a table showing applied vs pending migrations."""
    with engine.begin() as conn:
        conn.execute(text(_CREATE_TRACKING_TABLE_SQL))
        applied = _applied_versions(conn)

    files = _migration_files()
    col = max((len(f[:-4]) for f in files), default=20)

    print("  %-10s  VERSION" % "STATUS")
    print("  %s  %s" % ("-" * 10, "-" * col))
    for filename in files:
        version = filename[:-4]
        status = "applied" if version in applied else "PENDING"
        marker = "[ok]" if version in applied else "[  ]"
        print("  %s %-9s  %s" % (marker, status, version))

    pending = sum(1 for f in files if f[:-4] not in applied)
    print("")
    print("  %d applied   %d pending" % (len(applied), pending))


def _cmd_baseline(engine):
    # type: (Engine) -> None
    """Mark every migration file as applied without executing its SQL.

    Use this once on a database that was created before the migration system
    was introduced, so the runner can track future changes from a known state.
    """
    with engine.begin() as conn:
        conn.execute(text(_CREATE_TRACKING_TABLE_SQL))
        applied = _applied_versions(conn)

    files = _migration_files()
    count = 0

    for filename in files:
        version = filename[:-4]
        if version in applied:
            print("  Baseline: (already tracked)  %s" % version)
            continue

        with engine.begin() as conn:
            conn.execute(
                text(
                    "INSERT INTO schema_migrations (version, applied_at) "
                    "VALUES (:v, :at)"
                ),
                {"v": version, "at": datetime.now(timezone.utc).replace(tzinfo=None)},
            )
        print("  Baseline: [ok] registered  %s" % version)
        count += 1

    print("")
    print("  Baseline complete -- %d migration(s) registered." % count)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="M-PESA parser database migration runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  python db/migrate.py              # apply all pending migrations
  python db/migrate.py --status     # show applied / pending migrations
  python db/migrate.py --baseline   # register existing DB (run once on legacy installs)
""",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--status",
        action="store_true",
        help="show which migrations have been applied and which are pending",
    )
    group.add_argument(
        "--baseline",
        action="store_true",
        help="mark all migrations as applied without running them (legacy installs)",
    )
    args = parser.parse_args()

    _engine = _get_engine()

    if args.status:
        _cmd_status(_engine)
    elif args.baseline:
        _cmd_baseline(_engine)
    else:
        run_migrations(_engine)
