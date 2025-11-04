#!/bin/bash

# Script to track Kubernetes Job lifecycle timeline with Pod correlation
# Shows creation, suspension, resumption, pod start, and completion times with ASCII timeline visualization

NAMESPACE="${1:-$(oc project -q)}"

# Temporary file to store timeline events
TIMELINE_DATA=$(mktemp)
trap "rm -f $TIMELINE_DATA" EXIT

echo "Analyzing jobs and pods in namespace: $NAMESPACE"
echo "========================================"
echo ""

# Get all jobs in the namespace
jobs=$(oc get jobs -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')

if [ -z "$jobs" ]; then
    echo "No jobs found in namespace $NAMESPACE"
    exit 0
fi

# Function to convert timestamp to epoch (handles both macOS and Linux)
timestamp_to_epoch() {
    local ts="$1"
    # Try macOS date format first, then Linux
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null || date -d "$ts" +%s 2>/dev/null
}

# Collect all timeline events
for job in $jobs; do
    # Get job creation time
    creation_time=$(oc get job "$job" -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}')

    # Get job data
    job_data=$(oc get job "$job" -n "$NAMESPACE" -o json)

    # Get job start time (when job controller starts managing it)
    job_start_time=$(echo "$job_data" | jq -r '.status.startTime // empty')

    # Check if job is/was suspended
    is_suspended=$(echo "$job_data" | jq -r '.spec.suspend // false')

    # Get suspension and resumption times from conditions
    suspend_time=""
    resume_time=""
    conditions=$(echo "$job_data" | jq -r '.status.conditions // [] | .[] | "\(.type)|\(.status)|\(.lastTransitionTime)"')
    if [ -n "$conditions" ]; then
        while IFS='|' read -r type status transition_time; do
            if [ "$type" = "Suspended" ] && [ "$status" = "True" ]; then
                suspend_time="$transition_time"
            elif [ "$type" = "Suspended" ] && [ "$status" = "False" ]; then
                resume_time="$transition_time"
            fi
        done <<< "$conditions"
    fi

    # Get pod start times for this job
    pod_start_time=""
    pods=$(oc get pods -n "$NAMESPACE" -l "job-name=$job" -o json 2>/dev/null)
    if [ -n "$pods" ]; then
        # Get the earliest pod start time
        pod_start_time=$(echo "$pods" | jq -r '.items[].status.startTime // empty' | sort | head -1)
    fi

    # Get completion time
    completion_time=$(echo "$job_data" | jq -r '.status.completionTime // empty')

    # Add CREATED event
    if [ -n "$creation_time" ]; then
        creation_epoch=$(timestamp_to_epoch "$creation_time")
        if [ -n "$creation_epoch" ]; then
            echo "$creation_epoch|CREATED|$job|$creation_time" >> "$TIMELINE_DATA"
        fi
    fi

    # Add SUSPENDED event
    if [ -n "$suspend_time" ]; then
        suspend_epoch=$(timestamp_to_epoch "$suspend_time")
        if [ -n "$suspend_epoch" ]; then
            echo "$suspend_epoch|SUSPENDED|$job|$suspend_time" >> "$TIMELINE_DATA"
        fi
    fi

    # Add RESUMED event
    if [ -n "$resume_time" ]; then
        resume_epoch=$(timestamp_to_epoch "$resume_time")
        if [ -n "$resume_epoch" ]; then
            echo "$resume_epoch|RESUMED|$job|$resume_time" >> "$TIMELINE_DATA"
        fi
    fi

    # Add POD_STARTED event (actual pod execution start)
    if [ -n "$pod_start_time" ]; then
        pod_start_epoch=$(timestamp_to_epoch "$pod_start_time")
        if [ -n "$pod_start_epoch" ]; then
            echo "$pod_start_epoch|POD_STARTED|$job|$pod_start_time" >> "$TIMELINE_DATA"
        fi
    fi

    # Add COMPLETED event
    if [ -n "$completion_time" ]; then
        completion_epoch=$(timestamp_to_epoch "$completion_time")
        if [ -n "$completion_epoch" ]; then
            echo "$completion_epoch|COMPLETED|$job|$completion_time" >> "$TIMELINE_DATA"
        fi
    fi
done

# Sort timeline by timestamp
sort -t'|' -k1 -n "$TIMELINE_DATA" -o "$TIMELINE_DATA"

# Display ASCII Timeline
echo ""
echo "ASCII TIMELINE (ordered by event time)"
echo "========================================"
echo ""

# Track active and suspended jobs (using newline-separated list for bash 3.x compatibility)
active_jobs=""
suspended_jobs=""
timeline_start=""

# Helper function to calculate duration
format_duration() {
    local duration=$1
    local dur_hours=$((duration / 3600))
    local dur_minutes=$(((duration % 3600) / 60))
    local dur_seconds=$((duration % 60))
    printf "%02d:%02d:%02d" "$dur_hours" "$dur_minutes" "$dur_seconds"
}

while IFS='|' read -r epoch event_type job_name timestamp; do
    # Set timeline start if not set
    if [ -z "$timeline_start" ]; then
        timeline_start="$epoch"
    fi

    # Calculate relative time from start
    relative_time=$((epoch - timeline_start))
    hours=$((relative_time / 3600))
    minutes=$(((relative_time % 3600) / 60))
    seconds=$((relative_time % 60))
    time_offset=$(printf "+%02d:%02d:%02d" "$hours" "$minutes" "$seconds")

    # Format timestamp for display
    display_time=$(date -j -f "%s" "$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d "@$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)

    case "$event_type" in
        CREATED)
            printf "%s [%s] ◇ CREATED  │ %s\n" "$display_time" "$time_offset" "$job_name"
            ;;

        SUSPENDED)
            # Add to suspended list
            if [ -z "$suspended_jobs" ]; then
                suspended_jobs="$job_name"
            else
                suspended_jobs="$suspended_jobs"$'\n'"$job_name"
            fi
            printf "%s [%s] ⏸ SUSPENDED│ %s\n" "$display_time" "$time_offset" "$job_name"

            # Calculate time from creation to suspension
            created_line=$(grep "|CREATED|$job_name|" "$TIMELINE_DATA")
            if [ -n "$created_line" ]; then
                created_epoch=$(echo "$created_line" | cut -d'|' -f1)
                wait_time=$((epoch - created_epoch))
                printf "                               │ Wait time: %s\n" "$(format_duration $wait_time)"
            fi
            ;;

        RESUMED)
            # Remove from suspended list
            suspended_jobs=$(echo "$suspended_jobs" | grep -v "^${job_name}$" || true)
            printf "%s [%s] ▶ RESUMED  │ %s\n" "$display_time" "$time_offset" "$job_name"

            # Calculate suspension duration
            suspended_line=$(grep "|SUSPENDED|$job_name|" "$TIMELINE_DATA")
            if [ -n "$suspended_line" ]; then
                suspended_epoch=$(echo "$suspended_line" | cut -d'|' -f1)
                suspended_duration=$((epoch - suspended_epoch))
                printf "                               │ Suspended for: %s\n" "$(format_duration $suspended_duration)"
            fi
            ;;

        POD_STARTED)
            # Add to active list
            if [ -z "$active_jobs" ]; then
                active_jobs="$job_name"
            else
                active_jobs="$active_jobs"$'\n'"$job_name"
            fi
            printf "%s [%s] ▶ POD START│ %s\n" "$display_time" "$time_offset" "$job_name"

            # Calculate queue/pending time (creation to pod start or resume to pod start)
            resumed_line=$(grep "|RESUMED|$job_name|" "$TIMELINE_DATA")
            created_line=$(grep "|CREATED|$job_name|" "$TIMELINE_DATA")

            if [ -n "$resumed_line" ]; then
                # If job was resumed, show time from resume to pod start
                resumed_epoch=$(echo "$resumed_line" | cut -d'|' -f1)
                queue_time=$((epoch - resumed_epoch))
                printf "                               │ Queue time (from resume): %s\n" "$(format_duration $queue_time)"
            elif [ -n "$created_line" ]; then
                # Show time from creation to pod start
                created_epoch=$(echo "$created_line" | cut -d'|' -f1)
                queue_time=$((epoch - created_epoch))
                printf "                               │ Queue time (from creation): %s\n" "$(format_duration $queue_time)"
            fi

            # Show currently active jobs
            active_count=$(echo "$active_jobs" | grep -c '^' 2>/dev/null || echo 0)
            if [ "$active_count" -gt 0 ]; then
                printf "                               │ Active: %d pod(s) running\n" "$active_count"
            fi
            ;;

        COMPLETED)
            # Remove job from active list
            active_jobs=$(echo "$active_jobs" | grep -v "^${job_name}$" || true)
            printf "%s [%s] ■ COMPLETED│ %s\n" "$display_time" "$time_offset" "$job_name"

            # Calculate execution time (pod start to completion)
            pod_start_line=$(grep "|POD_STARTED|$job_name|" "$TIMELINE_DATA")
            if [ -n "$pod_start_line" ]; then
                pod_start_epoch=$(echo "$pod_start_line" | cut -d'|' -f1)
                exec_duration=$((epoch - pod_start_epoch))
                printf "                               │ Execution time: %s\n" "$(format_duration $exec_duration)"
            fi

            # Calculate total job time (creation to completion)
            created_line=$(grep "|CREATED|$job_name|" "$TIMELINE_DATA")
            if [ -n "$created_line" ]; then
                created_epoch=$(echo "$created_line" | cut -d'|' -f1)
                total_duration=$((epoch - created_epoch))
                printf "                               │ Total time: %s\n" "$(format_duration $total_duration)"
            fi

            # Show currently active jobs
            if [ -n "$active_jobs" ]; then
                active_count=$(echo "$active_jobs" | grep -c '^' 2>/dev/null || echo 0)
                if [ "$active_count" -gt 0 ]; then
                    printf "                               │ Active: %d pod(s) running\n" "$active_count"
                fi
            fi
            ;;
    esac
    echo "                               │"
