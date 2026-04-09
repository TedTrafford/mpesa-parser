# MPESA Statement Parser

This tool parses M-PESA PDF statements and extracts transaction data into CSV files and a MySQL database, with complete customer information and parse-provenance metadata.

## Quick Start

```bash
# 1. Create and activate conda environment
conda create -n mpesa_parser python=3.9 -y
conda activate mpesa_parser

# 2. Install dependencies
pip install -r requirements.txt

# 3. Place your PDF files in Mpesa_pdf_statement/

# 4a. Batch-process all PDFs
./run_parser.sh

# 4b. Parse a single PDF (queued, safe for concurrent callers)
python parse_single.py <record_id> <file_name> <pdf_path> <pin> <phone_number>

# 4c. Test DB connectivity (run on server to diagnose upload issues)
python db_test.py
```

## Requirements

- Python 3.9+
- Required Python packages (see `requirements.txt`):
  - `PyPDF2==3.0.1`
  - `pandas>=2.2.0`
  - `numpy>=1.26.0`
  - `SQLAlchemy>=2.0`
  - `PyMySQL>=1.1`
  - `python-dateutil>=2.8`

## Installation

### Option 1: Using Anaconda (Recommended)

```bash
conda create -n mpesa_parser python=3.9 -y
conda activate mpesa_parser
pip install -r requirements.txt
```

### Option 2: Using pip

```bash
pip install -r requirements.txt
```

## Directory Structure

```
.
├── Mpesa_pdf_statement/          # Input: Place PDF files here
├── Mpesa_csv_Statement_Parsed/   # Output: Successful CSVs
├── Mpesa_csv_Statement_Failed/   # Failed: PDFs that couldn't be parsed
├── logs/                         # Runtime logs (auto-created)
│   ├── processing_log.log        #   Per-job outcome (SUCCESS / SKIPPED / FAILED)
│   ├── db_errors.log             #   Full DB error tracebacks
│   └── parse_single_debug.log    #   Raw argument diagnostics per invocation
├── queue/                        # Runtime queue (git-ignored)
│   ├── pending/                  #   Jobs waiting to be processed
│   ├── done/                     #   Completed job descriptors
│   ├── failed/                   #   Failed job descriptors
│   └── worker.lock               #   Advisory lock (one worker at a time)
├── parser/
│   └── mpesa_parser.py           # Core parser + process_single_file()
├── db/
│   ├── schema.sql                # MySQL table DDL (reference / manual deployments)
│   ├── uploader.py               # MySQL upload helper (INSERT IGNORE + UploadResult + migrations)
│   ├── features_207.sql          # 207-feature credit-scoring SQL query
│   └── procedures/
│       └── fly_profiling.sql     # fly_profiling stored procedure (auto-deployed at startup)
├── config.py                     # Paths, DB credentials, regex patterns
├── parse_single.py               # Single-file queued parser (PHP integration)
├── process_all_pdfs.py           # Batch processor
├── db_test.py                    # DB connectivity diagnostic script
├── run_parser.sh                 # Quick batch-run script
├── requirements.txt              # Python dependencies
└── README.md                     # This file
```

## Configuration

All paths, DB credentials, regex patterns, and transaction type mappings are
centralized in `config.py`. Override any value with environment variables:

| Environment variable | Default | Description |
|---|---|---|
| `MPESA_DB_HOST` | `139.84.243.180` | MySQL host |
| `MPESA_DB_PORT` | `3306` | MySQL port |
| `MPESA_DB_NAME` | `Data_Science` | Database name |
| `MPESA_DB_USER` | `staging` | MySQL user |
| `MPESA_DB_PASSWORD` | *(hardcoded fallback)* | MySQL password |
| `MOBILE_COUNTRY_CODE` | `254` | Country dialling code prepended when normalising phone numbers (`0xxx` → `254xxx`). Change for non-Kenya deployments. |

## How to Use

### Option 1: Batch-process all PDFs

```bash
conda activate mpesa_parser
./run_parser.sh
# or directly:
python process_all_pdfs.py
```

### Option 2: Parse a single file with queueing (`parse_single.py`)

Use this when integrating with an external system (e.g. a PHP/Laravel web
application) that submits one statement at a time and may call the script
concurrently.

```bash
python parse_single.py <record_id> <file_name> <pdf_path> <pin> <phone_number>
```

