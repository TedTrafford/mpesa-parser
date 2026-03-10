# MPESA Statement Parser

This tool parses M-PESA PDF statements and extracts transaction data into CSV files with complete customer information.

## Quick Start

```bash
# 1. Create and activate conda environment
conda create -n mpesa_parser python=3.9 -y
conda activate mpesa_parser

# 2. Install dependencies
pip install PyPDF2==3.0.1 "numpy<2.0" pandas==2.0.0

# 3. Place your PDF files in Mpesa_pdf_statement/

# 4. Run the parser
./run_parser.sh
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
├── parser/                       # Parser module
│   └── mpesa_parser.py          # Main parser script
├── config.py                     # Configuration file
├── process_all_pdfs.py          # Batch processor
├── run_parser.sh                # Quick run script
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

### Option 1: Process all PDF statements at once (with Anaconda)

```bash
# Make sure conda environment is activated
conda activate mpesa_parser

# Run the parser using the provided script
./run_parser.sh
```

OR run directly:

```bash
conda activate mpesa_parser
python process_all_pdfs.py
```

### Option 2: Without Anaconda

```bash
python3 process_all_pdfs.py
```

### Option 2: Process a single PDF file

```bash
python parser/mpesa_parser.py <pdf_path> [output_csv] [password]
```

Examples:

```bash
# Process a single file with pure number filename
python parser/mpesa_parser.py Mpesa_pdf_statement/288720.pdf

# Process a file with text prefix
python parser/mpesa_parser.py Mpesa_pdf_statement/Maniga953060.pdf

# Process a single file with old naming format
python parser/mpesa_parser.py Mpesa_pdf_statement/123456_MPESA_Statement.pdf

# Specify output location and password explicitly
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

Each CSV file contains **12 columns** with complete customer and transaction information:

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