done < "$TIMELINE_DATA"

echo "========================================"

# Summary statistics
total_jobs=$(echo "$jobs" | wc -w | tr -d '[:space:]')
total_jobs=${total_jobs:-0}
completed_jobs=$(grep -c "|COMPLETED|" "$TIMELINE_DATA" 2>/dev/null || echo 0)
completed_jobs=${completed_jobs:-0}
running_jobs=0
pending_jobs=0
suspended_jobs_count=0

# Calculate job states more accurately
for job in $jobs; do
    has_completed=$(grep "|COMPLETED|$job|" "$TIMELINE_DATA" 2>/dev/null | wc -l | tr -d '[:space:]')
    has_pod_started=$(grep "|POD_STARTED|$job|" "$TIMELINE_DATA" 2>/dev/null | wc -l | tr -d '[:space:]')
    has_suspended=$(grep "|SUSPENDED|$job|" "$TIMELINE_DATA" 2>/dev/null | wc -l | tr -d '[:space:]')
    has_resumed=$(grep "|RESUMED|$job|" "$TIMELINE_DATA" 2>/dev/null | wc -l | tr -d '[:space:]')

    # Default to 0 if empty
    has_completed=${has_completed:-0}
    has_pod_started=${has_pod_started:-0}
    has_suspended=${has_suspended:-0}
    has_resumed=${has_resumed:-0}

    if [ "$has_completed" -eq 0 ]; then
        if [ "$has_pod_started" -gt 0 ]; then
            running_jobs=$((running_jobs + 1))
        elif [ "$has_suspended" -gt 0 ] && [ "$has_resumed" -eq 0 ]; then
            suspended_jobs_count=$((suspended_jobs_count + 1))
        else
            pending_jobs=$((pending_jobs + 1))
        fi
    fi
