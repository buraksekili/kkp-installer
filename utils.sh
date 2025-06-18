#!/usr/bin/env bash

set -euo pipefail

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_RESET='\033[0m'

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local message="$1"
    echo "[$(get_timestamp)] [INFO] ${message}"
}

success() {
    local message="$1"
    echo -e "${COLOR_GREEN}[$(get_timestamp)] [SUCCESS]${COLOR_RESET} ${message}"
}

error() {
    local message="$1"
    echo -e "${COLOR_RED}[$(get_timestamp)] [ERROR]${COLOR_RESET} ${message}"
}

export -f get_timestamp
export -f log
export -f success
export -f error

api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local kkp_token="$4"

    if [ -z "$method" ] || [ -z "$endpoint" ] || [ -z "$kkp_token" ]; then
        error "Missing required parameters: either method, endpoint, or kkp_token is not set"
        return 1
    fi

    local args=(-s -X "$method" -H "Authorization: Bearer $kkp_token" -H "Content-Type: application/json")

    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi

    local response_file
    response_file=$(mktemp)

    # Ensure cleanup on function exit
    trap 'rm -f "$response_file"' RETURN

    args+=(-w "%{http_code}" -o "$response_file")

    local http_status
    http_status=$(curl "${args[@]}" "${kkp_host}${endpoint}" 2>/dev/null)
    local curl_exit_code=$?

    # Check curl exit code first
    if [[ $curl_exit_code -ne 0 ]]; then
        return 1
    fi

    # Check HTTP status code (200-299 are considered successful)
    if [[ "$http_status" -lt 200 || "$http_status" -ge 300 ]]; then
        cat "$response_file" >&2
        return 1
    fi

    cat "$response_file"
    return 0
}

check_template_exists() {
    local response

    log "Checking if template $template_id exists in project $project_id"

    if ! response=$(api_request "GET" "/api/v2/projects/$project_id/clustertemplates" "" "$kkp_token"); then
        error "Failed to fetch cluster templates from API"
        return 1
    fi

    # Validate that the response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        error "API returned invalid JSON response: $response"
        return 1
    fi

    if echo "$response" | jq -e ".[] | select(.id == \"$template_id\")" >/dev/null; then
        log "Template $template_id found in project $project_id"
        return 0
    else
        return 1
    fi
}

create_cluster_from_template() {
    export template_id="$1"
    export project_id="$2"
    export kkp_token="$3"
    export kkp_host="$4"
    export replicas="${5:-1}" # Default to 1 replica if not specified

    if [ -z "$template_id" ] || [ -z "$project_id" ] || [ -z "$kkp_token" ] || [ -z "$kkp_host" ]; then
        error "Missing required parameters: either template_id, project_id, kkp_token, or kkp_host is not set"
        return 1
    fi

    if ! check_template_exists; then
        error "Template $template_id not found in project $project_id"
        return 1
    fi

    local response

    log "Creating $replicas cluster(s) from template
  Project ID: $project_id
  Template ID: $template_id
  Replicas: $replicas"

    # Create the request payload with the number of replicas
    local payload=$(jq -n \
        --arg replicas "$replicas" \
        '{
      "replicas": ($replicas | tonumber)
    }')

    # Make the API call to create the cluster(s) from template
    if ! response=$(api_request "POST" "/api/v2/projects/$project_id/clustertemplates/$template_id/instances" "$payload" "$kkp_token"); then
        error "Failed to create cluster(s) from template via API"
        return 1
    fi

    # Validate that the response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        error "API returned invalid JSON response: $response"
        return 1
    fi

    if [[ $(echo "$response" | jq -r '.error') != "null" && $(echo "$response" | jq -r '.error') != "" ]]; then
        error "API returned an error: $(echo "$response" | jq -r '.error')"
        return 1
    fi

    success "Cluster creation initiated successfully!"
    log "Created $replicas cluster(s) from template $template_id in project $project_id"
}

