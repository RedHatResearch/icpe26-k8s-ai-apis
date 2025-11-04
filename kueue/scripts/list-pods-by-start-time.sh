#!/bin/bash

# Script to list pods ordered by start time
# Usage: ./list-pods-by-start-time.sh [namespace]

# If namespace is provided as argument, use it; otherwise use current namespace
if [ -n "$1" ]; then
    NAMESPACE="$1"
else
    # Get current namespace from context
    NAMESPACE=$(oc config view --minify --output 'jsonpath={..namespace}')
    # If no namespace is set in context, default to 'default'
    if [ -z "$NAMESPACE" ]; then
        NAMESPACE="default"
    fi
fi

echo "Listing pods in namespace: $NAMESPACE"
echo "----------------------------------------"

# Get pods with their start time and sort by start time
# Output format: START_TIME | POD_NAME | STATUS
oc get pods -n "$NAMESPACE" -o json | \
jq -r '.items[] |
    "\(.status.startTime // "N/A") | \(.metadata.name) | \(.status.phase)"' | \
sort | \
awk -F' \\| ' 'BEGIN {
    printf "%-30s | %-60s | %-15s\n", "START TIME", "POD NAME", "STATUS"
    printf "%-30s-+-%-60s-+-%-15s\n", "------------------------------", "------------------------------------------------------------", "---------------"
}
{
    printf "%-30s | %-60s | %-15s\n", $1, $2, $3
}'
