import PyPDF2
import pandas as pd
import re
from datetime import datetime
import os
import glob
import sys
import hashlib
import uuid
import json

# Add parent directory to path to import config and db package
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import (
    INPUT_DIR, OUTPUT_DIR, FAILED_DIR,
    TRANSACTION_PATTERN, get_transaction_type, DATE_FORMAT,
)
from db.uploader import upload_to_mysql

# Global variable for password from command line
PASSWORD = None


def compute_manifest_hash(pdf_path):
    """
    Compute an MD5 hash over the combination of the filename bytes and the raw
    file content bytes.  This produces a single fingerprint that changes if
    either the filename or the file contents change, making it suitable for
    sync / dedup checks.
    """
    filename_bytes = os.path.basename(pdf_path).encode("utf-8")
    with open(pdf_path, "rb") as f:
        file_bytes = f.read()
    digest = hashlib.md5(filename_bytes + file_bytes).hexdigest()
    return digest


def get_pdf_password(pdf_path):
    """
    Extract password from PDF filename.
    The password is a 6-digit number that can appear in different formats:
    1. Pure number: 123456.pdf -> password is 123456
    2. With text prefix: Maniga123456.pdf -> password is 123456 (6-digit number)
    3. Old format with underscore: 123456_something.pdf -> password is 123456
    """
    if PASSWORD:
        return PASSWORD
        
    filename = os.path.basename(pdf_path)
    # Remove .pdf extension
    base_name = filename.replace('.pdf', '')
    
    # Check if filename contains underscore (old format)
    if '_' in base_name:
        # Old format: Extract numbers before the first underscore
        password = base_name.split('_')[0]
    else:
        # Try to extract 6-digit number from the filename
        match = re.search(r'\d{6}', base_name)
        if match:
            password = match.group()
        else:
            # If no 6-digit number found, use the entire filename
            password = base_name
    
    return password

def extract_text_from_pdf(pdf_path):
    """Extract text from PDF file."""
    password = get_pdf_password(pdf_path)
    print(f"Attempting to open PDF with password: {password}")
    
    with open(pdf_path, 'rb') as file:
        reader = PyPDF2.PdfReader(file)
        # Decrypt the PDF using the password
        if reader.is_encrypted:
            reader.decrypt(password)
        text = ""
        for page in reader.pages:
            text += page.extract_text()
    
    print(f"Extracted text length: {len(text)} characters")
    print("First 200 characters of extracted text:")
    print(text[:200])
    
    return text

def extract_customer_info(text):
    """Extract customer information from MPESA statement header."""
    customer_info = {
        'Customer Name': '',
        'Mobile Number': '',
        'Email Address': '',
        'Statement Period': '',
        'Request Date': ''
    }
    
    # Extract customer name
    name_match = re.search(r'Customer Name:\s*(.+)', text)
    if name_match:
        customer_info['Customer Name'] = name_match.group(1).strip()
    
    # Extract mobile number
    mobile_match = re.search(r'Mobile Number:\s*(\d+)', text)
    if mobile_match:
        customer_info['Mobile Number'] = mobile_match.group(1).strip()
    
    # Extract email address
    email_match = re.search(r'Email Address:\s*(.+)', text)
    if email_match:
        customer_info['Email Address'] = email_match.group(1).strip()
    
    # Extract statement period
    period_match = re.search(r'Statement Period:\s*(.+)', text)
    if period_match:
        customer_info['Statement Period'] = period_match.group(1).strip()
    
    # Extract request date
    request_match = re.search(r'Request Date:\s*(.+)', text)
    if request_match:
        customer_info['Request Date'] = request_match.group(1).strip()
    
    return customer_info

