#!/usr/bin/env python3

import os
import sys
import glob
import subprocess
import time
from config import INPUT_DIR, OUTPUT_DIR, PARSER_SCRIPT

print("MPESA PDF Statement Batch Processor")
print("----------------------------------")

print(f"Input directory: {INPUT_DIR}")
print(f"Output directory: {OUTPUT_DIR}")
print(f"Parser script: {PARSER_SCRIPT}")

# Create output directory if it doesn't exist
os.makedirs(OUTPUT_DIR, exist_ok=True)

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

# Process each PDF file separately (allows for better error handling)
for i, pdf_file in enumerate(pdf_files, 1):
    print(f"\nProcessing file {i} of {len(pdf_files)}: {os.path.basename(pdf_file)}")
    
    # Get the output CSV path
    base_filename = os.path.basename(pdf_file)
    output_csv = os.path.join(OUTPUT_DIR, base_filename.replace('.pdf', '.csv'))
    
    # Get password from filename
    password = base_filename.split('_')[0]
    
    # Run the parser script
    try:
        start_time = time.time()
        print(f"Running parser with: {pdf_file}, {output_csv}, {password}")
        
        # Run the command
        subprocess.run([
            sys.executable,
            PARSER_SCRIPT,
            pdf_file,
            output_csv,
            password
        ], check=True)
        
        end_time = time.time()
        print(f"Processing completed in {end_time - start_time:.2f} seconds")
        
        # Verify output file was created
        if os.path.exists(output_csv):
            print(f"Successfully created CSV file: {output_csv}")
        else:
            print(f"ERROR: Failed to create CSV file for {pdf_file}")
    
    except subprocess.CalledProcessError as e:
        print(f"Error processing {pdf_file}: {str(e)}")
    except Exception as e:
        print(f"Unexpected error processing {pdf_file}: {str(e)}")

print("\nAll processing complete!")

# List all CSV files created
csv_files = glob.glob(os.path.join(OUTPUT_DIR, "*.csv"))
print(f"Created {len(csv_files)} CSV files:")
for csv_file in csv_files:
    print(f"  - {os.path.basename(csv_file)}") 