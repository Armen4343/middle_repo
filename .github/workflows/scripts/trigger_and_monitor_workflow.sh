#!/bin/bash

set -euo pipefail

# Function for logging with levels, colors, and timestamps
log() {
    local level=${1:-INFO}
    local message=$2
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    case $level in
        INFO)
            echo -e "\033[32m[$timestamp] [INFO]\033[0m $message" ;;    # Green
        WARN)
            echo -e "\033[33m[$timestamp] [WARNING]\033[0m $message" ;;  # Yellow
        ERROR)
            echo -e "\033[31m[$timestamp] [ERROR]\033[0m $message" ;;    # Red
        *)
            echo "[$timestamp] [UNKNOWN] $message" ;;
    esac
}

# Function for GitHub API calls with error handling
github_api_call() {
    local method=$1
    local endpoint=$2
    local data=${3:-}
    # local data=$3
    local response
    local http_status

    response=$(curl -X "$method" -s -w "HTTPSTATUS:%{http_code}" "https://api.github.com$endpoint" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${TOKEN}" \
        ${data:+-d "$data"})

    http_status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    response_body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')

    if [ "$http_status" -ge 400 ]; then
        local error_message
        error_message=$(echo "$response_body" | jq -r '.message')
        log ERROR "GitHub API Error ($http_status): $error_message"
        exit 1
    fi

    echo "$response_body"
}


UUID=$(date +%s)-$RANDOM

echo "UUIDDddddddDdDdfsadfgljalkngfnaksdgkfvasdfv aksdfgvadfmgmUUID"
echo $UUID
# Set max pipeline execution time (in seconds) and wait time between checks
MAX_TIME=${MAX_EXEC_TIME:-1200}
WAIT_TIME=${SLEEP_TIME:-10}

# Trigger the repository_dispatch event
log INFO "Triggering repository dispatch event '${EVENT_TYPE}' in ${OWNER}/${REPO}..."
# github_api_call "POST" "/repos/${OWNER}/${REPO}/dispatches" "{\"event_type\": \"${EVENT_TYPE}\", \"client_payload\": {\"repository_name\": \"${CURRENT_REPO}\"}}"

github_api_call "POST" "/repos/${OWNER}/${REPO}/dispatches" \
    "{\"event_type\": \"${UUID}-${EVENT_TYPE}\", \"client_payload\": {\"repository_name\": \"${CURRENT_REPO}\"}}"
log INFO "Repository dispatch triggered with unique ID: ${UUID}"
# log INFO "Workflow dispatch event triggered successfully."

# Initialize variables
workflow=""
start_time=$(date +%s)
elapsed_time=0

# Poll for the workflow run associated with the dispatch event
log INFO "Waiting for workflow with unique ID: ${UUID} to start..."
while true; do
    sleep "$WAIT_TIME"
    elapsed_time=$(( $(date +%s) - start_time ))

    if [ "$elapsed_time" -ge "$MAX_TIME" ]; then
        log ERROR "Workflow did not start within the allotted time of $MAX_TIME seconds."
        exit 1
    fi

    # Fetch latest workflow runs for active workflows
    workflows=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs?status=in_progress&per_page=10")
    echo $workflows

    # Filter workflows by display_title matching the unique ID in client payload
    workflow=$(echo "$workflows" | jq --arg unique_id "$UUID" '
        .workflow_runs[] | select(.display_title | contains($unique_id))')

    if [ -n "$workflow" ] && [ "$workflow" != "null" ]; then
        wfid=$(echo "$workflow" | jq -r '.id')
        workflow_name=$(echo "$workflow" | jq -r '.name')
        log INFO "Found active workflow with name: $workflow_name"
        break
    else
        log INFO "No active workflow with the desired unique ID found. Checking again in $WAIT_TIME seconds..."
    fi
done


log INFO "Workflow '${workflow_name}' (ID: ${wfid}) started."
log INFO "Track the progress at: https://github.com/${OWNER}/${REPO}/actions/runs/${wfid}"

# Wait for the workflow to complete
log INFO "Waiting for workflow '${workflow_name}' to complete..."
while true; do
    sleep "$WAIT_TIME"
    elapsed_time=$(( $(date +%s) - start_time ))

    if [ "$elapsed_time" -ge "$MAX_TIME" ]; then
        log ERROR "Workflow '${workflow_name}' did not complete within the allotted time of $MAX_TIME seconds."
        exit 1
    fi

    # Fetch the current status of the workflow run
    workflow_run=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}")
    conclusion=$(echo "$workflow_run" | jq -r '.conclusion')
    status=$(echo "$workflow_run" | jq -r '.status')

    if [ "$status" = "completed" ]; then
        break
    else
        log INFO "Workflow '${workflow_name}' is still running. Status: $status. Elapsed time: ${elapsed_time}s."
    fi
done

log INFO "Workflow '${workflow_name}' concluded with status: $conclusion"

# Fetch and display job details
log INFO "Fetching job details for workflow '${workflow_name}'..."
jobs=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}/jobs")

# Display job statuses
echo -e "\nJob Details:"
echo "$jobs" | jq -r '.jobs[] | "- \(.name): \(.status) (\(.conclusion)) \n  Log: \(.html_url)"'

# Final status
if [ "$conclusion" = "success" ]; then
    log INFO "Workflow '${workflow_name}' completed successfully."
    exit 0
else
    log ERROR "Workflow '${workflow_name}' failed. Check the logs at: https://github.com/${OWNER}/${REPO}/actions/runs/${wfid}"
    exit 1
fi
