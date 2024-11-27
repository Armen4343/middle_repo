#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

log() {
    local level=$1
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

# Function for GitHub API calls
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

# Set variables
MAX_TIME=${MAX_EXEC_TIME:-1200}
WAIT_TIME=${SLEEP_TIME:-10}

# Trigger the repository_dispatch event
log INFO "Triggering repository dispatch event in ${OWNER}/${REPO}..."
resp=$(github_api_call "POST" "/repos/${OWNER}/${REPO}/dispatches" \
  "{\"event_type\": \"${EVENT_TYPE}\", \"client_payload\": {\"repository_name\": \"${CURRENT_REPO}\"}}")
log INFO "Workflow dispatch event triggered successfully."

# Check the trigger for errors
if echo "$resp" | grep -q "message"; then
    log ERROR "Error: ${resp}"
    exit 1
else
    log INFO "Workflow triggered successfully"
fi

# Find the triggered workflow run
log INFO "Waiting for workflow to start..."
counter=0
while true; do
    counter=$((counter + 1))
    workflow=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs?event=repository_dispatch" | jq '.workflow_runs[0]')
    
    if [ -z "$workflow" ] || [ "$workflow" = "null" ]; then
        log ERROR "Workflow did not start within the allotted time of $MAX_TIME seconds."
        sleep 4
        # continue
    fi

    wtime=$(echo "$workflow" | jq -r '.created_at')
    atime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    tdif=$(( $(date -d "$atime" +"%s") - $(date -d "$wtime" +"%s") ))
    if [ "$tdif" -gt 10 ]; then
        if [ "$counter" -gt 3 ]; then
            log INFO "Workflow not found after multiple attempts"
            exit 1
        else
            log INFO "Waiting for workflow to start..."
            sleep 3
        fi
    else
        break
    fi
done

wfid=$(echo "$workflow" | jq -r '.id')
conclusion=$(echo "$workflow" | jq -r '.conclusion')
log INFO "Workflow ID: ${wfid}"

# Wait for the workflow to complete
counter=0
while [ "$conclusion" = "null" ]; do
    if [ "$counter" -ge "$MAX_TIME" ]; then
        log ERROR "Time limit exceeded"
        exit 1
    fi
    
    log INFO "Check run on https://github.com/${OWNER}/${REPO}/actions/runs/${wfid}"
    sleep "$WAIT_TIME"
    
    conclusion=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}" | jq -r '.conclusion')
    counter=$((counter + WAIT_TIME))
done

log INFO "Workflow concluded with status: $conclusion"

# Display all jobs with it's status and link
github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}/jobs" | jq -r '.jobs[] | "\(.name) - \(.status) - \(.conclusion) - \(.html_url)"'
echo "workflow_conclusion=success" >> $GITHUB_ENV

if [ "$conclusion" = "success" ]; then
    log INFO "Workflow run successful"
else
    log ERROR "Workflow run failed"
    exit 1
fi
