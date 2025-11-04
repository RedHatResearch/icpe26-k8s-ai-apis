#!/bin/bash

# --- Configuration ---

# REQUIRED: Specify a string to find in your pod names.
# This will match any pod that contains this text.
# EXAMPLE:
# POD_NAME_STRING="whisper-transcription"
POD_NAME_STRING="whisper-transcription"

# Optional: Specify the namespace. If empty, it uses your current active namespace.
NAMESPACE=""

# ---------------------

# Check if the string is set
if [ -z "$POD_NAME_STRING" ]; then
  echo "Error: POD_NAME_STRING variable is empty. Please set it in the script."
  exit 1
fi

# Build the oc get pods command arguments
oc_pod_args="get pods -o custom-columns=:metadata.name --no-headers"
if [ -n "$NAMESPACE" ]; then
  oc_pod_args="-n $NAMESPACE $oc_pod_args"
fi

echo "Getting pods with names containing: '$POD_NAME_STRING'..."

# Get all pod names from the namespace, then grep for the string.
# We pipe to 'grep' to filter the list.
pod_list=$(oc $oc_pod_args | grep "$POD_NAME_STRING")

if [ -z "$pod_list" ]; then
  echo "No pods found with names containing '$POD_NAME_STRING'."
  if [ -n "$NAMESPACE" ]; then
    echo "Searched in namespace: '$NAMESPACE'."
  else
    echo "Searched in current namespace. (Use 'oc project' to check/change)."
  fi
  exit 1
fi

echo "" # Newline for readability

# Loop through each pod name found
for pod in $pod_list; do
  echo "--- Processing Pod: $pod ---"
  
  # Build the oc logs command arguments
  oc_log_args="logs $pod"
  if [ -n "$NAMESPACE" ]; then
    oc_log_args="-n $NAMESPACE $oc_log_args"
  fi

  # Get the *entire* log output once and store it in a variable
  echo "Fetching logs..."
  pod_logs=$(oc $oc_log_args)

  # --- 1. Find the filename ---
  # Filter for the "selected file:" line, get the first one just in case
  filename_line=$(echo "$pod_logs" | grep "selected file:" | head -n 1)
  
  if [ -n "$filename_line" ]; then
    # Use awk to split the line by ": " and print the second part
    filename=$(echo "$filename_line" | awk -F': ' '{print $2}')
    echo "File Transcribed: $filename"
  else
    echo "File Transcribed: Not found in log."
  fi

  # --- 2. Find the last timestamp ---
  # Filter for lines that look like timestamps
  # Get only the *last* line of that list
  last_timestamp_line=$(echo "$pod_logs" | grep '^\[.* --> .*\]' | tail -n 1)
  
  if [ -n "$last_timestamp_line" ]; then
    # Use 'sed' to extract only the end time.
    # It finds ' --> ', captures everything (.*) until the ']',
    # and replaces the whole line with just the captured part.
    end_time=$(echo "$last_timestamp_line" | sed 's/.* --> \(.*\)\].*/\1/')
    
    echo "Last audio timestamp: $end_time"
  else
    echo "Last audio timestamp: Not found in log."
  fi
  echo "" # Newline for readability
done

echo "--- Script complete ---"
