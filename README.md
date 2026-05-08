# M-PESA Statement Parser

Parses Safaricom M-PESA PDF bank statements into structured CSV files and uploads the transactions to a MySQL database.  After each successful parse a credit-scoring stored procedure (`fly_profiling`) runs automatically to compute a credit limit for the customer.  A companion procedure (`sp_populate_rejection_reasons`) then explains, in ranked order, why any rejected subscriber did not qualify — surfacing the most impactful gate failure first, down to the specific scorecard feature with the most room for improvement.

---

## Table of contents

- [Overview](#overview)
- [Project structure](#project-structure)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Database setup](#database-setup)
- [Usage](#usage)
  - [Single PDF](#single-pdf)
  - [Batch processing](#batch-processing)
- [Database schema](#database-schema)
- [Migrations](#migrations)
- [Credit scoring](#credit-scoring)
  - [Rejection reasons](#rejection-reasons)
- [Development](#development)
- [Deployment](#deployment)
  - [Server initial setup](#server-initial-setup)

---

## Overview

```
PDF statement  →  Parser  →  CSV  →  MySQL (tbl_raw_mpesa_statements)
                                           ↓
                                   fly_profiling() stored procedure
                                           ↓
                              customer_credit_limit  /  tbl_subscriber_profiles
                                           ↓  (model_category = 'not_qualified')
                             sp_populate_rejection_reasons()
                                           ↓
                                  tbl_rejection_reasons
                         (ranked reason codes + repayment probability)
```

Each transaction row extracted from the PDF is deduplicated against the database using a composite key on `(receipt_no, amount)` — re-submitting the same PDF is safe.

---

## Project structure

```
.
├── config.py                      # DB connection settings, path constants, helpers
├── parse_single.py                # Single-PDF entry point (queue-backed worker)
├── process_all_pdfs.py            # Batch processor for a directory of PDFs
├── parser/
│   └── mpesa_parser.py            # Core PDF → DataFrame parser
├── db/
│   ├── migrate.py                 # Migration runner (see Migrations section)
│   ├── uploader.py                # DataFrame → MySQL upload + audit log
│   ├── schema.sql                 # Reference DDL for tbl_raw_mpesa_statements
│   ├── features_207.sql           # 207-feature engineering query
│   ├── migrations/                # Numbered SQL migration files
│   │   ├── 0001_create_tbl_raw_mpesa_statements.sql
│   │   ├── 0002_create_tbl_file_processing_logs.sql
│   │   ├── 0003_create_tbl_scoring_features.sql
│   │   ├── 0004_create_tbl_subscriber_profiles.sql
│   │   ├── 0005_create_customer_credit_limit.sql
│   │   ├── 0006_add_record_id_to_raw_statements.sql
│   │   ├── 0007_replace_receipt_unique_key.sql
│   │   ├── 0008_normalize_mobile_numbers.sql
│   │   ├── 0009_add_profiling_status_to_logs.sql
│   │   ├── 0010_add_phone_match_to_logs.sql
│   │   ├── 0011_add_balance_check_pct_to_logs.sql
│   │   ├── 0012_add_supplied_phone_to_logs.sql
│   │   ├── 0013_add_extracted_phone_to_logs.sql
│   │   ├── 0014_fix_customer_credit_limit_types.sql
│   │   ├── 0015_fix_customer_credit_limit_data.sql
│   │   └── 0016_create_tbl_rejection_reasons.sql
│   └── procedures/
│       ├── fly_profiling.sql                    # Credit-scoring stored procedure
│       └── sp_populate_rejection_reasons.sql    # Rejection reason analysis procedure
├── scripts/
│   ├── pre-push                   # Git hook — runs lint + tests before push
│   └── server-deploy.sh           # Server-side deploy script (called by CI/CD)
├── tests/
│   ├── test_config.py
│   ├── test_parser.py
│   └── test_parse_single.py
├── .env.example                   # Environment variable template
├── Makefile                       # Local dev helpers
└── .github/workflows/
    ├── ci.yml                     # Lint + test on every PR
    └── deploy.yml                 # SSH deploy to production on merge to main
```

---

## Requirements

- Python 3.9+
- MySQL 8.0+ (or compatible)
- Runtime packages: `PyPDF2`, `pandas`, `numpy`, `SQLAlchemy`, `PyMySQL`, `python-dateutil`

---

## Installation

```bash
# Clone the repository
git clone <repo-url>
cd Mpesa_statement_parser_clean

# Install runtime dependencies
pip install -r requirements.txt

# Install dev/test dependencies (optional)
pip install -r requirements-dev.txt

# Install the pre-push git hook (optional but recommended)
make hooks
```

---

## Configuration

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

```ini
# MySQL connection
MPESA_DB_HOST=127.0.0.1
MPESA_DB_PORT=3306
MPESA_DB_NAME=Data_Science
MPESA_DB_USER=staging
MPESA_DB_PASSWORD=your_password_here

# Optional: override country code for mobile number normalisation (default: 254)
# MOBILE_COUNTRY_CODE=254
```

Load the variables before running any script:

```bash
export $(cat .env | xargs)
```

---

## Database setup

All tables are created and kept up to date by the migration runner.

### Fresh database

```bash
python db/migrate.py
```

This creates all tables and the `schema_migrations` tracking table, then applies any historical data migrations (phone number normalisation, column additions, etc.).

### Existing database (set up before migrations were introduced)

If the tables already exist and were created by the old code, register the current state as a baseline first — this marks all migrations as applied without re-running their SQL:

```bash
python db/migrate.py --baseline
```

Future schema changes (new migration files) will then be applied normally on the next `python db/migrate.py` run.

### Check migration status

```bash
python db/migrate.py --status
```

Output:

```
  STATUS      VERSION
  ----------  ------------------------------------
  ✓ applied   0001_create_tbl_raw_mpesa_statements
  ✓ applied   0002_create_tbl_file_processing_logs
  · PENDING   0003_create_tbl_scoring_features
  ...

  2 applied   12 pending
```

---

## Usage

### Single PDF

```bash
python parse_single.py <record_id> <file_name> <pdf_path> <pin> <phone_number>
```

| Argument | Description |
|---|---|
| `record_id` | Caller-supplied unique identifier stored with every transaction row |
| `file_name` | Original PDF filename (e.g. `310549.pdf`) |
| `pdf_path` | Absolute or relative path to the PDF file |
| `pin` | PDF password used to decrypt the M-PESA statement |
| `phone_number` | Customer's mobile number — validated against the number in the PDF |

**Example:**
```bash
python parse_single.py "REQ-001" "310549.pdf" "/data/310549.pdf" "1234" "254722123456"
```

The script uses a file-based queue so multiple callers can invoke it concurrently — each call enqueues a job and only one worker processes jobs at a time.

**Exit codes:** `0` = success, `1` = bad arguments or file not found.

### Batch processing

```bash
python process_all_pdfs.py
```

Processes every PDF in the configured `INPUT_DIR` directory sequentially, uploading transactions to the database and writing a processing log for each file.

---

## Database schema

| Table | Purpose |
|---|---|
| `tbl_raw_mpesa_statements` | All parsed M-PESA transactions. Unique on `(receipt_no, amount)`. |
| `tbl_file_processing_logs` | Audit log for every PDF parse job — status, row counts, phone validation, profiling outcome. |
| `tbl_scoring_features` | 18 engineered features computed by `fly_profiling()` per customer. |
| `tbl_subscriber_profiles` | Risk segment, turnover segment, and credit limit output per customer. |
| `customer_credit_limit` | Latest approved credit limit per mobile number (maintained by `fly_profiling()`). |
| `tbl_rejection_reasons` | Ranked rejection reasons for every `not_qualified` subscriber (see [Rejection reasons](#rejection-reasons)). |
| `schema_migrations` | Tracks which migration files have been applied and when. |

### Key columns — `customer_credit_limit`

| Column | Type | Notes |
|---|---|---|
| `mobile_number` | `VARCHAR(20)` | International format (`254xxx`) — consistent with all other tables |
| `credit_limit` | `INT` | Whole-number amounts (0, 5000, 8000, …) |
| `profiling_date` | `DATETIME` | When `fly_profiling()` last ran for this customer |
| `profiling_category` | `VARCHAR(20)` | `FTB1` (new customer) or `FTB2` (returning customer) |

> **Note:** Early deployments stored `mobile_number` and `credit_limit` as `DECIMAL(18,4)`, causing values to display with thousands-separator commas (e.g. `254,722,123,456.0000`). Migrations `0014` and `0015` correct this automatically — `0015` also strips any `.0000` decimal artefacts left in existing rows after the column type change.

### Key columns — `tbl_rejection_reasons`

| Column | Type | Notes |
|---|---|---|
| `mobile_number` | `VARCHAR(20)` | Primary lookup key — one subscriber, one set of reasons |
| `profile_id` | `BIGINT UNSIGNED` | FK to the `tbl_subscriber_profiles` row that was rejected |
| `reason_rank` | `TINYINT UNSIGNED` | `1` = most impactful reason for this subscriber; dense-ranked |
| `reason_code` | `VARCHAR(60)` | Machine-readable enum (see table below) |
| `reason_detail` | `TEXT` | Human-readable sentence for the credit analyst |
| `feature_name` | `VARCHAR(100)` | Populated only for `WEAK_SCORING_FEATURE` rows |
| `feature_value` | `DOUBLE` | Raw feature value at scoring time |
| `score_actual` | `INT` | Points this feature contributed |
| `score_max` | `INT` | Maximum points this feature could contribute |
| `score_gap` | `INT` | `score_max − score_actual`; higher = more points lost |
| `repayment_probability` | `DECIMAL(5,2)` | Estimated probability of repayment (%) derived from `total_score` via logistic sigmoid |

**Reason codes, in priority order:**

| Code | Condition | Rank |
|---|---|---|
| `INSUFFICIENT_HISTORY` | `age_days < 90` — hard gate; no limit possible regardless of score | 1 |
| `WEAK_SCORING_FEATURE` | The single scorecard feature with the highest score gap (most points lost vs. maximum) | 1 or 2 |
| `LOW_TURNOVER` | `turnover_segment` below the minimum required for the subscriber's `risk_segment` | 2 or 3 |
| `HIGH_CREDIT_RISK` | `risk_segment ≤ 2` — score so low no achievable turnover level can qualify the subscriber | 2 or 3 |

---

## Migrations

Migration files live in `db/migrations/` and are named `NNNN_description.sql`. The runner tracks applied migrations in a `schema_migrations` table so each file runs exactly once per database.

### Adding a new migration

1. Create `db/migrations/NNNN_description.sql` with the next available number.
2. Write plain SQL — `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE`, `UPDATE`, etc.
3. Run `python db/migrate.py` to apply it.

The runner gracefully handles the common "already in desired state" MySQL errors:

| MySQL error | Meaning | Action |
|---|---|---|
| 1060 | Duplicate column name — `ADD COLUMN` already exists | Skip silently |
| 1061 | Duplicate key name — `ADD INDEX` already exists | Skip silently |
| 1091 | Can't drop — column/index doesn't exist | Skip silently |

### Commands

```bash
python db/migrate.py             # apply all pending migrations
python db/migrate.py --status    # show applied vs pending
python db/migrate.py --baseline  # register existing DB without running SQL
```

---

## Credit scoring

After each successful parse, `fly_profiling(<mobile_number>)` is called automatically. The procedure:

1. Computes 18 features from `tbl_raw_mpesa_statements` (6-month and 3-month windows).
2. Scores them against a risk scorecard and a turnover scorecard.
3. Assigns a `credit_limit` based on the combined `risk_segment` × `turnover_segment` matrix.
4. Writes results to `tbl_scoring_features`, `tbl_subscriber_profiles`, and `customer_credit_limit`.

The stored procedure is read from `db/procedures/fly_profiling.sql` and (re)deployed on every startup — edit the file and restart to pick up changes.

### Rejection reasons

Subscribers whose `model_category` is set to `not_qualified` by `fly_profiling` can be analysed by the companion procedure `sp_populate_rejection_reasons()`. It is **not** called automatically on every parse; run it on demand (e.g. after a bulk profiling run or on a scheduled basis):

```sql
CALL sp_populate_rejection_reasons();
```

The procedure is idempotent — it only processes `not_qualified` mobile numbers that have no entry yet in `tbl_rejection_reasons`, using `mobile_number` as the primary identifier. Re-running it after new rejections accumulate is safe.

For each subscriber it inserts up to three ranked reasons, derived entirely from data already in the database:

| Priority | Source | What it tells you |
|---|---|---|
| **1 — `INSUFFICIENT_HISTORY`** | `tbl_subscriber_profiles.age_days` | Statement history < 90 days; the subscriber simply needs to wait |
| **2 — `WEAK_SCORING_FEATURE`** | `tbl_scoring_features` (latest row) | The one scorecard feature that lost the most points relative to its maximum — the highest-leverage behaviour to improve |
| **3 — `LOW_TURNOVER` / `HIGH_CREDIT_RISK`** | `tbl_subscriber_profiles` | Turnover too low for the subscriber's risk level, or risk score too low for any turnover to compensate |

Each reason row also carries a **`repayment_probability`** — the subscriber's estimated probability of repayment expressed as a percentage, computed from the scorecard total via a logistic sigmoid:

```
P = 100 / (1 + exp(−(total_score − 100) / 35))
```

Reference calibration points against the scoring model's segments:

| Risk segment | Approx. score | Repayment probability |
|---|---|---|
| 1 (≤ 45) | 45 | ~17% |
| 3 (< 81) | 81 | ~39% |
| 5 (< 127) | 127 | ~65% |
| 8 (≥ 169) | 169 | ~88% |

The procedure source lives at `db/procedures/sp_populate_rejection_reasons.sql`; the table DDL and `CREATE PROCEDURE` statement are in migration `0016`.

---

## Development

```bash
make install-dev    # install runtime + dev/test dependencies
make test           # run the test suite
make test-cov       # run tests with HTML coverage report (htmlcov/)
make lint           # run flake8
make check          # lint + test (mirrors CI — run before pushing)
make hooks          # install the pre-push git hook
make clean          # remove .pyc files and __pycache__
```

---

## Deployment

The project deploys automatically to production via GitHub Actions on every merge to `main`.

### CI/CD pipeline

1. **CI** (`ci.yml`) — runs `make check` (lint + tests) on every pull request.
2. **Deploy** (`deploy.yml`) — SSHes into the production server and runs `scripts/server-deploy.sh` on merge to `main`.

### `server-deploy.sh` steps

1. `git pull` latest code from `main`.
2. Activate the virtualenv and sync `pip install -r requirements.txt`.
3. (Optionally) restart a `systemd` service if the parser is run as a persistent process.

### Required GitHub secrets

| Secret | Value |
|---|---|
| `SSH_HOST` | Production server IP / hostname |
| `SSH_USER` | SSH login user |
| `SSH_PRIVATE_KEY` | Private key with access to the server |

Set these at: **Settings → Secrets and variables → Actions → Repository secrets**.

---

### Server initial setup

Run these steps **once** when setting up the server for the first time.  Subsequent deploys are handled automatically by the CI/CD pipeline.

#### 1. Clone the repository

```bash
mkdir -p /var/www/server/parser
cd /var/www/server/parser
git clone <repo-url> .
```

#### 2. Create and activate a virtualenv

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

#### 3. Create runtime directories

The parser reads PDFs from, and writes CSVs and logs to, directories that are **not** tracked by git and must be created manually:

```bash
cd /var/www/server/parser

mkdir -p Mpesa_pdf_statement        # INPUT_DIR  — drop PDF statements here
mkdir -p Mpesa_csv_Statement_Parsed # OUTPUT_DIR — parsed CSVs land here
mkdir -p Mpesa_csv_Statement_Failed # FAILED_DIR — CSVs for failed parses
mkdir -p logs                       # LOG_DIR    — application and error logs
mkdir -p queue                      # job queue used by parse_single.py
```

| Directory | Config constant | Purpose |
|---|---|---|
| `Mpesa_pdf_statement/` | `INPUT_DIR` | Source PDFs for batch processing |
| `Mpesa_csv_Statement_Parsed/` | `OUTPUT_DIR` | Output CSVs from successful parses |
| `Mpesa_csv_Statement_Failed/` | `FAILED_DIR` | Output CSVs from failed parses |
| `logs/` | `LOG_DIR` | Runtime logs and `db_errors.log` |
| `queue/` | *(internal)* | File-based job queue for `parse_single.py` |

#### 4. Configure environment variables

```bash
cp .env.example .env
nano .env   # fill in DB credentials
```

Load them for the current session:

```bash
export $(cat .env | xargs)
```

To load them automatically on login, add the export line to `~/.bashrc` or `~/.profile`.

#### 5. Run database migrations

```bash
source .venv/bin/activate
export $(cat .env | xargs)
python db/migrate.py
```

This creates all tables and the `schema_migrations` tracking table.  If the tables already exist from a previous setup, run `--baseline` first:

```bash
python db/migrate.py --baseline   # register existing state
python db/migrate.py              # apply any new migrations
```

#### 6. Verify the setup

```bash
# Check migrations
python db/migrate.py --status

# Run a test parse
python parse_single.py "test-001" "sample.pdf" "/path/to/sample.pdf" "1234" "254722123456"
```

#### Full one-liner (copy-paste)

```bash
cd /var/www/server/parser
python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
mkdir -p Mpesa_pdf_statement Mpesa_csv_Statement_Parsed Mpesa_csv_Statement_Failed logs queue
cp .env.example .env
echo "Edit .env with your DB credentials, then run:"
echo "  export \$(cat .env | xargs) && python db/migrate.py"
```

---

### Server assumptions (ongoing deploys)

- Repo is cloned at `/var/www/server/parser`
- Virtualenv exists at `/var/www/server/parser/.venv`
- `.env` with real credentials lives at `/var/www/server/parser/.env` (not tracked by git)
- All runtime directories listed above exist
