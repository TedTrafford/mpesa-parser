#!/usr/bin/env python3

import os
import sys
import glob
import subprocess
import time
import shutil
import re
from config import INPUT_DIR, OUTPUT_DIR, FAILED_DIR, PARSER_SCRIPT

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
    
    # Run the parser script
    try:
        start_time = time.time()
        print(f"Running parser with: {pdf_file}, {output_csv}, password: {password}")
        
        # Run the command
        result = subprocess.run([
            sys.executable,
            PARSER_SCRIPT,
            pdf_file,
            output_csv,
            password
        ], check=True, capture_output=True, text=True)
        
        end_time = time.time()
        print(f"Processing completed in {end_time - start_time:.2f} seconds")
        
        # Verify output file was created
        if os.path.exists(output_csv):
            print(f"✓ Successfully created CSV file: {output_csv}")
            successful_files.append(base_filename)
            # Move successfully processed PDF to parsed directory
            parsed_pdf_path = os.path.join(OUTPUT_DIR, base_filename)
            shutil.move(pdf_file, parsed_pdf_path)
            print(f"  Moved PDF to: {parsed_pdf_path}")
        else:
            print(f"✗ ERROR: Failed to create CSV file for {pdf_file}")
            # Move failed file to failed directory
            failed_path = os.path.join(FAILED_DIR, base_filename)
            shutil.move(pdf_file, failed_path)
            print(f"  Moved failed PDF to: {failed_path}")
            failed_files.append(base_filename)
    
    except subprocess.CalledProcessError as e:
        print(f"✗ Error processing {pdf_file}: {str(e)}")
        if e.stderr:
            print(f"  Error details: {e.stderr}")
        # Move failed file to failed directory
        failed_path = os.path.join(FAILED_DIR, base_filename)
        shutil.move(pdf_file, failed_path)
        print(f"  Moved failed PDF to: {failed_path}")
        failed_files.append(base_filename)
        
    except Exception as e:
        print(f"✗ Unexpected error processing {pdf_file}: {str(e)}")
        # Move failed file to failed directory
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