def parse_mpesa_statement(text, pdf_path):
    """Parse MPESA statement text into structured data."""
    print("Extracting customer information...")
    
    # Extract customer metadata
    customer_info = extract_customer_info(text)
    print(f"Customer: {customer_info['Customer Name']}")
    print(f"Mobile: {customer_info['Mobile Number']}")
    print(f"Period: {customer_info['Statement Period']}")
    
    print("Preprocessing text to handle split transaction lines...")
    
    # First, preprocess the text to join split transaction lines
    lines = text.split('\n')
    processed_lines = []
    i = 0
    
    while i < len(lines):
        line = lines[i].strip()
        
        # If the line starts with a receipt number (format like QAxx...)
        if re.match(r'^[A-Z0-9]{10}\s+\d{4}-\d{2}-\d{2}', line):
            # This is the start of a transaction
            current_line = line
            
            # Look ahead to see if the next line is a continuation (doesn't start with a receipt number)
            j = i + 1
            while j < len(lines) and not re.match(r'^[A-Z0-9]{10}\s+\d{4}-\d{2}-\d{2}', lines[j]) and lines[j].strip():
                current_line += " " + lines[j].strip()
                j += 1
            
            processed_lines.append(current_line)
            i = j  # Skip the lines we've already processed
        else:
            # Not a transaction line, add it as is
            if line:  # Only add non-empty lines
                processed_lines.append(line)
            i += 1
    
    # Join the processed lines back into text
    processed_text = '\n'.join(processed_lines)
    
    
    # Use the regex pattern from config to match transactions
    transactions = []
    matches = re.findall(TRANSACTION_PATTERN, processed_text, re.MULTILINE)
    print(f"Found {len(matches)} transactions in the statement")
    
    for match in matches:
        try:
            receipt_no, timestamp, details, amount_str, balance_str = match
            
            # Clean up the details field
            details = details.replace("Completed", "").replace("Failed", "").strip()
            
            # Convert timestamp string to datetime object
            date_obj = datetime.strptime(timestamp.split()[0], DATE_FORMAT)
            time_str = timestamp.split()[1]
            
            # Process amount - might be negative or have commas
            amount_str = amount_str.replace(',', '')
            amount = float(amount_str)
            
            # Process balance - might have commas
            balance_str = balance_str.replace(',', '')
            balance = float(balance_str)
            
            # Get transaction type using function from config
            trans_type = get_transaction_type(details)
            
            transactions.append({
                'Customer Name': customer_info['Customer Name'],
                'Mobile Number': customer_info['Mobile Number'],
                'Email Address': customer_info['Email Address'],
                'Statement Period': customer_info['Statement Period'],
                'Request Date': customer_info['Request Date'],
                'Date': date_obj,
                'Time': time_str,
                'Receipt No': receipt_no,
                'Transaction Type': trans_type,
                'Details': details.strip(),
                'Amount': amount,
                'Balance': balance
            })
                
        except Exception as e:
            print(f"Error processing transaction {receipt_no if 'receipt_no' in locals() else 'unknown'}: {str(e)}")
    
    print(f"Successfully processed {len(transactions)} transactions")
    return transactions

def _attach_metadata(df, pdf_path, output_csv):
    """
    Append a 'metadata' column to *df* containing a JSON object per row with:

    - manifest_hash   : MD5 of (filename bytes + file content bytes)
    - pin             : source filename without the .pdf extension
    - record_uuid     : a unique UUID4 for this individual transaction row
    - output_file_path: absolute path to the CSV file where this row is stored
    """
    manifest_hash = compute_manifest_hash(pdf_path)
    pin = os.path.splitext(os.path.basename(pdf_path))[0]
    abs_output = os.path.abspath(output_csv)

    df["metadata"] = [
        json.dumps(
            {
                "manifest_hash": manifest_hash,
                "pin": pin,
                "record_uuid": str(uuid.uuid4()),
                "output_file_path": abs_output,
            },
            separators=(",", ":"),
        )
        for _ in range(len(df))
    ]
    return df