done

echo ""
echo "SUMMARY"
echo "========================================"
echo "Total Jobs:      $total_jobs"
echo "Completed Jobs:  $completed_jobs"
echo "Running Jobs:    $running_jobs (pod executing)"
echo "Pending Jobs:    $pending_jobs (pod not started)"
echo "Suspended Jobs:  $suspended_jobs_count"

# Calculate average queue times
total_queue_time=0
queue_time_count=0
while IFS='|' read -r epoch event_type job_name timestamp; do
    if [ "$event_type" = "POD_STARTED" ]; then
        resumed_line=$(grep "|RESUMED|$job_name|" "$TIMELINE_DATA")
        created_line=$(grep "|CREATED|$job_name|" "$TIMELINE_DATA")

        if [ -n "$resumed_line" ]; then
            resumed_epoch=$(echo "$resumed_line" | cut -d'|' -f1)
            queue_time=$((epoch - resumed_epoch))
        elif [ -n "$created_line" ]; then
            created_epoch=$(echo "$created_line" | cut -d'|' -f1)
            queue_time=$((epoch - created_epoch))
        else
            continue
        fi

        total_queue_time=$((total_queue_time + queue_time))
        queue_time_count=$((queue_time_count + 1))
    fi
done < "$TIMELINE_DATA"

