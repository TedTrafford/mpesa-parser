#!/bin/bash

echo "Starting MPESA PDF statement processing script"
echo "Current directory: $(pwd)"

# Get config values from Python
BASE_DIR=$(python -c "import os; print(os.path.dirname(os.path.abspath('__file__')))")
INPUT_DIR=$(python -c "from config import INPUT_DIR; print(INPUT_DIR)")
OUTPUT_DIR=$(python -c "from config import OUTPUT_DIR; print(OUTPUT_DIR)")
DEBUG_DIR=$(python -c "from config import DEBUG_DIR; print(DEBUG_DIR)")
PARSER_SCRIPT=$(python -c "from config import PARSER_SCRIPT; print(PARSER_SCRIPT)")

echo "Using paths from config:"
echo "INPUT_DIR: $INPUT_DIR"
echo "OUTPUT_DIR: $OUTPUT_DIR"
echo "DEBUG_DIR: $DEBUG_DIR"
echo "PARSER_SCRIPT: $PARSER_SCRIPT"

# Create output and debug directories if they don't exist
mkdir -p "$OUTPUT_DIR"
mkdir -p "$DEBUG_DIR"
echo "Created output directory: $OUTPUT_DIR"
echo "Created debug directory: $DEBUG_DIR"

# Check if the input directory exists and has PDF files
if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Input directory $INPUT_DIR does not exist!"
    exit 1
fi

# List PDF files
echo "Available PDF files:"
ls -la "$INPUT_DIR"/*.pdf

# Count PDF files
PDF_COUNT=$(ls -1 "$INPUT_DIR"/*.pdf 2>/dev/null | wc -l)
if [ "$PDF_COUNT" -eq 0 ]; then
    echo "No PDF files found in $INPUT_DIR"
    exit 1
fi

echo "Found $PDF_COUNT PDF files to process."
echo "==============================================="

# Process all PDF files at once using the main script
python "$PARSER_SCRIPT"

echo "==============================================="
echo "All processing complete!"
ls -la "$OUTPUT_DIR/"
