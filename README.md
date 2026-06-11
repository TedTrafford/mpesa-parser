# M-PESA Statement Parser

Parses Safaricom M-PESA PDF bank statements into structured CSV files and uploads the transactions to a MySQL database.  After each successful parse a credit-scoring stored procedure (`fly_profiling`) runs automatically to compute a credit limit for the customer.  It then calls `sp_populate_fraud_rules`, which evaluates a 12-rule weighted fraud framework and writes results to `tbl_fraud_rules`.  A companion procedure (`sp_populate_rejection_reasons`) explains, in ranked order, why a subscriber was rejected for an **initial** credit limit — credit-score gates for `not_qualified` subscribers, and `FRAUD_CRITICAL` for fraud scores ≥ 80 regardless of credit qualification.  For **returning borrowers**, `sp_apply_credit_limit_enhancement` evaluates limit increases against the Credit Limit Enhancement Matrix using LMS loan history plus parser analytics; ineligible customers receive ranked explanations in `tbl_LEM_rejection_reasons` via `sp_populate_LEM_rejection_reasons`.

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
  - [Fraud rules](#fraud-rules)
  - [Credit limit enhancement](#credit-limit-enhancement)
  - [LEM rejection reasons](#lem-rejection-reasons)
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
                                           ↓
                              sp_populate_fraud_rules()
                                           ↓
                                    tbl_fraud_rules
                         (12-rule score, decision, triggered rules)
                                           ↓
                             sp_populate_rejection_reasons()
                                           ↓
                                  tbl_rejection_reasons
              (credit gates for not_qualified + FRAUD_CRITICAL for score ≥ 80)

Returning borrowers (on demand / scheduled):
  aleza.loans + loan_schedules + parser tables
           ↓
  sp_apply_credit_limit_enhancement(mobile, apply)
           ↓
  tbl_credit_limit_enhancements
           ↓
  sp_populate_LEM_rejection_reasons()   (when is_eligible = 0)
           ↓
  tbl_LEM_rejection_reasons
           ↓
  (optional, p_apply = 1) aleza.credit_profiles + customer_credit_limit
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
│   │   ├── 0016_create_tbl_rejection_reasons.sql
│   │   ├── 0017_add_dti_cols_to_subscriber_profiles.sql
│   │   ├── 0018_align_table_collations.sql
│   │   ├── 0019_create_fraud_rules.sql
│   │   ├── 0020_create_credit_limit_enhancements.sql
│   │   └── 0021_create_tbl_LEM_rejection_reasons.sql
│   └── procedures/
│       ├── fly_profiling.sql                         # Credit-scoring stored procedure
│       ├── sp_populate_fraud_rules.sql               # Fraud / gaming risk evaluation
│       ├── sp_populate_rejection_reasons.sql         # Rejection reason analysis procedure
│       ├── sp_apply_credit_limit_enhancement.sql     # Limit enhancement matrix (returning borrowers)
│       └── sp_populate_LEM_rejection_reasons.sql     # LEM ineligibility explanations
├── scripts/
│   ├── pre-push                   # Git hook — runs lint + tests before push
│   └── server-deploy.sh           # Server-side deploy script (called by CI/CD)
├── tests/
│   ├── test_config.py
│   ├── test_parser.py
│   ├── test_parse_single.py
│   ├── test_profiling_procedures.py   # Credit-scoring / rejection reason rules
│   └── profiling_rules.py             # Reference logic mirrored from stored procedures
├── .env.example                   # Environment variable template
├── Makefile                       # Local dev helpers
└── .github/workflows/
    ├── ci.yml                     # Lint + test on every push and PR
    └── deploy.yml                 # SSH deploy to 65.20.86.247 on merge to main
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

`config.py` **auto-loads `.env`** from the project root on import, so the queued worker (`parse_single.py`), `db/migrate.py`, batch jobs, and `fly_profiling` all read the same credentials regardless of how the process is launched. Real environment variables always take precedence over `.env` (useful for CI).

> **Important:** If `.env` is missing and no `MPESA_DB_*` environment variables are set, `config.py` falls back to `127.0.0.1` and prints a warning — it will **not** silently connect to a remote server. Always keep a valid `.env` next to `config.py` on the server (`/var/www/server/parser/.env`).

Manual export is optional (e.g. for ad-hoc SQL tooling):

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
| `tbl_subscriber_profiles` | Risk segment, turnover segment, credit limit, and debt-to-income (DTI) metrics per customer. |
| `customer_credit_limit` | Latest approved credit limit per mobile number (maintained by `fly_profiling()`). |
| `tbl_rejection_reasons` | Ranked rejection reasons for `not_qualified` subscribers and `FRAUD_CRITICAL` hard rejections (see [Rejection reasons](#rejection-reasons)). |
| `tbl_phone_id` | Device / identity registry — links `mobile_number`, `phone_id`, `device_id`, and `national_id` for fraud linkage rules. Populated externally. |
| `tbl_fraud_rules` | Per-customer fraud evaluation — 12 rule flags, weighted score, decision tier, and JSON audit metrics (see [Fraud rules](#fraud-rules)). |
| `tbl_credit_limit_enhancements` | Limit enhancement evaluation results for returning borrowers (see [Credit limit enhancement](#credit-limit-enhancement)). |
| `tbl_LEM_rejection_reasons` | Ranked reasons why a limit increase was not granted (see [LEM rejection reasons](#lem-rejection-reasons)). |
| `schema_migrations` | Tracks which migration files have been applied and when. |

### Key columns — `customer_credit_limit`

| Column | Type | Notes |
|---|---|---|
| `mobile_number` | `VARCHAR(20)` | International format (`254xxx`) — consistent with all other tables |
| `credit_limit` | `INT` | Whole-number amounts (0, 5000, 8000, …) |
| `profiling_date` | `DATETIME` | When `fly_profiling()` last ran for this customer |
| `profiling_category` | `VARCHAR(20)` | `FTB1` (new), `FTB2` (returning), or `ENHANCED` (after limit increase applied) |

> **Note:** Early deployments stored `mobile_number` and `credit_limit` as `DECIMAL(18,4)`, causing values to display with thousands-separator commas (e.g. `254,722,123,456.0000`). Migrations `0014` and `0015` correct this automatically — `0015` also strips any `.0000` decimal artefacts left in existing rows after the column type change.

### Key columns — `tbl_subscriber_profiles` (DTI, migration `0017`)

| Column | Type | Notes |
|---|---|---|
| `total_inflow` | `DOUBLE` | KES sum of all positive M-PESA transactions in the last 6 months |
| `lender_inflow` | `DOUBLE` | KES sum of inflows matched to known digital lenders (6 months) |
| `debt_to_income_ratio` | `DECIMAL(7,4)` | `lender_inflow / total_inflow`; `NULL` when `total_inflow = 0` |
| `total_inflow_txn_count` | `BIGINT` | Count of positive transactions in the 6-month window |
| `lender_inflow_txn_count` | `BIGINT` | Count of digital-lender inflow transactions in the 6-month window |

Subscribers with `debt_to_income_ratio > 0.50` (50 %) are hard-gated to `not_qualified` by `fly_profiling()` regardless of scorecard outcome.

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
| `HIGH_DEBT_TO_INCOME` | `debt_to_income_ratio > 50 %` — digital-lender inflows dominate total inflows | 1 or 2 |
| `WEAK_SCORING_FEATURE` | The single scorecard feature with the highest score gap (most points lost vs. maximum) | 1 or 2 |
| `LOW_TURNOVER` | `turnover_segment` below the minimum required for the subscriber's `risk_segment` (risk 5–8 only) | 2, 3, or 4 |
| `HIGH_CREDIT_RISK` | `risk_segment ≤ 4` — score too low for any credit-limit assignment | 2, 3, or 4 |
| `FRAUD_CRITICAL` | Fraud score ≥ 80 in `tbl_fraud_rules` — independent hard rejection; not gated on `model_category` | 1 |

### Key columns — `tbl_credit_limit_enhancements`

| Column | Type | Notes |
|---|---|---|
| `customer_id` | `CHAR(36)` | LMS `aleza.customers.id` (UUID) |
| `mobile_number` | `VARCHAR(20)` | International format (`254xxx`) |
| `current_limit` | `INT` | Limit before enhancement (from `customer_credit_limit`) |
| `turnover_segment` | `TINYINT` | 1–8, derived from `three_month_wavg` (same thresholds as `fly_profiling`) |
| `limit_band` | `VARCHAR(20)` | `1k_5k`, `5k_10k`, `10k_20k`, `20k_30k`, or `30k_40k` |
| `enhancement_pct` | `DECIMAL(5,2)` | Matrix percentage (e.g. `40.00` = 40 %) |
| `enhanced_limit` | `INT` | `ROUND(current_limit × (1 + enhancement_pct / 100))` |
| `is_eligible` | `TINYINT(1)` | `1` only when all five eligibility gates pass and a matrix cell exists |
| `eligibility_detail` | `TEXT` | Semicolon-separated reasons when ineligible |
| `applied` | `TINYINT(1)` | `1` when `p_apply = 1` and the enhanced limit was written |
| `last_loan_days_late` | `INT` | Days between final due date and final payment on last closed loan |
| `max_arrears_days_1y` | `INT` | Peak `days_overdue` on any installment in the last 12 months |
| `limit_age_days` | `INT` | Days since `customer_credit_limit.profiling_date` |
| `fraud_decision` | `VARCHAR(20)` | Latest decision from `tbl_fraud_rules` |
| `debt_to_income_ratio` | `DECIMAL(7,4)` | Latest DTI from `tbl_subscriber_profiles` |

### Key columns — `tbl_LEM_rejection_reasons`

| Column | Type | Notes |
|---|---|---|
| `mobile_number` | `VARCHAR(20)` | Primary lookup key |
| `customer_id` | `CHAR(36)` | LMS `aleza.customers.id` (UUID) |
| `enhancement_id` | `BIGINT UNSIGNED` | FK to `tbl_credit_limit_enhancements.id` for this evaluation |
| `reason_rank` | `TINYINT UNSIGNED` | `1` = most impactful gate failure; dense-ranked among active failures |
| `reason_code` | `VARCHAR(60)` | Machine-readable LEM code (see [LEM rejection reasons](#lem-rejection-reasons)) |
| `reason_detail` | `TEXT` | Human-readable explanation for the credit analyst |
| `metric_name` | `VARCHAR(100)` | Gate metric that triggered the reason (e.g. `debt_to_income_ratio`) |
| `metric_value` | `DOUBLE` | Raw metric value at evaluation time |

**Rejection reason tables compared:**

| | Initial credit limit | Limit enhancement (LEM) |
|---|---|---|
| Audit table | `tbl_rejection_reasons` | `tbl_LEM_rejection_reasons` |
| Procedure | `sp_populate_rejection_reasons` | `sp_populate_LEM_rejection_reasons` |
| Triggered by | `sp_populate_fraud_rules` (after `fly_profiling`) | `sp_apply_credit_limit_enhancement` |
| Scope | `not_qualified` subscribers + `FRAUD_CRITICAL` | Customers with `is_eligible = 0` in `tbl_credit_limit_enhancements` |
| Idempotency | Per `reason_code` (append if missing) | Full refresh per scope on each enhancement run |

---

## Migrations

Migration files live in `db/migrations/` and are named `NNNN_description.sql` (must start with a digit — editor temp files are ignored). The runner tracks applied migrations in a `schema_migrations` table so each file runs exactly once per database.

Statements are split on `;` outside single-quoted strings, so semicolons inside `COMMENT '...'` text are safe. Migration files must still be **UTF-8** encoded (avoid Windows-1252 characters such as smart dashes).

### Adding a new migration

1. Create `db/migrations/NNNN_description.sql` with the next available number.
2. Write plain SQL — `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE`, `UPDATE`, etc.
3. Save the file as UTF-8. Prefer ASCII hyphens in comments; avoid semicolons inside quoted strings when possible.
4. Run `python db/migrate.py` to apply it locally, then commit.

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
2. Computes 6-month inflow totals and a debt-to-income ratio (`lender_inflow / total_inflow`) from digital-lender dictionary matches.
3. Scores features against a risk scorecard and a turnover scorecard.
4. Assigns a `credit_limit` based on the combined `risk_segment` × `turnover_segment` matrix (see below).
5. Sets `model_category = 'qualified'` **only when `credit_limit > 0`**, so qualification always matches an actual limit assignment.
6. Hard-gates subscribers to `not_qualified` when `debt_to_income_ratio > 50 %`.
7. Writes results to `tbl_scoring_features`, `tbl_subscriber_profiles`, and `customer_credit_limit`.
8. Calls `sp_populate_fraud_rules(<mobile_number>)`, which evaluates all 12 fraud rules, writes `tbl_fraud_rules`, then calls `sp_populate_rejection_reasons` for credit gates and `FRAUD_CRITICAL` rejections.

Stored procedures in `db/procedures/` are (re)deployed on every startup via `python -m db.deploy_procedures` (also run automatically by `ensure_table_exists()`). Edit a `.sql` file and redeploy to pick up changes.

| Procedure | When it runs | Purpose |
|---|---|---|
| `fly_profiling` | After every successful PDF parse | Initial credit scoring and limit assignment |
| `sp_populate_fraud_rules` | End of `fly_profiling` | 12-rule fraud evaluation → `tbl_fraud_rules` |
| `sp_populate_rejection_reasons` | End of `sp_populate_fraud_rules` | Ranked rejection reasons + `FRAUD_CRITICAL` |
| `sp_apply_credit_limit_enhancement` | On demand / scheduled (not auto on parse) | Limit increase for eligible returning borrowers |
| `sp_populate_LEM_rejection_reasons` | End of `sp_apply_credit_limit_enhancement` | Ranked reasons for ineligible limit increases |

### Credit limit matrix

A subscriber must have at least **90 days** of statement history (`age_days ≥ 90`) before any limit is assigned. Qualifying combinations:

| Risk segment | Min turnover segment | Credit limit (KES) |
|---|---|---|
| 8 | 5 | 5,000 |
| 8 | 6 | 6,000 |
| 8 | 7 | 7,000 |
| 8 | 8 | 8,000 |
| 7 | 6 | 5,000 |
| 7 | 7 | 6,000 |
| 7 | 8 | 8,000 |
| 6 | 7 | 5,000 |
| 6 | 8 | 6,000 |
| 5 | 8 | 5,000 |

All other risk × turnover combinations receive `credit_limit = 0` and `model_category = 'not_qualified'`. Risk segments 1–4 never receive a limit regardless of turnover.

### Rejection reasons

`sp_populate_rejection_reasons` is invoked automatically at the end of `sp_populate_fraud_rules` (which `fly_profiling` calls after scoring). You can also run it directly for backfill:

```sql
-- Single subscriber (called automatically via sp_populate_fraud_rules)
CALL sp_populate_rejection_reasons('254722123456');

-- Batch backfill for all pending rejections
CALL sp_populate_rejection_reasons(NULL);
```

The procedure is idempotent — it only inserts reason codes that do not yet exist for a given `mobile_number`. Re-running it after new rejections accumulate is safe.

For each subscriber it inserts up to six ranked reasons, derived entirely from data already in the database:

| Priority | Source | What it tells you |
|---|---|---|
| **1 — `INSUFFICIENT_HISTORY`** | `tbl_subscriber_profiles.age_days` | Statement history < 90 days; the subscriber simply needs to wait |
| **1–2 — `HIGH_DEBT_TO_INCOME`** | `tbl_subscriber_profiles.debt_to_income_ratio` | Digital-lender inflows exceed 50 % of total inflows — hard gate from `fly_profiling()` |
| **1–3 — `WEAK_SCORING_FEATURE`** | `tbl_scoring_features` (latest row) | The one scorecard feature that lost the most points relative to its maximum — the highest-leverage behaviour to improve |
| **2–4 — `LOW_TURNOVER`** | `tbl_subscriber_profiles` | Turnover below the minimum for the subscriber's risk segment (risk 5–8 only; see matrix above) |
| **2–4 — `HIGH_CREDIT_RISK`** | `tbl_subscriber_profiles` | Risk segment ≤ 4 — no credit limit is assigned at any turnover level |
| **1 — `FRAUD_CRITICAL`** | `tbl_fraud_rules` | Fraud score ≥ 80 — hard rejection independent of credit qualification; lists triggered fraud rules |

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

The procedure source lives at `db/procedures/sp_populate_rejection_reasons.sql`. Table DDL is in migration `0016`; DTI columns on `tbl_subscriber_profiles` are added by migration `0017`.

### Fraud rules

`sp_populate_fraud_rules(<mobile_number>)` evaluates 12 weighted fraud rules against `tbl_raw_mpesa_statements` (6-month window anchored on each customer's latest transaction date) and writes one row per customer to `tbl_fraud_rules`. Pass `NULL` to re-evaluate all customers in batch mode.

```sql
-- Single subscriber (called automatically by fly_profiling)
CALL sp_populate_fraud_rules('254722123456');

-- Batch re-evaluation for all customers
CALL sp_populate_fraud_rules(NULL);
```

At the end of each run the procedure calls `sp_populate_rejection_reasons`, which inserts `FRAUD_CRITICAL` for any customer whose fraud decision is `Reject`.

**Decision thresholds** (sum of triggered rule weights):

| Score | Decision | Action |
|---|---|---|
| 0 – 39 | Approve | Standard automated credit assignment |
| 40 – 59 | Reduce Limit | Moderate risk — truncate limit 50–70 % for first cycle |
| 60 – 79 | Manual Review | Hold disbursement for secondary verification |
| 80+ | Reject | Hard rejection; `FRAUD_CRITICAL` reason inserted |

**Rules and weights:**

| Category | Rule | Weight |
|---|---|---|
| Identity & Device | Device Multi-ID Linkage — device linked to > 3 unique National IDs in 90 days (`tbl_phone_id`) | 40 |
| Identity & Device | SIM/Phone Recency — statement span (`MAX` − `MIN` transaction date) < 90 days | 25 |
| Statement & Velocity | Network Concentration — bidirectional P2P with same entity > 5×/month and net amount diff < 10 % | 30 |
| Statement & Velocity | Circular Cash Movement — monthly received ≈ monthly sent (≤ 5 % variance) | 20 |
| Statement & Velocity | Shared Counterparties — P2P sender funding > 5 distinct borrowers | 20 |
| Statement & Velocity | Sudden Income Inflation — 1-month inflow / (6-month inflow ÷ 6) > 3 | 15 |
| Credit Distress | Borrowing for Betting — loan disbursement followed by betting within 48 hours | 20 |
| Credit Distress | Loan Cycling — > 3 rapid disburse → repay → re-borrow cycles | 15 |
| Credit Distress | High Gambling Exposure — betting outflows / total outflows > 30 % (1 month) | 15 |
| Credit Distress | Active Loan Stacking — > 3 unrealised loan disbursements (6 months) | 15 |
| Credit Distress | Excessive Borrowing Dependency — loan disbursements / total inflows > 50 % (6 months) | 10 |
| Credit Distress | High Volume, Low Balance — average 1-month balance < 5 % of monthly inflows | 10 |

Digital-lender disbursements use the same dictionary as the DTI calculation in `fly_profiling` (Fuliza, Tala, Branch, OKash, Hustler Fund, etc.).

**Key columns — `tbl_fraud_rules`:**

| Column | Notes |
|---|---|
| `flag_*` (12 columns) | Boolean flag per rule |
| `total_score` | Sum of weights for triggered rules |
| `decision` | `Approve`, `Reduce Limit`, `Manual Review`, or `Reject` |
| `triggered_rules` | Pipe-separated list of triggered rule names and weights |
| `metrics` | JSON audit payload (inflow ratios, cycle counts, device ID count, etc.) |

Table DDL is in migration `0019`. Procedure source: `db/procedures/sp_populate_fraud_rules.sql`.

> **Note:** `tbl_phone_id` must be populated by an external identity/device capture system for the Device Multi-ID Linkage rule to fire. Fraud tiers `Reduce Limit` and `Manual Review` are recorded in `tbl_fraud_rules` but do not yet modify `credit_limit` in `fly_profiling` — only `Reject` (≥ 80) writes to `tbl_rejection_reasons`.

### Credit limit enhancement

`sp_apply_credit_limit_enhancement(p_mobile_number, p_apply)` evaluates returning borrowers against the **Credit Limit Enhancement Matrix** (current limit band on the Y-axis × turnover segment on the X-axis). Results are written to `tbl_credit_limit_enhancements`. The procedure joins parser tables in `Data_Science` with LMS loan tables in the `aleza` database on the same MySQL host.

**Signature:**

```sql
CALL sp_apply_credit_limit_enhancement(p_mobile_number, p_apply);
```

| Parameter | Type | Description |
|---|---|---|
| `p_mobile_number` | `VARCHAR(20)` | Customer mobile (`254xxx`), or `NULL` for batch (all customers with `credit_limit >= 1000`) |
| `p_apply` | `TINYINT(1)` | `0` or `NULL` = evaluate only; `1` = also update `aleza.credit_profiles` and `customer_credit_limit` (both parameters are required — MySQL does not support parameter defaults) |

**Data sources:**

| Domain | Tables | Database |
|---|---|---|
| Parser / analytics | `customer_credit_limit`, `tbl_subscriber_profiles`, `tbl_fraud_rules` | `Data_Science` |
| Loan management | `customers`, `loans`, `loan_schedules`, `credit_profiles` | `aleza` |

**Eligibility gates (all required):**

| # | Condition | Source |
|---|---|---|
| 1 | Last closed loan repaid ≤ 3 days after final installment due date | `aleza.loans`, `aleza.loan_schedules` |
| 2 | No loan in the last 12 months had any installment > 90 days overdue | `aleza.loan_schedules.days_overdue` |
| 3 | Current limit held for ≥ 14 days | `customer_credit_limit.profiling_date` |
| 4 | Not fraud-flagged (`Reject` or `Manual Review`) | `tbl_fraud_rules` |
| 5 | Debt-to-income ratio < 50 % (not actively lender-dependent) | `tbl_subscriber_profiles.debt_to_income_ratio` |

Customers with no closed loan fail gate 1 (`No closed loan on record`).

**Turnover segments** (X-axis — same `three_month_wavg` thresholds as `fly_profiling`):

| Segment | 3-month weighted avg turnover (KES) | Label |
|---|---|---|
| 8 | > 107,556 | > 153k |
| 7 | > 60,463 | 107k |
| 6 | > 39,179 | 60k |
| 5 | > 23,895 | 39k |
| 4 | > 16,027 | 23k |
| 3 | > 12,561 | 16k |
| 2 | > 9,841 | 12k |
| 1 | ≤ 9,841 | 9k |

**Limit bands** (Y-axis — based on `customer_credit_limit.credit_limit`):

| Band | Range (KES) |
|---|---|
| `1k_5k` | 1,000 – 5,000 |
| `5k_10k` | 5,001 – 10,000 |
| `10k_20k` | 10,001 – 20,000 |
| `20k_30k` | 20,001 – 30,000 |
| `30k_40k` | 30,001 – 40,000 |

**Enhancement matrix** (% increase applied to `current_limit`):

| Limit band \ Turnover | 8 | 7 | 6 | 5 | 4 | 3 | 2 | 1 |
|---|---|---|---|---|---|---|---|---|
| 30k–40k | 10 % | 5 % | — | — | — | — | — | — |
| 20k–30k | 20 % | 10 % | 5 % | — | — | — | — | — |
| 10k–20k | 30 % | 20 % | 8 % | 10 % | — | — | — | — |
| 5k–10k | 40 % | 30 % | 20 % | 15 % | 3 % | — | — | — |
| 1k–5k | 60 % | 50 % | 50 % | 40 % | 30 % | 20 % | 5 % | — |

Empty cells mean no enhancement is available for that combination.

The matrix percentage is an **increment on top of** the current limit, not a replacement factor:

```
enhanced_limit = ROUND(current_limit × (1 + enhancement_pct / 100))
```

Example: limit KES 1,000 in band `1k_5k` at turnover segment 8 (60 %) → `1,000 × 1.60 = 1,600`.

After each evaluation, `sp_populate_LEM_rejection_reasons` is called automatically. Ineligible customers (`is_eligible = 0`) receive one or more ranked rows in `tbl_LEM_rejection_reasons`; eligible customers receive none.

**Examples:**

```sql
-- Evaluate one customer (dry run)
CALL sp_apply_credit_limit_enhancement('254722123456', 0);

-- Batch evaluate all customers with limit >= 1 000
CALL sp_apply_credit_limit_enhancement(NULL, 0);

-- Evaluate and apply (writes enhanced limit)
CALL sp_apply_credit_limit_enhancement('254722123456', 1);

-- Review eligible customers
SELECT mobile_number, current_limit, turnover_segment, enhancement_pct,
       enhanced_limit
FROM   tbl_credit_limit_enhancements
WHERE  is_eligible = 1
ORDER  BY evaluated_at DESC;

-- Review ineligible customers with ranked LEM rejection reasons
SELECT e.mobile_number, e.current_limit, e.is_eligible,
       r.reason_rank, r.reason_code, r.reason_detail
FROM   tbl_credit_limit_enhancements e
JOIN   tbl_LEM_rejection_reasons r ON r.enhancement_id = e.id
WHERE  e.is_eligible = 0
ORDER  BY e.evaluated_at DESC, r.reason_rank;
```

When `p_apply = 1` and the customer is eligible, the procedure updates:

- `aleza.credit_profiles.credit_limit` and `available_credit`
- `customer_credit_limit.credit_limit` with `profiling_category = 'ENHANCED'`

Table DDL: migration `0020`. Procedure: `db/procedures/sp_apply_credit_limit_enhancement.sql`.

> **Note:** Change the `aleza.` schema prefix in the procedure if your LMS database name differs on the server (production host `65.20.86.247:3306`).

### LEM rejection reasons

When `sp_apply_credit_limit_enhancement` marks a customer as ineligible (`is_eligible = 0`), it calls `sp_populate_LEM_rejection_reasons`, which writes ranked explanations to `tbl_LEM_rejection_reasons` — mirroring how `sp_populate_rejection_reasons` explains initial credit-limit rejections.

Reasons are refreshed on each enhancement run (prior rows for the scope are deleted, then re-inserted from the latest `tbl_credit_limit_enhancements` evaluation).

**Reason codes, in priority order:**

| Code | Condition | Typical rank |
|---|---|---|
| `LEM_FRAUD_FLAG` | `tbl_fraud_rules.decision` is `Reject` or `Manual Review` | 1 |
| `LEM_EXCESSIVE_ARREARS` | Any loan in last 12 months exceeded 90 days overdue | 1 or 2 |
| `LEM_NO_CLOSED_LOAN` | No closed loan on record | 1 – 3 |
| `LEM_LATE_LOAN_REPAYMENT` | Last loan repaid > 3 days after final due date | 1 – 3 |
| `LEM_HIGH_DEBT_TO_INCOME` | `debt_to_income_ratio` ≥ 50 % | 1 – 4 |
| `LEM_LIMIT_TENURE_INSUFFICIENT` | Current limit held < 14 days | 1 – 5 |
| `LEM_NO_MATRIX_CELL` | No enhancement % for limit band × turnover segment | 1 – 6 |

```sql
-- Called automatically by sp_apply_credit_limit_enhancement; can also run standalone:
CALL sp_populate_LEM_rejection_reasons('254722123456');
CALL sp_populate_LEM_rejection_reasons(NULL);

-- Review why a customer was not increased
SELECT reason_rank, reason_code, reason_detail, metric_name, metric_value
FROM   tbl_LEM_rejection_reasons
WHERE  mobile_number = '254722123456'
ORDER  BY reason_rank;
```

Table DDL: migration `0021`. Procedure: `db/procedures/sp_populate_LEM_rejection_reasons.sql`.

Rank increments when multiple gates fail — e.g. a customer who fails both fraud and DTI checks receives `LEM_FRAUD_FLAG` at rank 1 and `LEM_HIGH_DEBT_TO_INCOME` at rank 2.

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

### Test suite

Tests run without a live database. The suite includes:

| Module | What it covers |
|---|---|
| `tests/test_config.py` | Mobile number normalisation, transaction type mapping |
| `tests/test_parser.py` | PDF parsing, manifest hashing, metadata attachment |
| `tests/test_parse_single.py` | Phone validation and balance continuity checks |
| `tests/test_profiling_procedures.py` | Credit limit matrix, `model_category` alignment, rejection reason thresholds, fraud/enhancement/LEM procedure wiring, and SQL procedure source checks |

Credit-scoring rule tests use `tests/profiling_rules.py`, a Python reference implementation that mirrors the logic in `db/procedures/fly_profiling.sql` and `db/procedures/sp_populate_rejection_reasons.sql`. Run just the profiling tests:

```bash
pytest tests/test_profiling_procedures.py -v
```

---

## Deployment

The project deploys automatically to **production** (`65.20.86.247`) via GitHub Actions whenever a commit lands on `main` — typically when a pull request is merged.

### CI/CD pipeline

| Workflow | File | Trigger | What it does |
|---|---|---|---|
| **CI** | `.github/workflows/ci.yml` | Every push and pull request (all branches) | Lint with flake8 and run pytest on Python 3.11 and 3.12 |
| **Deploy** | `.github/workflows/deploy.yml` | Push to `main`, or manual **Run workflow** | SSH to `65.20.86.247` and execute `scripts/server-deploy.sh` |

**Recommended:** protect the `main` branch and require the **CI / Lint & Test** status checks to pass before merging, so only tested code reaches production.

Deploy jobs use a concurrency group (`production-deploy`) so overlapping deploys do not run in parallel.

### `server-deploy.sh` steps (on the server)

1. `git fetch` and reset `main` to `origin/main`.
2. Activate `.venv` (or `venv`) and run `pip install -r requirements.txt`.
3. Run `python db/migrate.py` — applies any pending migrations (idempotent; reads DB credentials from `.env`).
4. Run `python -m db.deploy_procedures` — redeploys all stored procedures from `db/procedures/` (also runs automatically on app startup via `ensure_table_exists()`).
5. (Optional) restart a `systemd` service — uncomment in the script if the parser runs as a persistent daemon.

### Required GitHub secrets

The production host (`65.20.86.247`) is set in the workflow file. Only SSH credentials are stored as secrets:

| Secret | Required | Description |
|---|---|---|
| `SSH_USER` | Yes | SSH login user on the production server (e.g. `root` or `deploy`) |
| `SSH_PRIVATE_KEY` | Yes | Private key whose public key is in `~/.ssh/authorized_keys` on the server |
| `SSH_PORT` | No | SSH port (defaults to `22`) |

Set these at: **Settings → Secrets and variables → Actions → Repository secrets**.

#### One-time deploy key setup

On your laptop, generate a key and follow the printed instructions:

```bash
bash scripts/setup-github-deploy-key.sh root
```

Then on **65.20.86.247** (as the same user as `SSH_USER`, e.g. `root`):

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# paste the public key line from the script output:
echo "ssh-ed25519 AAAA... github-actions-aleza-deploy" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Test before relying on GitHub Actions:

```bash
ssh -i ./gh_actions_deploy_key root@65.20.86.247
```

Copy the **private** key file contents into the `SSH_PRIVATE_KEY` secret (never commit the key file).

### Deploy failed: `unable to authenticate`

```
ssh: handshake failed: ssh: unable to authenticate, attempted methods [none publickey]
```

The workflow reached the server but the key was rejected. Check in order:

| Check | Fix |
|---|---|
| `SSH_PRIVATE_KEY` is the **private** key | Must include `BEGIN OPENSSH PRIVATE KEY` (or `BEGIN RSA PRIVATE KEY`), not `.pub` |
| Newlines preserved in the GitHub secret | Re-paste the full key; GitHub secrets support multiline values |
| Public key on the server | `cat ~/.ssh/authorized_keys` on the server must contain the matching `.pub` line |
| `SSH_USER` matches the account | Key must be in `/home/<SSH_USER>/.ssh/authorized_keys` (e.g. `root` → `/root/.ssh/`) |
| Permissions on the server | `chmod 700 ~/.ssh` and `chmod 600 ~/.ssh/authorized_keys` |
| `PubkeyAuthentication` enabled | In `/etc/ssh/sshd_config`, `PubkeyAuthentication yes` then `systemctl reload sshd` |
| Passphrase on the key | Use a key with empty passphrase (`-N ""` in `setup-github-deploy-key.sh`) |

After updating secrets or `authorized_keys`, re-run **Deploy to Production** from the Actions tab.

### Manual deploy

From the GitHub **Actions** tab, open **Deploy to Production** and click **Run workflow** (uses `workflow_dispatch`).

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
# Ubuntu: install venv support if python3 -m venv fails
apt install -y python3-venv python3-pip

python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

> **Note:** `scripts/server-deploy.sh` creates `.venv` automatically on deploy if it is missing. For the first deploy before that script is on `main`, create the venv once manually (commands above).

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
python -m db.deploy_procedures
```

This creates all tables and the `schema_migrations` tracking table, then deploys stored procedures (`fly_profiling`, `sp_populate_fraud_rules`, `sp_populate_rejection_reasons`).  If the tables already exist from a previous setup, run `--baseline` first:

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

| Item | Path / value |
|---|---|
| Production host | `65.20.86.247` |
| Application root | `/var/www/server/parser` |
| Virtualenv | `/var/www/server/parser/.venv` (or `venv`) |
| Environment file | `/var/www/server/parser/.env` (not tracked by git) |
| Deploy script | `/var/www/server/parser/scripts/server-deploy.sh` |

Runtime directories (`Mpesa_pdf_statement/`, `logs/`, `queue/`, etc.) must exist before the first parse job runs — see [Server initial setup](#server-initial-setup).

### Troubleshooting migrations on the server

```bash
cd /var/www/server/parser
source .venv/bin/activate
export $(cat .env | xargs)
python db/migrate.py --status        # see applied vs pending
python db/migrate.py                 # apply pending migrations
python -m db.deploy_procedures       # redeploy stored procedures after SQL edits
```

Common issues:

- **`UnicodeDecodeError`** — a migration file is not UTF-8; re-save as UTF-8 or replace non-ASCII characters in comments.
- **SQL syntax error near a `COMMENT`** — usually caused by an old runner splitting on `;` inside quoted strings; pull the latest `db/migrate.py` and ensure migration `0017` uses parentheses instead of a semicolon in the DTI column comment.
- **Duplicate column (1060)** — safe to re-run; the runner skips statements that are already in the desired state.