| Argument | Description |
|----------|-------------|
| `record_id` | Caller-supplied unique identifier (e.g. a Laravel model UUID). Stored in the `record_id` DB column of every transaction row. |
| `file_name` | Original PDF filename (e.g. `310549.pdf`). The output CSV uses the same stem. |
| `pdf_path` | Absolute path to the PDF file on disk. |
| `pin` | PDF password used to decrypt the M-PESA statement. |
| `phone_number` | Customer's mobile number in international format (e.g. `254722123456`). A leading `0` is auto-converted to `254`. Validated against the number extracted from the PDF — result stored as `phone_match` in the processing log. |

**Examples:**

```bash
# Standard call — phone_number validated against the PDF
python parse_single.py 12345 310549.pdf /var/uploads/310549.pdf 310549 254722123456

# With a UUID record_id (typical Laravel usage)
python parse_single.py 019cf6da-b7d9-73a6-bd7a-f0f8d52a66ba statement.pdf \
    /var/www/app/storage/app/private/mpesa-statements/statement.pdf 123456 254759891910
```

**Path handling:**

`parse_single.py` accepts absolute paths only. If the caller strips the
leading `/` (producing a relative path), the script restores it automatically
before validation — preventing the doubled-path bug that results from
`os.path.abspath()` prepending the process CWD.

**Concurrency behaviour:**

Multiple processes may call `parse_single.py` simultaneously. Each call
atomically writes a job file to `queue/pending/` and then attempts to acquire
an exclusive advisory lock (`queue/worker.lock`).

- The **first caller** that wins the lock becomes the worker and drains all
  pending jobs in arrival order before releasing the lock.
- **Subsequent callers** that lose the lock exit immediately after enqueuing —
  their job is picked up by the running worker in the same drain loop.

Completed job descriptors are archived to `queue/done/`; failed ones to
`queue/failed/` for inspection.

### Option 3: Call the parser directly (no queue)

```bash
python parser/mpesa_parser.py <pdf_path> [output_csv] [password]
```

```bash
python parser/mpesa_parser.py Mpesa_pdf_statement/288720.pdf
python parser/mpesa_parser.py Mpesa_pdf_statement/288720.pdf output.csv 288720
```

## Database Upload

Every successful parse uploads the extracted transactions to MySQL table
`tbl_raw_mpesa_statements`.

### Automatic migrations

`db/uploader.py` runs a lightweight migration check on every startup (inside
`ensure_table_exists()`). Migrations are **idempotent** — safe to run
repeatedly, they are no-ops when nothing has changed:

| Migration | What it does |
|-----------|--------------|
| Table creation | Creates `tbl_raw_mpesa_statements` if it does not exist |
| `record_id` column | Adds `record_id` + its index to pre-existing tables |
| Unique key upgrade | Replaces the single-column `uq_receipt_no` key with a composite `uq_receipt_amount` key |
| Mobile number normalisation | One-time `UPDATE` converting all `0xxx` values in `mobile_number` to `254xxx` |
| `fly_profiling` procedure | Drops and recreates the stored procedure from `db/procedures/fly_profiling.sql` |
| `profiling_status` column | Adds `profiling_status` to `tbl_file_processing_logs` on existing tables |
| `phone_match` column | Adds `phone_match` to `tbl_file_processing_logs` on existing tables |
| `balance_check_pct` column | Adds `balance_check_pct` to `tbl_file_processing_logs` on existing tables |

#### Editing the `fly_profiling` procedure

Edit `db/procedures/fly_profiling.sql` directly in this repo, then restart the
app. The migration will pick up the changes automatically — no manual MySQL
Workbench runs required. The `DEFINER` clause is stripped at deploy time so the
connecting DB user does not need `SUPER` or `SET_USER_ID` privilege.

#### Invoking `fly_profiling` manually

The procedure is no longer called automatically after every parse job. To run
profiling for a specific subscriber from Python, call the helper directly:

```python
from parse_single import call_fly_profiling
call_fly_profiling("254722123456")
```

Or execute it straight from a MySQL client:

```sql
CALL fly_profiling('254722123456');
```

### Duplicate handling (INSERT IGNORE)

Rows are inserted with `INSERT IGNORE`. If a `receipt_no` already exists in
the table, the new row is **silently skipped** — no duplicate is created. This
behaviour is intentional:

- Re-uploading the same PDF by the same user produces no duplicates.
- A different user uploading a PDF that shares a receipt number is flagged as a
  potential duplicate or fraudulent submission — visible in the processing log
  as `status: SKIPPED`.

### DB connectivity diagnostic

Before deploying or when troubleshooting, run the diagnostic script on the
server to verify each layer in isolation:

```bash
python db_test.py
```

The script checks: config loading → PyMySQL import → raw TCP connection →
MySQL authentication → SQLAlchemy engine → table creation → test row insert.
Each step prints `PASS` or `FAIL` with a clear explanation.

## Logs

All runtime logs are written to the `logs/` directory next to `parse_single.py`
(auto-created on first run).

### `logs/processing_log.log`

One block per job, retained for 3 years. Fields:

| Field | Description |
|---|---|
| `filename` | PDF filename |
| `md5` | MD5 of the raw PDF bytes |
| `manifest_hash` | MD5 of (filename bytes + file bytes) — changes if either the name or content changes |
| `source` | Always `parse_single.py` |
| `source_path` | Absolute path to the input PDF |
| `destination` | Absolute path to the output CSV |
| `record_id` | Caller-supplied identifier |
| `rows_inserted` | Number of new rows written to MySQL |
| `rows_skipped` | Number of rows silently ignored (receipt_no already exists) |
| `start` / `end` / `duration` | Job timing |
| `status` | `SUCCESS`, `SKIPPED`, or `FAILED` |
| `profiling_status` | Result of the `fly_profiling` stored-procedure call: `OK`, `FAILED: <msg>`, `SKIPPED`, or `N/A` |
| `phone_match` | `MATCH` — caller `phone_number` matches the mobile number in the PDF; `NO_MATCH` — mismatch; `N/A` — parse failed or no phone supplied |
| `balance_check_pct` | Percentage of consecutive transaction pairs where `balance[i] == balance[i-1] + amount[i]` — a data-quality indicator (see note below) |
| `error` | Empty on success; skip reason or exception message otherwise |

**Status values:**

| Status | Meaning |
|---|---|
| `SUCCESS` | PDF parsed and all (or some) rows inserted into MySQL |
| `SKIPPED` | PDF parsed successfully but all rows already exist — possible duplicate submission |
| `FAILED` | Parsing or DB error — see `error` field and `db_errors.log` |

**`phone_match` values:**

| Value | Meaning |
|---|---|
| `MATCH` | The `phone_number` argument matches the mobile number extracted from the PDF |
| `NO_MATCH` | They differ — possible wrong customer or data-entry error |
| `N/A` | Parse failed, `phone_number` was empty, or PDF had no mobile number |

**`balance_check_pct` explained:**

Transactions are sorted by date + time. For each consecutive pair the formula
`balance[i] == balance[i-1] + amount[i]` (±0.01 tolerance) is tested and the
percentage of pairs that pass is recorded. M-PESA statements include two-sided
entries (e.g. AGENT WITHDRAWAL records both the credit and debit legs as
separate rows), so a score of 100 % is uncommon — this is a relative
data-quality indicator. `NULL` means the parse failed or the file had fewer
than 2 transactions.

**Example — new upload:**
```
filename          : abc123.pdf
md5               : 5ad9815575d547baeab12e70031ac316
manifest_hash     : e3b0c44298fc1c149afb4c8996fb924
...
rows_inserted     : 47
rows_skipped      : 0
status            : SUCCESS
profiling_status  : OK
phone_match       : MATCH
balance_check_pct : 72.34%
error             :
```

**Example — duplicate submission:**
```
filename          : abc123.pdf
md5               : 5ad9815575d547baeab12e70031ac316
manifest_hash     : e3b0c44298fc1c149afb4c8996fb924
...
rows_inserted     : 0
rows_skipped      : 47
status            : SKIPPED
profiling_status  : OK
phone_match       : MATCH
balance_check_pct : 72.34%
error             : 47 row(s) already exist in the database (receipt_no conflict — possible duplicate submission)
```

### `logs/db_errors.log`

Full Python traceback for every DB error. Check this first when `status: FAILED`
and the error message is truncated in `processing_log.log`.

### `logs/parse_single_debug.log`

One line per script invocation showing the raw `pdf_path` argument received
from the caller, the resolved path after the leading-slash guard, the process
CWD, and whether the file exists. Useful for diagnosing path issues.