def process_pdf_file(pdf_path):
    """Process a single PDF file and save the output to CSV."""
    print(f"\nProcessing PDF file: {pdf_path}")
    
    # Extract text from PDF
    text = extract_text_from_pdf(pdf_path)
    
    # Parse transactions
    transactions = parse_mpesa_statement(text, pdf_path)
    
    if not transactions:
        print("No transactions were parsed from the PDF")
        return None
    
    # Create DataFrame
    df = pd.DataFrame(transactions)
    df["Record ID"] = ""        # no caller-supplied record_id in batch mode

    # Create output directory if it doesn't exist
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Save to CSV with same name as PDF but with .csv extension
    base_filename = os.path.basename(pdf_path)
    output_csv = os.path.join(OUTPUT_DIR, base_filename.replace('.pdf', '.csv'))

    df = _attach_metadata(df, pdf_path, output_csv)

    df.to_csv(output_csv, index=False)
    print(f"Data saved to {output_csv}")

    df.attrs["upload_result"] = upload_to_mysql(df)

    # Display DataFrame summary
    print(f"Total transactions in CSV: {len(df)}")
    print("\nFirst few transactions:")
    print(df.head())

    return df

def process_single_file(pdf_path, output_csv=None, password=None, record_id=None):
    """Process a single PDF file with optional parameters.

    Parameters
    ----------
    pdf_path   : path to the PDF file
    output_csv : explicit output CSV path; defaults to OUTPUT_DIR/<stem>.csv
    password   : PDF decryption password; falls back to filename-derived PIN
    record_id  : caller-supplied unique identifier stored in the record_id DB column
    """
    global PASSWORD
    PASSWORD = password

    # Extract text from PDF
    text = extract_text_from_pdf(pdf_path)

    # Parse transactions
    transactions = parse_mpesa_statement(text, pdf_path)

    if not transactions:
        print("No transactions were parsed from the PDF")
        return None

    # Create DataFrame
    df = pd.DataFrame(transactions)
    df["Record ID"] = str(record_id) if record_id is not None else ""

    # Save to CSV
    if output_csv:
        df = _attach_metadata(df, pdf_path, output_csv)
        df.to_csv(output_csv, index=False)
        print(f"Data saved to {output_csv}")
    else:
        base_filename = os.path.basename(pdf_path)
        default_output = os.path.join(OUTPUT_DIR, base_filename.replace('.pdf', '.csv'))
        df = _attach_metadata(df, pdf_path, default_output)
        df.to_csv(default_output, index=False)
        print(f"Data saved to {default_output}")

    df.attrs["upload_result"] = upload_to_mysql(df)

    print(f"Total transactions in CSV: {len(df)}")
    print("\nFirst few transactions:")
    print(df.head())

    return df

def main():
    """
    Main function that can be called with arguments or run directly.
    
    Usage:
    1. No arguments: Process all PDFs in the default input directory
    2. With arguments: 
       python mpesa_parser.py <pdf_path> [output_csv] [password]
    """
    # Check for command line arguments
    if len(sys.argv) > 1:
        pdf_path = sys.argv[1]
        output_csv = sys.argv[2] if len(sys.argv) > 2 else None
        password = sys.argv[3] if len(sys.argv) > 3 else None
        
        print(f"Using command-line arguments: PDF={pdf_path}, OUTPUT={output_csv}, PASSWORD={password}")
        process_single_file(pdf_path, output_csv, password)
    else:
        # Process all files in the input directory
        print(f"No command-line arguments provided. Processing all PDFs in {INPUT_DIR}")
        
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        
        # Get all PDF files in the input directory
        pdf_files = glob.glob(os.path.join(INPUT_DIR, '*.pdf'))
        
        if not pdf_files:
            print(f"No PDF files found in {INPUT_DIR}")
            return
        
        print(f"Found {len(pdf_files)} PDF files to process")
        
        # Process each PDF file
        for pdf_file in pdf_files:
            process_pdf_file(pdf_file)
        
        print("\nAll files processed successfully!")

if __name__ == "__main__":
    main() 