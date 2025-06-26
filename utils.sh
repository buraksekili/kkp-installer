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
        error "Failed to fetch cluster templates from API, $response"
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

    if ! response=$(api_request "GET" "/api/v2/projects/$project_id/clusters" "" "$kkp_token"); then
        error "Failed to list clusters via API"
        return 1
    fi

    if ! echo "$response" | jq . >/dev/null 2>&1; then
        error "API returned invalid JSON response: $response"
        return 1
    fi

    log "Recently created clusters:"
    echo "$response" | jq -r '.clusters | sort_by(.creationTimestamp) | reverse | .[] | "\(.id) - \(.name) - Created: \(.creationTimestamp)"' | head -n 10 | while read -r line; do
        log "  $line"
    done

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

    local start_time=$(date +%s)
    local timeout_seconds=$((timeout_minutes * 60))
    local end_time=$((start_time + timeout_seconds))
    local retry_interval=30

    while true; do
        current_time=$(date +%s)

        if [ $current_time -gt $end_time ]; then
            error "Timeout reached while waiting for nodes to have external IPs"
            return 1
        fi

        local elapsed_seconds=$((current_time - start_time))
        local elapsed_minutes=$((elapsed_seconds / 60))
        local elapsed_seconds_remainder=$((elapsed_seconds % 60))
        local remaining_seconds=$((end_time - current_time))
        local remaining_minutes=$((remaining_seconds / 60))

        log "Checking nodes status (elapsed: ${elapsed_minutes}m ${elapsed_seconds_remainder}s, remaining: ${remaining_minutes}m)..."

        local response
        if ! response=$(api_request "GET" "/api/v2/projects/${project_id}/clusters/${cluster_id}/nodes" "" "$kkp_token"); then
            log "Failed to get nodes, retrying in ${retry_interval}s..."
            log "Response: $response"
            sleep $retry_interval
            continue
        fi

        if ! echo "$response" | jq . >/dev/null 2>&1; then
            log "Invalid JSON response, retrying in ${retry_interval}s..."
            sleep $retry_interval
            continue
        fi

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

remove_yaml_scheduling_config() {
    local target_file="$1"

    if [ -z "$target_file" ]; then
        error "remove_yaml_scheduling_config: target file parameter is required"
        return 1
    fi

    if [ ! -f "$target_file" ]; then
        error "remove_yaml_scheduling_config: file '$target_file' does not exist"
        return 1
    fi

    log "Removing YAML scheduling configurations from $target_file"

    # Remove YAML anchor and node scheduling configurations
    sed -i '' '/^scheduleOnStableNodes:/d' "$target_file"
    sed -i '' '/^  tolerations:/d' "$target_file"
    sed -i '' '/^    - operator:/d' "$target_file"
    sed -i '' '/^      key:/d' "$target_file"
    sed -i '' '/^  nodeSelector:/d' "$target_file"
    sed -i '' '/^    kubermatic.io\/stable:/d' "$target_file"
    sed -i '' '/<<: \*scheduleOnStableNodes/d' "$target_file"

    return 0
}

update_helm_master_file() {
    local source_file="$KKP_FILES_DIR/helm-master.yaml"
    log "updating helm master file located at $source_file"

    local admin_password="${ADMIN_PASSWORD:-}"
    if [ -z "$admin_password" ]; then
        error "Admin password is not set"
        return 1
    fi

    if [ ! -f "$source_file" ]; then
        error "Source file '$source_file' does not exist"
        return 1
    fi

    local secret_key_file="${KKP_FILES_DIR}/random-secret-key"
    local dex_client_secret=""
    if [ -f "$secret_key_file" ]; then
        dex_client_secret=$(cat "$secret_key_file")
        log "Read dex client secret from $secret_key_file"
    else
        error "Secret key file '$secret_key_file' not found"
        return 1
    fi

    local password_hash
    if command -v htpasswd >/dev/null 2>&1; then
        password_hash=$(htpasswd -bnBC 10 "" "$admin_password" | tr -d ':\n' | sed 's/$2y/$2a/')
    else
        error "htpasswd is not available for password hashing"
        return 1
    fi

    log "Generated bcrypt hash for admin password"

    local temp_file
    temp_file=$(mktemp /tmp/helm-master-update.XXXXXX)
    trap "rm -f \"$temp_file\" \"$temp_file.new\"" EXIT

    cp "$source_file" "$temp_file"

    if ! remove_yaml_scheduling_config "$temp_file"; then
        error "Failed to remove YAML scheduling configurations"
        return 1
    fi

    # Change dex replica count from 2 to 1
    sed -i '' 's/replicaCount: 2/replicaCount: 1/g' "$temp_file"

    # Replace specific hostnames with placeholders
    sed -i '' 's/"dev\.kubermatic\.io"/'"$KKP_HOST"'/g' "$temp_file"
    sed -i '' 's/https:\/\/dev\.kubermatic\.io/https:\/\/'"$KKP_HOST"'/g' "$temp_file"

    # Update user accounts
    awk -v password_hash="$password_hash" -v email="$KKP_EMAIL" '
    BEGIN { in_passwords = 0; printed = 0; }
    /^    staticPasswords:/ { 
        print "    staticPasswords:";
        print "      - email: " email;
        print "        hash: \"" password_hash "\"";
        print "        username: admin";
        print "        userID: 08a8684b-db88-4b73-90a9-3cd1661f5466";
        in_passwords = 1;
        printed = 1;
        next;
    }
    /^    staticClients:/ { in_passwords = 0; print; next; }
    in_passwords { next; } # Skip all lines in the passwords section
    { print; } # Print all other lines
    ' "$temp_file" >"$temp_file.new" && mv "$temp_file.new" "$temp_file"

    # awk -v dex_secret="$dex_client_secret" '
    # BEGIN { in_clients = 0; client_count = 0; skip_current_client = 0; }
    # /^    staticClients:/ { in_clients = 1; print; next; }
    # /^    [a-zA-Z]/ { in_clients = 0; skip_current_client = 0; print; next; } # Any other section starts

    # in_clients && /^      - id:/ {
    #     client_count++;
    #     skip_current_client = (client_count > 2);
    #     if (!skip_current_client) {
    #         print;
    #     }
    #     next;
    # }

    # in_clients && skip_current_client { next; } # Skip all lines for clients that should be skipped

    # in_clients && /^        secret:/ {
    #     print "        secret: " dex_secret;
    #     next;
    # }

    # { print; } # Print all other lines
    # ' "$temp_file" >"$temp_file.new" && mv "$temp_file.new" "$temp_file"

    sed -i '' '/^cert-manager:/,/^$/d' "$temp_file"
    sed -i '' '/^nginx:/,/^$/d' "$temp_file"

    # set `useNewDexChart: true`
    yq eval '.useNewDexChart = true' -i "$temp_file"

    # Update all domains to KKP_HOST (good for MLA deployments)
    sed -i '' 's/dev.kubermatic.io/'"$KKP_HOST"'/g' "$temp_file"

    mv "$temp_file" "$source_file"

    success "Updated $source_file"

    return 0
}
