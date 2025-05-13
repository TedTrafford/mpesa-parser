# MPESA Statement Parser

This tool parses M-PESA PDF statements and extracts transaction data into CSV files.

## Requirements

- Python 3.6+
- Required Python packages:
  - PyPDF2
  - pandas
  - re (built-in)

## Installation

```bash
pip install PyPDF2 pandas
```

## Directory Structure

- `Mpesa_pdf_statement/` - Place your PDF files here
- `Mpesa_csv_Statement_Parsed/` - CSV output will be saved here
- `debug/` - Debug files (extracted text and processed text)
- `parser/` - Contains the main parser script
- `config.py` - Configuration file with paths and patterns

## Configuration

All paths, patterns and transaction type mappings are centralized in `config.py`. If you need to modify:
- Input/output directories
- Transaction regex pattern
- Transaction type mappings

Edit the `config.py` file instead of modifying individual scripts.

## How to Use

### Option 1: Process all PDF statements at once

Run the shell script:

```bash
./parse_pdfs.sh
```

OR

Run the Python batch processor:

```bash
./process_all_pdfs.py
```

### Option 2: Process a single PDF file

```bash
python parser/mpesa_parser.py <pdf_path> [output_csv] [password]
```

Examples:

```bash
# Process a single file with default output location
python parser/mpesa_parser.py Mpesa_pdf_statement/123456_MPESA_Statement.pdf

# Specify output location and password
python parser/mpesa_parser.py Mpesa_pdf_statement/123456_MPESA_Statement.pdf output.csv 123456
```

## Features

- Extracts transaction details including:
  - Date and time
  - Receipt number
  - Transaction type
  - Transaction details
  - Amount
  - Balance
- Handles line breaks in transaction data
- Automatically extracts password from PDF filename
- Supports batch processing of multiple PDF files
- Centralized configuration for easy customization

## Troubleshooting

If you encounter errors:

1. Check the debug directory for extracted text and processed text files
2. Ensure PDF files are not corrupted and are valid M-PESA statements
3. Verify that the password (numbers before first underscore in filename) is correct

## Customization

To add new transaction types or modify existing ones, edit the `TRANSACTION_TYPES` dictionary in `config.py`. 