import PyPDF2
import pandas as pd
import re
from datetime import datetime
import os
import glob
import sys

# Add parent directory to path to import config
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import (
    INPUT_DIR, OUTPUT_DIR, DEBUG_DIR, 
    TRANSACTION_PATTERN, get_transaction_type, DATE_FORMAT
)

# Global variable for password from command line
PASSWORD = None

def get_pdf_password(pdf_path):
    """Extract password from PDF filename."""
    if PASSWORD:
        return PASSWORD
        
    filename = os.path.basename(pdf_path)
    # Extract numbers before the first underscore
    password = filename.split('_')[0]
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
    
    # Create a debug directory if it doesn't exist
    os.makedirs(DEBUG_DIR, exist_ok=True)
    
    # Save the extracted text to a file for debugging
    debug_filename = os.path.basename(pdf_path).replace('.pdf', '_extracted_text.txt')
    with open(os.path.join(DEBUG_DIR, debug_filename), 'w') as f:
        f.write(text)
    
    return text

def parse_mpesa_statement(text, pdf_path):
    """Parse MPESA statement text into structured data."""
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
    
    # Save the processed text for debugging if needed
    debug_filename = os.path.basename(pdf_path).replace('.pdf', '_processed_text.txt')
    with open(os.path.join(DEBUG_DIR, debug_filename), 'w') as f:
        f.write(processed_text)
    
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
    
    # Create output directory if it doesn't exist
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    # Save to CSV with same name as PDF but with .csv extension
    base_filename = os.path.basename(pdf_path)
    output_csv = os.path.join(OUTPUT_DIR, base_filename.replace('.pdf', '.csv'))
    df.to_csv(output_csv, index=False)
    print(f"Data saved to {output_csv}")
    
    # Display DataFrame summary
    print(f"Total transactions in CSV: {len(df)}")
    print("\nFirst few transactions:")
    print(df.head())
    
    return df

def process_single_file(pdf_path, output_csv=None, password=None):
    """Process a single PDF file with optional parameters."""
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
    
    # Save to CSV
    if output_csv:
        df.to_csv(output_csv, index=False)
        print(f"Data saved to {output_csv}")
    else:
        # Use default naming with PDF filename
        base_filename = os.path.basename(pdf_path)
        default_output = os.path.join(OUTPUT_DIR, base_filename.replace('.pdf', '.csv'))
        df.to_csv(default_output, index=False)
        print(f"Data saved to {default_output}")
    
    # Display DataFrame summary
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
        
        # Ensure directories exist
        os.makedirs(OUTPUT_DIR, exist_ok=True)
        os.makedirs(DEBUG_DIR, exist_ok=True)
        
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