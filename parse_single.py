#!/usr/bin/env python3
"""
parse_single.py
---------------
Enqueue a single M-PESA PDF parse request and run it through a serialised
worker backed by a file-based queue.

Multiple callers may invoke this script concurrently.  Each call atomically
writes one job file to the queue directory.  An advisory flock on a lock file
ensures that only one worker processes jobs at a time; a concurrent caller
that loses the lock race simply exits after enqueuing — the running worker
will pick up the new job automatically in the same drain loop.

Usage
-----
    python parse_single.py <record_id> <file_name> <pdf_path> <pin>

Arguments
---------
    record_id   Caller-supplied unique identifier for this parse request.
                Stored as ``record_id`` inside the ``metadata`` JSON column
                of every transaction row produced by the parse.

    file_name   Original PDF filename (e.g. ``310549.pdf``).  Used to derive
                the output CSV name — the ``.pdf`` extension is swapped for
                ``.csv`` and the file is written to OUTPUT_DIR.

    pdf_path    Absolute or relative path to the PDF file to parse.

    pin         PDF password used to decrypt the M-PESA statement.

Exit codes
----------
    0   Job enqueued (and processed if this call won the worker lock).
    1   Bad arguments or PDF file not found.
"""

import fcntl
import glob
import hashlib
import json
import os
import re
import shutil
import sys
import uuid
from datetime import datetime, timezone

from dateutil.relativedelta import relativedelta

# ── project root on sys.path ──────────────────────────────────────────────────
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

from config import FAILED_DIR, LOG_DIR, OUTPUT_DIR  # noqa: E402
from db.uploader import get_engine, insert_processing_log  # noqa: E402

# ── queue / lock paths ────────────────────────────────────────────────────────
_QUEUE_ROOT   = os.path.join(ROOT, "queue")
_PENDING_DIR  = os.path.join(_QUEUE_ROOT, "pending")
_DONE_DIR     = os.path.join(_QUEUE_ROOT, "done")
_FAILED_DIR   = os.path.join(_QUEUE_ROOT, "failed")
_LOCK_FILE    = os.path.join(_QUEUE_ROOT, "worker.lock")

# ── logging ───────────────────────────────────────────────────────────────────
_LOG_FILE         = os.path.join(LOG_DIR, "processing_log.log")
_SEPARATOR        = "-" * 60
_RETENTION_YEARS  = 3


def _compute_md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def _write_log(entry: dict) -> None:
    """Append one log block and prune entries older than _RETENTION_YEARS.

    Extended fields compared to process_all_pdfs.py:
        source        — always 'parse_single.py'
        source_path   — absolute path to the input PDF
        destination   — absolute path to the output CSV
        record_id     — caller-supplied unique identifier
        manifest_hash — MD5 of (filename bytes + file content bytes)
        rows_inserted — number of new rows written to the DB
        rows_skipped  — number of rows silently ignored (receipt_no already exists)
    """
    os.makedirs(LOG_DIR, exist_ok=True)

    try:
        start_dt = datetime.strptime(entry["start_timestamp"], "%Y-%m-%d %H:%M:%S")
        end_dt   = datetime.strptime(entry["end_timestamp"],   "%Y-%m-%d %H:%M:%S")
        duration = f"{(end_dt - start_dt).total_seconds():.2f}s"
    except ValueError:
        duration = "N/A"

    rows_inserted = entry.get("rows_inserted", "")
    rows_skipped  = entry.get("rows_skipped",  "")
    manifest_hash = entry.get("manifest_hash", "")

    new_block = (
        f"filename      : {entry['filename']}\n"
        f"md5           : {entry['md5']}\n"
        f"manifest_hash : {manifest_hash}\n"
        f"source        : parse_single.py\n"
        f"source_path   : {entry['source_path']}\n"
        f"destination   : {entry['destination']}\n"
        f"record_id     : {entry['record_id']}\n"
        f"rows_inserted : {rows_inserted}\n"
        f"rows_skipped  : {rows_skipped}\n"
        f"start         : {entry['start_timestamp']}\n"
        f"end           : {entry['end_timestamp']}\n"
        f"duration      : {duration}\n"
        f"status        : {entry['status']}\n"
        f"error         : {entry['error']}"
    )

    cutoff = datetime.now() - relativedelta(years=_RETENTION_YEARS)
    kept_blocks = []

    if os.path.exists(_LOG_FILE):
        with open(_LOG_FILE, "r") as fh:
            raw = fh.read()
        for block in raw.split(_SEPARATOR):
            block = block.strip()
            if not block:
                continue
            match = re.search(r"^start\s*:\s*(.+)$", block, re.MULTILINE)
            if match:
                try:
                    ts = datetime.strptime(match.group(1).strip(), "%Y-%m-%d %H:%M:%S")
                    if ts >= cutoff:
                        kept_blocks.append(block)
                except ValueError:
                    kept_blocks.append(block)
            else:
                kept_blocks.append(block)

    kept_blocks.append(new_block)

    with open(_LOG_FILE, "w") as fh:
        fh.write(f"\n{_SEPARATOR}\n".join(kept_blocks))
        fh.write(f"\n{_SEPARATOR}\n")


