#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Function for logging with levels, colors, and timestamps
log() {
    # Default log level
    local level=${1:-INFO}
    local message=${2:-"No message provided"}

    # Generate timestamp
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Determine color and prefix based on level
    local color
    local prefix

    case $level in
        INFO)
            color="\033[32m"
            prefix="INFO" ;;
        WARN)
            color="\033[33m"
            prefix="WARNING" ;;
        ERROR)
            color="\033[31m"
            prefix="ERROR" ;;
    esac

    # Single echo command
    echo -e "${color}[$timestamp] $prefix $message"
}

# Function for GitHub API calls with error handling
github_api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
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

# Set max pipeline execution time (in seconds) and wait time between checks
MAX_TIME=${MAX_EXEC_TIME:-1200}
WAIT_TIME=${SLEEP_TIME:-10}

# Trigger the repository_dispatch event
log "Triggering repository dispatch event '${EVENT_TYPE}' in ${OWNER}/${REPO}..."
github_api_call "POST" "/repos/${OWNER}/${REPO}/dispatches" "{\"event_type\": \"${EVENT_TYPE}\", \"client_payload\": {\"repository_name\": \"${CURRENT_REPO}\"}}"
log "Workflow dispatch event triggered successfully."

# Initialize variables
workflow=""
start_time=$(date +%s)
elapsed_time=0

# Poll for the workflow run associated with the dispatch event
log "Waiting for workflow to start..."
while true; do
    sleep "$WAIT_TIME"
    elapsed_time=$(( $(date +%s) - start_time ))

    if [ "$elapsed_time" -ge "$MAX_TIME" ]; then
        log ERROR "Workflow did not start within the allotted time of $MAX_TIME seconds."
        exit 1
    fi

    # Fetch the latest workflow runs triggered by 'repository_dispatch' event
    workflows=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs?event=repository_dispatch&per_page=5")
    workflow=$(echo "$workflows" | jq '.workflow_runs[0]')

    if [ -n "$workflow" ] && [ "$workflow" != "null" ]; then
        wfid=$(echo "$workflow" | jq -r '.id')
        workflow_name=$(echo "$workflow" | jq -r '.name')
        break
    else
        log "Workflow not started yet. Checking again in $WAIT_TIME seconds..."
    fi
done

log "Workflow '${workflow_name}' (ID: ${wfid}) started."
log "Track the progress at: https://github.com/${OWNER}/${REPO}/actions/runs/${wfid}"

# Wait for the workflow to complete
log "Waiting for workflow '${workflow_name}' to complete..."
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
        log "Workflow '${workflow_name}' is still running. Status: $status. Elapsed time: ${elapsed_time}s."
    fi
done

log "Workflow '${workflow_name}' concluded with status: $conclusion"

# Fetch and display job details
log "Fetching job details for workflow '${workflow_name}'..."
jobs=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}/jobs")

# Display job statuses
echo -e "\nJob Details:"
echo "$jobs" | jq -r '.jobs[] | "- \(.name): \(.status) (\(.conclusion)) \n  Log: \(.html_url)"'

# Final status
if [ "$conclusion" = "success" ]; then
    log "Workflow '${workflow_name}' completed successfully."
    exit 0
else
    log ERROR "Workflow '${workflow_name}' failed. Check the logs at: https://github.com/${OWNER}/${REPO}/actions/runs/${wfid}"
    exit 1
fi
