#!/usr/bin/env python3

import os
import sys
import glob
import shutil
import re
import hashlib
from datetime import datetime
from dateutil.relativedelta import relativedelta
from config import INPUT_DIR, OUTPUT_DIR, FAILED_DIR, LOG_DIR

LOG_FILE = os.path.join(LOG_DIR, "processing_log.log")
_SEPARATOR = "-" * 60
_RETENTION_YEARS = 3


def _compute_md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def _write_log(entry):
    """Append a log entry and prune records older than _RETENTION_YEARS."""
    os.makedirs(LOG_DIR, exist_ok=True)

    try:
        start_dt = datetime.strptime(entry['start_timestamp'], "%Y-%m-%d %H:%M:%S")
        end_dt   = datetime.strptime(entry['end_timestamp'],   "%Y-%m-%d %H:%M:%S")
        duration = f"{(end_dt - start_dt).total_seconds():.2f}s"
    except ValueError:
        duration = "N/A"

    new_block = (
        f"filename      : {entry['filename']}\n"
        f"md5           : {entry['md5']}\n"
        f"manifest_hash : {entry.get('manifest_hash', '')}\n"
        f"source        : {entry.get('source', 'process_all_pdfs.py')}\n"
        f"source_path   : {entry.get('source_path', '')}\n"
        f"destination   : {entry.get('destination', '')}\n"
        f"record_id     : {entry.get('record_id', '')}\n"
        f"rows_inserted : {entry.get('rows_inserted', '')}\n"
        f"rows_skipped  : {entry.get('rows_skipped', '')}\n"
        f"start         : {entry['start_timestamp']}\n"
        f"end           : {entry['end_timestamp']}\n"
        f"duration      : {duration}\n"
        f"status        : {entry['status']}\n"
        f"error         : {entry['error']}"
    )

    cutoff = datetime.now() - relativedelta(years=_RETENTION_YEARS)
    kept_blocks = []

    if os.path.exists(LOG_FILE):
        with open(LOG_FILE, "r") as f:
            raw = f.read()

        for block in raw.split(_SEPARATOR):
            block = block.strip()
            if not block:
                continue
            match = re.search(r'^start\s*:\s*(.+)$', block, re.MULTILINE)
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

    with open(LOG_FILE, "w") as f:
        f.write(f"\n{_SEPARATOR}\n".join(kept_blocks))
        f.write(f"\n{_SEPARATOR}\n")

print("MPESA PDF Statement Batch Processor")
print("----------------------------------")

print(f"Input directory: {INPUT_DIR}")
print(f"Output directory: {OUTPUT_DIR}")
print(f"Failed directory: {FAILED_DIR}")
print(f"Parser script: {PARSER_SCRIPT}")

# Create output directories if they don't exist
os.makedirs(OUTPUT_DIR, exist_ok=True)
os.makedirs(FAILED_DIR, exist_ok=True)

# Check if input directory exists
if not os.path.exists(INPUT_DIR):
    print(f"Error: Input directory {INPUT_DIR} does not exist!")
    sys.exit(1)

# Get all PDF files
pdf_files = glob.glob(os.path.join(INPUT_DIR, "*.pdf"))

if not pdf_files:
    print(f"No PDF files found in {INPUT_DIR}")
    sys.exit(1)

print(f"Found {len(pdf_files)} PDF files to process:")
for pdf_file in pdf_files:
    print(f"  - {os.path.basename(pdf_file)}")

# Keep track of successes and failures
successful_files = []
failed_files = []

