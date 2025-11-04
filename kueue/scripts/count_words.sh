#!/bin/bash

# Define the directory to scan
TRANS_DIR="/transcriptions"

# Check if the directory exists
if [ ! -d "$TRANS_DIR" ]; then
  echo "Error: Directory $TRANS_DIR does not exist."
  exit 1
fi

echo "--- All files in $TRANS_DIR ---"
# List all files and directories for visibility
ls "$TRANS_DIR"
echo "" # Add a blank line for readability

echo "--- Word Count for each file ---"
# Loop over every item in the directory
for file_path in "$TRANS_DIR"/*; do
  
  # Check if the item is a regular file
  if [ -f "$file_path" ]; then
    
    # Get the word count. Using '<' prevents the filename from being printed by wc
    word_count=$(wc -w < "$file_path")
    
    # Get just the filename from the full path
    filename=$(basename "$file_path")
    
    # Print the filename and the word count
    # 'tr -d ' ' removes any leading/trailing whitespace from the word_count
    echo "$filename: $(echo $word_count | tr -d ' ') words"
    
  fi
done

echo ""
echo "--- Script complete ---"