if [ "$queue_time_count" -gt 0 ]; then
    avg_queue_time=$((total_queue_time / queue_time_count))
    echo "Avg Queue Time:  $(format_duration $avg_queue_time)"
fi

# Calculate total timeline duration
if [ -s "$TIMELINE_DATA" ]; then
    first_epoch=$(head -1 "$TIMELINE_DATA" | cut -d'|' -f1)
    last_epoch=$(tail -1 "$TIMELINE_DATA" | cut -d'|' -f1)
    total_duration=$((last_epoch - first_epoch))
    total_hours=$((total_duration / 3600))
    total_minutes=$(((total_duration % 3600) / 60))
    total_seconds=$((total_duration % 60))
    echo "Timeline Span:   ${total_hours}h ${total_minutes}m ${total_seconds}s"
fi

echo "========================================"

# Add detailed pod listing section
echo ""
echo "POD DETAILS (ordered by pod start time)"
echo "========================================"
echo ""

# Get all pods in the namespace and their details
pod_data=$(mktemp)
job_creation_data=$(mktemp)
trap "rm -f $TIMELINE_DATA $pod_data $job_creation_data" EXIT

# First, get job creation times and store them in a file (for Bash 3.x compatibility)
for job in $jobs; do
    creation_time=$(oc get job "$job" -n "$NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
    echo "$job|$creation_time" >> "$job_creation_data"
done

oc get pods -n "$NAMESPACE" -o json | \
jq -r '.items[] |
    "\(.status.startTime // "N/A")|\(.metadata.name)|\(.status.phase)|\(.metadata.labels["job-name"] // "N/A")"' | \
sort > "$pod_data"

# Display pod table with job creation time column
printf "%-30s | %-30s | %-60s | %-15s | %-40s\n" "POD START TIME" "JOB CREATION TIME" "POD NAME" "STATUS" "JOB NAME"
printf "%-30s-+-%-30s-+-%-60s-+-%-15s-+-%-40s\n" "------------------------------" "------------------------------" "------------------------------------------------------------" "---------------" "----------------------------------------"

while IFS='|' read -r start_time pod_name status job_name; do
    # Get job creation time for this pod's job (Bash 3.x compatible)
    job_creation=$(grep "^${job_name}|" "$job_creation_data" 2>/dev/null | cut -d'|' -f2)
    job_creation="${job_creation:-N/A}"
    printf "%-30s | %-30s | %-60s | %-15s | %-40s\n" "$start_time" "$job_creation" "$pod_name" "$status" "$job_name"
done < "$pod_data"

echo ""
echo "========================================"
echo "Timeline Analysis Complete"