# Process each PDF file separately (allows for better error handling)
for i, pdf_file in enumerate(pdf_files, 1):
    print(f"\nProcessing file {i} of {len(pdf_files)}: {os.path.basename(pdf_file)}")
    
    # Get the output CSV path
    base_filename = os.path.basename(pdf_file)
    output_csv = os.path.join(OUTPUT_DIR, base_filename.replace('.pdf', '.csv'))
    
    # Get password from filename - extract 6-digit number
    base_name = base_filename.replace('.pdf', '')
    if '_' in base_name:
        # Old format: 123456_something.pdf
        password = base_name.split('_')[0]
    else:
        # Extract 6-digit number from filename (handles both pure numbers and text prefixes)
        match = re.search(r'\d{6}', base_name)
        if match:
            password = match.group()
        else:
            # If no 6-digit number found, use the entire filename
            password = base_name
    
    # Compute MD5 before the file is moved
    file_md5 = _compute_md5(pdf_file)

    # Import deferred so errors surface per-file rather than aborting the batch
    from parser.mpesa_parser import process_pdf_file  # noqa: PLC0415

    try:
        start_ts = datetime.now()
        print(f"Running parser with: {pdf_file}, {output_csv}, password: {password}")

        df = process_pdf_file(pdf_file)

        end_ts = datetime.now()
        print(f"Processing completed in {(end_ts - start_ts).total_seconds():.2f} seconds")

        if df is not None and os.path.exists(output_csv):
            upload      = df.attrs.get("upload_result")
            rows_ins    = upload.inserted      if upload else ""
            rows_skip   = upload.skipped       if upload else ""
            man_hash    = upload.manifest_hash if upload else ""

            if upload and upload.inserted == 0 and upload.skipped > 0:
                status = "SKIPPED"
                error  = (
                    f"{upload.skipped} row(s) already exist in the database "
                    f"(receipt_no + amount conflict — possible duplicate submission)"
                )
            else:
                status = "SUCCESS"
                error  = ""

            print(f"✓ Successfully created CSV file: {output_csv}")
            successful_files.append(base_filename)
            _write_log({
                "filename":        base_filename,
                "md5":             file_md5,
                "manifest_hash":   man_hash,
                "source":          "process_all_pdfs.py",
                "source_path":     os.path.abspath(pdf_file),
                "destination":     os.path.abspath(output_csv),
                "rows_inserted":   rows_ins,
                "rows_skipped":    rows_skip,
                "start_timestamp": start_ts.strftime("%Y-%m-%d %H:%M:%S"),
                "end_timestamp":   end_ts.strftime("%Y-%m-%d %H:%M:%S"),
                "status":          status,
                "error":           error,
            })
            parsed_pdf_path = os.path.join(OUTPUT_DIR, base_filename)
            shutil.move(pdf_file, parsed_pdf_path)
            print(f"  Moved PDF to: {parsed_pdf_path}")
        else:
            end_ts = datetime.now()
            print(f"✗ ERROR: Failed to create CSV file for {pdf_file}")
            _write_log({
                "filename":        base_filename,
                "md5":             file_md5,
                "manifest_hash":   "",
                "source":          "process_all_pdfs.py",
                "source_path":     os.path.abspath(pdf_file),
                "destination":     os.path.abspath(output_csv),
                "rows_inserted":   "",
                "rows_skipped":    "",
                "start_timestamp": start_ts.strftime("%Y-%m-%d %H:%M:%S"),
                "end_timestamp":   end_ts.strftime("%Y-%m-%d %H:%M:%S"),
                "status":          "FAILED",
                "error":           "No transactions parsed or CSV not created",
            })
            failed_path = os.path.join(FAILED_DIR, base_filename)
            shutil.move(pdf_file, failed_path)
            print(f"  Moved failed PDF to: {failed_path}")
            failed_files.append(base_filename)

    except Exception as e:
        end_ts = datetime.now()
        print(f"✗ Error processing {pdf_file}: {str(e)}")
        _write_log({
            "filename":        base_filename,
            "md5":             file_md5,
            "manifest_hash":   "",
            "source":          "process_all_pdfs.py",
            "source_path":     os.path.abspath(pdf_file),
            "destination":     os.path.abspath(output_csv),
            "rows_inserted":   "",
            "rows_skipped":    "",
            "start_timestamp": start_ts.strftime("%Y-%m-%d %H:%M:%S"),
            "end_timestamp":   end_ts.strftime("%Y-%m-%d %H:%M:%S"),
            "status":          "FAILED",
            "error":           str(e)[:500].replace("\n", " "),
        })
        failed_path = os.path.join(FAILED_DIR, base_filename)
        shutil.move(pdf_file, failed_path)
        print(f"  Moved failed PDF to: {failed_path}")
        failed_files.append(base_filename)

print("\n" + "="*50)
print("PROCESSING SUMMARY")
print("="*50)

# List all CSV files created
csv_files = glob.glob(os.path.join(OUTPUT_DIR, "*.csv"))
print(f"\n✓ Successfully processed: {len(successful_files)} files")
if successful_files:
    for file in successful_files[:10]:  # Show first 10
        print(f"  - {file}")
    if len(successful_files) > 10:
        print(f"  ... and {len(successful_files) - 10} more")

print(f"\n✗ Failed to process: {len(failed_files)} files")
if failed_files:
    for file in failed_files:
        print(f"  - {file}")
    print(f"\nFailed PDFs have been moved to: {FAILED_DIR}")
    
print(f"\nSuccessfully processed PDFs have been moved to: {OUTPUT_DIR}")

print(f"\nTotal CSV files created: {len(csv_files)}")
print("="*50) 