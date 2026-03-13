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
import json
import os
import shutil
import sys
import uuid
from datetime import datetime, timezone

# ── project root on sys.path ──────────────────────────────────────────────────
ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

from config import FAILED_DIR, LOG_DIR, OUTPUT_DIR  # noqa: E402

# ── queue / lock paths ────────────────────────────────────────────────────────
_QUEUE_ROOT   = os.path.join(ROOT, "queue")
_PENDING_DIR  = os.path.join(_QUEUE_ROOT, "pending")
_DONE_DIR     = os.path.join(_QUEUE_ROOT, "done")
_FAILED_DIR   = os.path.join(_QUEUE_ROOT, "failed")
_LOCK_FILE    = os.path.join(_QUEUE_ROOT, "worker.lock")


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
        "job_id":    job_id,
        "record_id": record_id,
        "file_name": file_name,
        "pdf_path":  os.path.abspath(pdf_path),
        "pin":       pin,
        "queued_at": _utc_now(),
    }

    dest = os.path.join(_PENDING_DIR, f"{job_id}.json")
    tmp  = dest + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(job, fh, indent=2)
    os.replace(tmp, dest)           # atomic on POSIX

    print(f"[queue] enqueued  job_id={job_id}  record_id={record_id}")
    return job_id


def _process_job(job: dict) -> bool:
    """
    Execute a single queued job.  Returns True on success, False on failure.

    Imports are intentionally deferred so that import errors surface as
    per-job failures rather than crashing the whole worker process.
    """
    from parser.mpesa_parser import process_single_file  # noqa: PLC0415

    record_id = job["record_id"]
    pdf_path  = job["pdf_path"]
    file_name = job["file_name"]
    pin       = job["pin"]

    base = os.path.splitext(file_name)[0]
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_csv = os.path.join(OUTPUT_DIR, f"{base}.csv")

    print(
        f"[worker] processing  job_id={job['job_id']}"
        f"  record_id={record_id}  pdf={pdf_path}"
    )
    try:
        result = process_single_file(
            pdf_path=pdf_path,
            output_csv=output_csv,
            password=pin,
            record_id=record_id,
        )
        return result is not None
    except Exception as exc:
        print(f"[worker] ERROR  job_id={job['job_id']}: {exc}", file=sys.stderr)
        return False


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

            success      = _process_job(job)
            archive_dir  = _DONE_DIR if success else _FAILED_DIR
            archive_path = os.path.join(archive_dir, os.path.basename(job_file))
            shutil.move(job_file, archive_path)

            status = "done" if success else "failed"
            print(f"[worker] job_id={job['job_id']} {status}")

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

    if not os.path.isfile(pdf_path):
        print(f"Error: PDF file not found: {pdf_path}", file=sys.stderr)
        sys.exit(1)

    _enqueue(record_id, file_name, pdf_path, pin)
    _run_worker()


if __name__ == "__main__":
    main()