# ── helpers ───────────────────────────────────────────────────────────────────

def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _enqueue(record_id: str, file_name: str, pdf_path: str, pin: str) -> str:
    """
    Write a job descriptor to the pending queue and return the job_id.

    The job file is written via a temp-file + atomic rename so a worker
    scanning the directory never sees a half-written file.
    """
    os.makedirs(_PENDING_DIR, exist_ok=True)

    job_id = str(uuid.uuid4())
    job = {
        "job_id":               job_id,
        "record_id":            record_id,
        "file_name":            file_name,
        "pdf_path":             pdf_path,
        "pin":                  pin,
        "status":               "queued",
        "queued_at":            _utc_now(),
        "processing_started_at": None,
        "completed_at":         None,
        "error":                None,
    }

    dest = os.path.join(_PENDING_DIR, f"{job_id}.json")
    tmp  = dest + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(job, fh, indent=2)
    os.replace(tmp, dest)           # atomic on POSIX

    print(f"[queue] status=queued  job_id={job_id}  record_id={record_id}")
    return job_id


def _update_job_file(job_file: str, **fields) -> dict:
    """Read the job JSON at *job_file*, merge *fields*, write back atomically.

    Returns the updated job dict.
    """
    with open(job_file) as fh:
        job = json.load(fh)
    job.update(fields)
    tmp = job_file + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(job, fh, indent=2)
    os.replace(tmp, job_file)
    return job


def call_fly_profiling(mobile_number: str) -> None:
    """Execute CALL fly_profiling('<mobile_number>') against the configured DB.

    The procedure is deployed automatically at startup via the migration in
    db/uploader.ensure_table_exists().  Call this function explicitly when
    you need to trigger profiling for a specific subscriber — it is no longer
    invoked automatically after every parse job.

    Errors are printed but do not propagate.
    """
    from sqlalchemy import text  # noqa: PLC0415

    if not mobile_number:
        print("[profiling] skipped — mobile number is empty", file=sys.stderr)
        return

    try:
        engine = get_engine()
        with engine.begin() as conn:
            conn.execute(text("CALL fly_profiling(:phone)"), {"phone": mobile_number})
        print(f"[profiling] fly_profiling('{mobile_number}') completed")
    except Exception as exc:
        print(
            f"[profiling] WARNING: fly_profiling('{mobile_number}') failed: {exc}",
            file=sys.stderr,
        )


