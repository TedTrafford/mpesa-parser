# MPESA Statement Parser

This tool parses M-PESA PDF statements and extracts transaction data into CSV files with complete customer information.

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
python parse_single.py <record_id> <file_name> <pdf_path> <pin>
```

## Requirements

- Python 3.6+
- Required Python packages:
  - PyPDF2
  - pandas
  - re (built-in)

## Installation

### Option 1: Using Anaconda (Recommended)

```bash
# Create conda environment
conda create -n mpesa_parser python=3.9 -y

# Activate environment
conda activate mpesa_parser

# Install dependencies
pip install PyPDF2==3.0.1 "numpy<2.0" pandas==2.0.0
```

### Option 2: Using pip

```bash
pip install PyPDF2==3.0.1 pandas==2.0.0
```

## Directory Structure

```
.
├── Mpesa_pdf_statement/          # Input: Place PDF files here
├── Mpesa_csv_Statement_Parsed/   # Output: Successful CSVs and PDFs
├── Mpesa_csv_Statement_Failed/   # Failed: PDFs that couldn't be parsed
├── queue/                        # Runtime queue (git-ignored)
│   ├── pending/                  #   Jobs waiting to be processed
│   ├── done/                     #   Completed job descriptors
│   ├── failed/                   #   Failed job descriptors
│   └── worker.lock               #   Advisory lock (one worker at a time)
├── parser/                       # Parser module
│   └── mpesa_parser.py          # Core parser + process_single_file()
├── db/
│   ├── schema.sql                # MySQL table DDL
│   ├── uploader.py               # MySQL upload helper
│   └── features_207.sql          # 207-feature credit-scoring SQL query
├── config.py                     # Paths, DB credentials, regex patterns
├── parse_single.py               # Single-file queued parser (new)
├── process_all_pdfs.py          # Batch processor
├── run_parser.sh                # Quick batch-run script
├── requirements.txt             # Python dependencies
└── README.md                    # This file
```

## Configuration

All paths, patterns and transaction type mappings are centralized in `config.py`. If you need to modify:
- Input/output directories
- Transaction regex pattern
- Transaction type mappings

Edit the `config.py` file instead of modifying individual scripts.

## How to Use

### Option 1: Batch-process all PDFs (with Anaconda)

```bash
conda activate mpesa_parser
./run_parser.sh
```

Or directly:

```bash
python process_all_pdfs.py
```

### Option 2: Parse a single file with queueing (`parse_single.py`)

Use this when integrating with an external system (e.g. a web application)
that submits one statement at a time and may call the script concurrently.

```bash
python parse_single.py <record_id> <file_name> <pdf_path> <pin>
```

| Argument | Description |
|----------|-------------|
| `record_id` | Caller-supplied unique identifier (e.g. a database application ID). Stored in the `metadata` JSON column of every transaction row. |
| `file_name` | Original PDF filename (e.g. `310549.pdf`). The output CSV uses the same stem. |
| `pdf_path` | Path to the PDF file on disk. |
| `pin` | PDF password used to decrypt the M-PESA statement. |

**Examples:**

```bash
# Minimal call — record_id ties this parse back to your application record
python parse_single.py 12345 310549.pdf /tmp/statements/310549.pdf 310549

# Absolute path
python parse_single.py app-req-9f3a statement.pdf /var/uploads/statement.pdf 123456
```

**Concurrency behaviour:**

When multiple processes call `parse_single.py` at the same time each one
atomically writes a job file to `queue/pending/` and then attempts to acquire
an exclusive advisory lock (`queue/worker.lock`).

- The **first caller** that wins the lock becomes the worker and processes all
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

## Features

- Extracts transaction details including:
  - **Customer Name** (e.g., Monica Atieno Ondoo)
  - **Mobile Number** (e.g., 0112850906)
  - **Email Address** (e.g., info@aleza.co.ke)
  - **Statement Period** (e.g., 14 Aug 2024 - 14 Feb 2025)
  - **Request Date** (e.g., 14 Feb 2025)
  - Date and time of transaction
  - Receipt number
  - Transaction type
  - Transaction details
  - Amount
  - Balance
- Handles line breaks in transaction data
- Automatically extracts 6-digit password from PDF filename
- Supports multiple filename formats:
  - Pure numbers: `123456.pdf` → password is `123456`
  - With text prefix: `Maniga123456.pdf` → password is `123456`
  - Old format: `123456_something.pdf` → password is `123456`
- Supports batch processing of multiple PDF files
- Automatically organizes files after processing:
  - Successful: PDFs and CSVs moved to `Mpesa_csv_Statement_Parsed/`
  - Failed: PDFs moved to `Mpesa_csv_Statement_Failed/`
- Centralized configuration for easy customization
- Detailed processing summary showing successes and failures

## CSV Output Format

Each CSV file contains **13 columns** with complete customer and transaction information:

| Column | Description | Example |
|--------|-------------|---------|
| Customer Name | Account holder name | Monica Atieno Ondoo |
| Mobile Number | M-PESA number | 0112850906 |
| Email Address | Email on account | info@aleza.co.ke |
| Statement Period | Date range | 14 Aug 2024 - 14 Feb 2025 |
| Request Date | Statement generated | 14 Feb 2025 |
| Date | Transaction date | 2025-02-14 |
| Time | Transaction time | 14:30:45 |
| Receipt No | M-PESA receipt | TJEKA7E3VO |
| Transaction Type | Category | SEND MONEY |
| Details | Full description | Customer Transfer to... |
| Amount | Transaction amount | -1500.0 |
| Balance | Balance after | 5432.10 |
| metadata | JSON with parse provenance | see below |

### `metadata` column

Every row carries a `metadata` JSON object:

```json
{
  "manifest_hash":    "85779f75f98d0eed022ccd597cc7845f",
  "pin":              "310549",
  "record_uuid":      "3829cdd5-6e40-4be4-bf9a-3b35dfca8ebd",
  "output_file_path": "/path/to/Mpesa_csv_Statement_Parsed/310549.csv",
  "record_id":        "12345"
}
```

| Key | Set by | Description |
|-----|--------|-------------|
| `manifest_hash` | parser | MD5 of filename + file contents — changes if the file is replaced |
| `pin` | parser | PDF stem (the M-PESA PIN used as password) |
| `record_uuid` | parser | UUID4 unique to this transaction row |
| `output_file_path` | parser | Absolute path to the output CSV |
| `record_id` | caller | The `record_id` argument passed to `parse_single.py` (omitted when the parser is invoked directly) |

## Troubleshooting

If you encounter errors:

1. **Module not found**: Make sure conda environment is activated
   ```bash
   conda activate mpesa_parser
   pip install PyPDF2==3.0.1 "numpy<2.0" pandas==2.0.0
   ```

2. **Numpy compatibility errors**: Reinstall with correct version
   ```bash
   pip uninstall -y numpy pandas
   pip install "numpy<2.0" pandas==2.0.0
   ```

3. **Password errors**: Verify filename contains 6-digit number
   - Pure numbers: `288720.pdf` → password is `288720`
   - With text: `Maniga953060.pdf` → password is `953060`
   - Old format: `123456_statement.pdf` → password is `123456`

4. **Processing stops**: Re-run the script - already processed files have been moved
   ```bash
   ./run_parser.sh
   ```

## Customization

To add new transaction types or modify existing ones, edit the `TRANSACTION_TYPES` dictionary in `config.py`. 