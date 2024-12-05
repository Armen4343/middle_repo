#!/bin/bash

set -euo pipefail

# Validate required environment variables
required_vars=("TOKEN" "OWNER" "REPO" "EVENT_TYPE" "CURRENT_REPO")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Required environment variable $var is not set"
        exit 1
    fi
done

API_BASE_URL=${API_BASE_URL:-"https://api.github.com"}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-5}
MAX_TIME=${MAX_EXEC_TIME:-1200} 
WAIT_TIME=${SLEEP_TIME:-10}    
COLOR_OUTPUT=${COLOR_OUTPUT:-true}
PIPELINE_START_MAX_TIME=600
UUID=$(date +%s)-$RANDOM

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
    local retry_count=0
    local response
    local http_status
    local response_body

    while [ $retry_count -lt $MAX_RETRIES ]; do
        response=$(curl -X "$method" -s -w "HTTPSTATUS:%{http_code}" "${API_BASE_URL}${endpoint}" \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${TOKEN}" \
            ${data:+-d "$data"})
        
        http_status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
        response_body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')

        if [ "$http_status" -lt 400 ]; then
            echo "$response_body"
            return 0
        elif [ "$http_status" -eq 429 ]; then
            log WARN "Rate limited. Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
            retry_count=$((retry_count + 1))
        else
            local error_message
            error_message=$(echo "$response_body" | jq -r '.message' || echo "Unable to parse error message")
            log ERROR "GitHub API Error ($http_status): $error_message"
            return 1
        fi
    done

    log ERROR "Max retries reached for API call to ${endpoint}"
    return 1
}

# Trigger the repository_dispatch event
log INFO "Triggering repository dispatch event '${EVENT_TYPE}' in ${OWNER}/${REPO}..."
if ! github_api_call "POST" "/repos/${OWNER}/${REPO}/dispatches" "{\"event_type\": \"${UUID}-${EVENT_TYPE}\", \"client_payload\": {\"repository_name\": \"${CURRENT_REPO}\", \"env\": \"${EVENT_TYPE}\"}}"; then
    log ERROR "Failed to trigger repository dispatch event"
    exit 1
fi
log INFO "Repository dispatch triggered with unique ID: ${UUID}"

# Initialize variables for workflow monitoring
workflows=""
workflow=""
wfid=""
workflow_name=""
workflow_run=""
conclusion=""
status=""
jobs=""
start_time=$(date +%s)
elapsed_time=0

# Poll for the workflow run associated with the dispatch event
log INFO "Waiting for workflow with unique ID: ${UUID} to start..."
while true; do
    sleep "$WAIT_TIME"
    elapsed_time=$(( $(date +%s) - start_time ))

    if [ "$elapsed_time" -ge "$PIPELINE_START_MAX_TIME" ]; then
        log ERROR "Workflow did not start within the allotted time of $PIPELINE_START_MAX_TIME seconds."
        exit 1
    fi

    # Fetch latest workflow runs for active workflows
    if ! workflows=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs"); then
        log ERROR "Failed to fetch workflow runs"
        continue
    fi

    # Filter workflows by display_title matching the unique ID in client payload
    if ! workflow=$(echo "$workflows" | jq --arg unique_id "$UUID" '.workflow_runs[] | select(.display_title | contains($unique_id))'); then
        log ERROR "Failed to parse workflow runs"
        continue
    fi

    if [ -n "$workflow" ] && [ "$workflow" != "null" ]; then
        wfid=$(echo "$workflow" | jq -r '.id')
        workflow_name=$(echo "$workflow" | jq -r '.name')
        log INFO "Found active workflow with name: ${UUID}"
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
    if ! workflow_run=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}"); then
        log ERROR "Failed to fetch workflow run status"
        continue
    fi

    if ! conclusion=$(echo "$workflow_run" | jq -r '.conclusion'); then
        log ERROR "Failed to parse workflow conclusion"
        continue
    fi

    if ! status=$(echo "$workflow_run" | jq -r '.status'); then
        log ERROR "Failed to parse workflow status"
        continue
    fi

    if [ "$status" = "completed" ]; then
        break
    else
        log INFO "Workflow '${workflow_name}' is still running. Status: $status. Elapsed time: ${elapsed_time}s."
    fi
done

log INFO "Workflow '${workflow_name}' concluded with status: $conclusion"

# Fetch and display job details
log INFO "Fetching job details for workflow '${workflow_name}'..."
if ! jobs=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}/jobs"); then
    log ERROR "Failed to fetch job details"
    exit 1
fi

# Display job statuses
echo -e "\nJob Details:"
echo "$jobs" | jq -r '.jobs[] | "- Job: \(.name)\n  Status: \(.status)\n  Conclusion: \(.conclusion)\n  Logs: \(.html_url)\n"'

# Final status
if [ "$conclusion" = "success" ]; then
    log INFO "Workflow '${workflow_name}' completed successfully."
    exit 0
else
    log ERROR "Workflow '${workflow_name}' failed. Check the logs at: https://github.com/${OWNER}/${REPO}/actions/runs/${wfid}"
    exit 1
fi