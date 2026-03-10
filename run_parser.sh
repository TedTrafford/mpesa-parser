#!/bin/bash

# Activate conda environment and run the parser
eval "$(conda shell.bash hook)"
conda activate mpesa_parser
python process_all_pdfs.py
 