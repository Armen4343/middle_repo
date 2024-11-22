#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Function for logging with timestamps
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function for GitHub API calls
github_api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
    curl -X "$method" -s "https://api.github.com$endpoint" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${TOKEN}" \
        ${data:+-d "$data"}
}

# Set variables
MAX_TIME=${MAX_EXEC_TIME:-1200}
WAIT_TIME=${SLEEP_TIME:-10}
echo "${EVENT_TYPE}"
echo "eveeeeeeeeeeeeeeeeeeent type"
# Trigger the repository_dispatch event
log "Triggering repository dispatch event in ${OWNER}/${REPO}..."
resp=$(github_api_call "POST" "/repos/${OWNER}/${REPO}/dispatches" "{\"event_type\": \"${EVENT_TYPE}\"}")

# Check the trigger for errors
if echo "$resp" | grep -q "message"; then
    log "Error: ${resp}"
    exit 1
else
    log "Workflow triggered successfully"
fi

# Find the triggered workflow run
log "Waiting for workflow to start..."
counter=0
while true; do
    counter=$((counter + 1))
    workflow=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs?event=repository_dispatch" | jq '.workflow_runs[0]')
    
    if [ -z "$workflow" ] || [ "$workflow" = "null" ]; then
        log "No workflow runs found. Retrying..."
        sleep 4
        # continue
    fi

    wtime=$(echo "$workflow" | jq -r '.created_at')
    atime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    tdif=$(( $(date -d "$atime" +"%s") - $(date -d "$wtime" +"%s") ))

    if [ "$tdif" -gt 10 ]; then
        if [ "$counter" -gt 3 ]; then
            log "Workflow not found after multiple attempts"
            exit 1
        else
            log "Waiting for workflow to start..."
            sleep 3
        fi
    else
        break
    fi
done

wfid=$(echo "$workflow" | jq -r '.id')
conclusion=$(echo "$workflow" | jq -r '.conclusion')

log "Workflow ID: ${wfid}"


# Wait for the workflow to complete
counter=0
while [ "$conclusion" = "null" ]; do
    if [ "$counter" -ge "$MAX_TIME" ]; then
        log "Time limit exceeded"
        exit 1
    fi
    
    log "Check run on https://github.com/${OWNER}/${REPO}/actions/runs/${wfid}"
    sleep "$WAIT_TIME"
    
    conclusion=$(github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}" | jq -r '.conclusion')
    counter=$((counter + WAIT_TIME))
done

log "Workflow concluded with status: $conclusion"

# Display all jobs with it's status and link
github_api_call "GET" "/repos/${OWNER}/${REPO}/actions/runs/${wfid}/jobs" | jq -r '.jobs[] | "\(.name) - \(.status) - \(.conclusion) - \(.html_url)"'
echo "workflow_conclusion=success" >> $GITHUB_ENV

if [ "$conclusion" = "success" ]; then
    log "Workflow run successful"
else
    log "Workflow run failed"
    exit 1
fi