list_recently_created_clusters() {
    export project_id="$1"
    export kkp_token="$2"
    export kkp_host="$3"

    if [ -z "$project_id" ] || [ -z "$kkp_token" ] || [ -z "$kkp_host" ]; then
        error "Missing required parameters: either project_id, kkp_token, or kkp_host is not set"
        return 1
    fi

    log "Retrieving recently created clusters..."

    local response

    # Make API call to list clusters in the project
    if ! response=$(api_request "GET" "/api/v2/projects/$project_id/clusters" "" "$kkp_token"); then
        error "Failed to list clusters via API"
        return 1
    fi

    # Validate that the response is valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        error "API returned invalid JSON response: $response"
        return 1
    fi

    # Sort clusters by creation timestamp (newest first)
    log "Recently created clusters:"
    echo "$response" | jq -r '.clusters | sort_by(.creationTimestamp) | reverse | .[] | "\(.id) - \(.name) - Created: \(.creationTimestamp)"' | head -n 10 | while read -r line; do
        log "  $line"
    done

    # Store the most recently created cluster ID in the environment variable
    export K8C_CLUSTER_ID=$(echo "$response" | jq -r '.clusters | sort_by(.creationTimestamp) | reverse | .[0].id')
    log "Set K8C_CLUSTER_ID=$K8C_CLUSTER_ID for subsequent operations"
}

wait_for_nodes_external_ip() {
    local project_id="$1"
    local cluster_id="$2"
    local kkp_token="$3"
    local kkp_host="$4"
    local timeout_minutes="${5:-15}"

    if [ -z "$project_id" ] || [ -z "$cluster_id" ] || [ -z "$kkp_token" ] || [ -z "$kkp_host" ]; then
        error "Missing required parameters for wait_for_nodes_external_ip"
        return 1
    fi

    log "Waiting for cluster nodes to have external IP addresses (timeout: ${timeout_minutes} minutes)..."

    local start_time=$(date +%s)
    local timeout_seconds=$((timeout_minutes * 60))
    local end_time=$((start_time + timeout_seconds))
    local retry_interval=30

    while true; do
        current_time=$(date +%s)

        # Check timeout
        if [ $current_time -gt $end_time ]; then
            error "Timeout reached while waiting for nodes to have external IPs"
            return 1
        fi

        # Calculate elapsed and remaining time
        local elapsed_seconds=$((current_time - start_time))
        local elapsed_minutes=$((elapsed_seconds / 60))
        local elapsed_seconds_remainder=$((elapsed_seconds % 60))
        local remaining_seconds=$((end_time - current_time))
        local remaining_minutes=$((remaining_seconds / 60))

        log "Checking nodes status (elapsed: ${elapsed_minutes}m ${elapsed_seconds_remainder}s, remaining: ${remaining_minutes}m)..."

        # Get nodes
        local response
        if ! response=$(api_request "GET" "/api/v2/projects/${project_id}/clusters/${cluster_id}/nodes" "" "$kkp_token"); then
            log "Failed to get nodes, retrying in ${retry_interval}s..."
            sleep $retry_interval
            continue
        fi

        # Validate JSON
        if ! echo "$response" | jq . >/dev/null 2>&1; then
            log "Invalid JSON response, retrying in ${retry_interval}s..."
            sleep $retry_interval
            continue
        fi

        # Check for nodes
        local node_count=$(echo "$response" | jq '. | length')
        if [ "$node_count" -eq 0 ]; then
            log "No nodes found yet, retrying in ${retry_interval}s..."
            sleep $retry_interval
            continue
        fi

        log "Found ${node_count} node(s), checking for external IPs..."

        local found_external_ip=false

        for i in $(seq 0 $((node_count - 1))); do
            local node_name=$(echo "$response" | jq -r ".[$i].metadata.name")
            local external_ip=$(echo "$response" | jq -r ".[$i].status.addresses[] | select(.type == \"ExternalIP\") | .address" 2>/dev/null)

            if [ -n "$external_ip" ]; then
                # Set the global AWS_IP variable to the first external IP found
                export AWS_IP="$external_ip"
                log "Found external IP: $node_name ($external_ip)"
                echo "Set AWS_IP=$AWS_IP"
                found_external_ip=true
                break
            fi
        done

        if [ "$found_external_ip" = true ]; then
            return 0
        else
            log "No nodes have external IPs yet, retrying in ${retry_interval}s..."
        fi

        sleep $retry_interval
    done
}