## CSV / Database Output Format

Each parsed statement produces **14 columns** (CSV and database table):

| Column | DB column | Description | Example |
|--------|-----------|-------------|---------|
| Record ID | `record_id` | Caller-supplied unique identifier | `019cf6da-b7d9-73a6-bd7a-f0f8d52a66ba` |
| Customer Name | `customer_name` | Account holder name | Monica Atieno Ondoo |
| Mobile Number | `mobile_number` | M-PESA number in international format | 254112850906 |
| Email Address | `email_address` | Email on account | info@aleza.co.ke |
| Statement Period | `statement_period` | Date range | 14 Aug 2024 - 14 Feb 2025 |
| Request Date | `request_date` | Statement generated | 14 Feb 2025 |
| Date | `transaction_date` | Transaction date | 2025-02-14 |
| Time | `transaction_time` | Transaction time | 14:30:45 |
| Receipt No | `receipt_no` | M-PESA receipt (unique) | TJEKA7E3VO |
| Transaction Type | `transaction_type` | Category | SEND MONEY |
| Details | `details` | Full description | Customer Transfer to... |
| Amount | `amount` | Signed transaction amount | -1500.00 |
| Balance | `balance` | Balance after transaction | 5432.10 |
| metadata | `metadata` | JSON parse-provenance object | see below |

### `metadata` column

Every row carries a `metadata` JSON object with parse-level provenance.

```json
{
  "manifest_hash":    "85779f75f98d0eed022ccd597cc7845f",
  "pin":              "310549",
  "record_uuid":      "3829cdd5-6e40-4be4-bf9a-3b35dfca8ebd",
  "output_file_path": "/path/to/Mpesa_csv_Statement_Parsed/310549.csv"
}
```

| Key | Description |
|-----|-------------|
| `manifest_hash` | MD5 of (filename bytes + file bytes) — changes if the file is replaced |
| `pin` | PDF stem used as the decryption password |
| `record_uuid` | UUID4 unique to this individual transaction row |
| `output_file_path` | Absolute path to the output CSV |

## Troubleshooting

### 1. Module not found
```bash
conda activate mpesa_parser
pip install -r requirements.txt
```

### 2. numpy compatibility errors
```bash
pip uninstall -y numpy pandas
pip install "numpy<2.0" pandas==2.0.0
```

### 3. Password / decryption errors
Verify the filename contains a 6-digit number:
- Pure numbers: `288720.pdf` → password `288720`
- With text prefix: `Maniga953060.pdf` → password `953060`
- Old format: `123456_statement.pdf` → password `123456`

### 4. Data not appearing in MySQL

Run the DB diagnostic on the server:
```bash
python db_test.py
```

Then check the logs:
```bash
# Job outcome and skip/insert counts
cat logs/processing_log.log

# Full DB error traceback (if any)
cat logs/db_errors.log

# Raw path received from caller
cat logs/parse_single_debug.log
```

If all jobs show `status: SKIPPED`, the receipt numbers already exist in the
database from a previous run. This is expected behaviour (INSERT IGNORE). If
you need to re-import from scratch, truncate the table and re-run:

```sql
TRUNCATE TABLE tbl_raw_mpesa_statements;
```

### 5. Doubled file path (`/var/www/.../var/www/...`)

This was a known production bug caused by PHP prepending the storage base path
to a `file_path` value that already contained the full absolute path.

**PHP-side fix:** ensure `$filePath` is constructed from the relative portion
of the stored path only, not from a path that already contains the base.

**Python-side guard:** `parse_single.py` automatically restores a missing
leading `/` if the received path is not absolute, preventing `os.path.abspath()`
from prepending the process CWD and doubling the path.

### 6. `phone_match: NO_MATCH` in the processing log

The `phone_number` argument passed to `parse_single.py` does not match the
mobile number extracted from the PDF statement.  Check that:

1. The correct PDF was submitted for the given customer record.
2. The `phone_number` was passed in international format (`254xxx`). A leading
   `0` is auto-converted, but any other prefix is not.
3. The PDF itself belongs to the expected account holder.

### 7. Processing stops during batch run
Re-run the script — already processed files have been moved:
```bash
./run_parser.sh
```

## Customization

To add new transaction types or modify existing ones, edit the
`TRANSACTION_TYPES` dictionary in `config.py`.