def _process_job(job: dict) -> tuple:
    """Execute a single queued job.

    Returns ``(success: bool, error_msg: str)``.

    Imports are intentionally deferred so that import errors surface as
    per-job failures rather than crashing the whole worker process.
    """
    from parser.mpesa_parser import process_single_file  # noqa: PLC0415

    record_id  = job["record_id"]
    pdf_path   = job["pdf_path"]
    file_name  = job["file_name"]
    pin        = job["pin"]

    base = os.path.splitext(file_name)[0]
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_csv = os.path.join(OUTPUT_DIR, f"{base}.csv")

    file_md5 = _compute_md5(pdf_path)
    start_ts = datetime.now()

    try:
        result  = process_single_file(
            pdf_path=pdf_path,
            output_csv=output_csv,
            password=pin,
            record_id=record_id,
        )
        end_ts        = datetime.now()
        success       = result is not None
        upload        = result.attrs.get("upload_result") if success else None
        rows_inserted = upload.inserted      if upload else ""
        rows_skipped  = upload.skipped       if upload else ""
        manifest_hash = upload.manifest_hash if upload else ""

        if not success:
            status = "FAILED"
            error  = "process_single_file returned None"
        elif upload and upload.inserted == 0 and upload.skipped > 0:
            status = "SKIPPED"
            error  = (
                f"{upload.skipped} row(s) already exist in the database "
                f"(receipt_no conflict — possible duplicate submission)"
            )
        else:
            status = "SUCCESS"
            error  = ""

        log_entry = {
            "filename":        file_name,
            "md5":             file_md5,
            "manifest_hash":   manifest_hash,
            "source":          "parse_single.py",
            "source_path":     os.path.abspath(pdf_path),
            "destination":     os.path.abspath(output_csv),
            "record_id":       record_id,
            "rows_inserted":   rows_inserted,
            "rows_skipped":    rows_skipped,
            "start_timestamp": start_ts.strftime("%Y-%m-%d %H:%M:%S"),
            "end_timestamp":   end_ts.strftime("%Y-%m-%d %H:%M:%S"),
            "status":          status,
            "error":           error,
        }
        _write_log(log_entry)
        insert_processing_log(log_entry)

        return success, error

    except Exception as exc:
        end_ts    = datetime.now()
        error_msg = str(exc)[:500].replace("\n", " ")
        print(f"[worker] ERROR  job_id={job['job_id']}: {exc}", file=sys.stderr)
        log_entry = {
            "filename":        file_name,
            "md5":             file_md5,
            "manifest_hash":   "",
            "source":          "parse_single.py",
            "source_path":     os.path.abspath(pdf_path),
            "destination":     os.path.abspath(output_csv),
            "record_id":       record_id,
            "rows_inserted":   "",
            "rows_skipped":    "",
            "start_timestamp": start_ts.strftime("%Y-%m-%d %H:%M:%S"),
            "end_timestamp":   end_ts.strftime("%Y-%m-%d %H:%M:%S"),
            "status":          "FAILED",
            "error":           error_msg,
        }
        _write_log(log_entry)
        insert_processing_log(log_entry)
        return False, error_msg


def _run_worker() -> None:
    """
    Acquire the advisory flock and drain the pending queue sequentially.

    If another worker already holds the lock this function returns
    immediately — the running worker will process any newly enqueued jobs
    in its own drain loop before it releases the lock.
    """
    for d in (_DONE_DIR, _FAILED_DIR):
        os.makedirs(d, exist_ok=True)

    lock_fh = open(_LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(
            "[worker] another worker is already running — "
            "job will be processed in turn"
        )
        lock_fh.close()
        return

    print("[worker] lock acquired — draining queue")
    try:
        while True:
            pending = sorted(glob.glob(os.path.join(_PENDING_DIR, "*.json")))
            if not pending:
                break

            job_file = pending[0]
            try:
                with open(job_file) as fh:
                    job = json.load(fh)
            except (OSError, json.JSONDecodeError) as exc:
                print(f"[worker] could not read job file {job_file}: {exc}", file=sys.stderr)
                os.remove(job_file)
                continue

            # ── processing ────────────────────────────────────────────────────
            job = _update_job_file(
                job_file,
                status="processing",
                processing_started_at=_utc_now(),
            )
            print(
                f"[worker] status=processing  job_id={job['job_id']}"
                f"  record_id={job['record_id']}  pdf={job['pdf_path']}"
            )

            success, error_msg = _process_job(job)

            # ── final status ──────────────────────────────────────────────────
            final_status = "success" if success else "failed"
            job = _update_job_file(
                job_file,
                status=final_status,
                completed_at=_utc_now(),
                error=error_msg or None,
            )
            print(f"[worker] status={final_status}  job_id={job['job_id']}")

            archive_dir  = _DONE_DIR if success else _FAILED_DIR
            archive_path = os.path.join(archive_dir, os.path.basename(job_file))
            shutil.move(job_file, archive_path)

    finally:
        fcntl.flock(lock_fh, fcntl.LOCK_UN)
        lock_fh.close()
        print("[worker] lock released")


# ── entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)

    _, record_id, file_name, pdf_path, pin = sys.argv

    # Guard against callers that strip the leading slash from an absolute path.
    # os.path.abspath() would otherwise prepend CWD and produce a doubled path
    # (e.g. /srv/app/var/www/host/storage/…).
    if not os.path.isabs(pdf_path):
        pdf_path = os.sep + pdf_path

    if not os.path.isfile(pdf_path):
        print(f"Error: PDF file not found: {pdf_path}", file=sys.stderr)
        sys.exit(1)

    _enqueue(record_id, file_name, pdf_path, pin)
    _run_worker()


if __name__ == "__main__":
    main()
