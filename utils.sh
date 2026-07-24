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

# ---- Config loading ----

CONFIG_YAML=""

load_config() {
  local config_file="${CONFIG_FILE:-config.yaml}"

  if [ ! -f "$config_file" ]; then
    error "Config file not found: $config_file"
    exit 1
  fi

  CONFIG_YAML="$config_file"

  # minimal validation: check critical fields
  local missing=0
  for field in '.kubermatic.version' '.kubermatic.domain' '.infrastructure.clusterName'; do
    local val
    val=$(yq eval "$field" "$CONFIG_YAML")
    if [ "$val" = "null" ] || [ -z "$val" ]; then
      error "Required config field $field is missing or empty"
      missing=1
    fi
  done

  if [ $missing -eq 1 ]; then
    exit 1
  fi

  log "Loaded config from $config_file"
}

config_get() {
  local path="$1"
  local default="${2:-}"
  local value
  value=$(yq eval "${path} // \"${default}\"" "$CONFIG_YAML")
  echo "$value"
}

config_enabled() {
  local path="$1"
  local value
  value=$(yq eval "${path} // false" "$CONFIG_YAML")
  [[ "$value" == "true" ]]
}

# config_has returns success when a config path exists and is non-null.
# use it instead of `[ -n "$v" ] && [ "$v" != "null" ]` at read sites.
config_has() {
  local path="$1"
  local value
  value=$(yq eval "${path} // null" "$CONFIG_YAML")
  [ "$value" != "null" ]
}

extract_helm_overlay() {
  local section="$1"
  local output="$2"

  local values
  values=$(yq eval ".${section}.values" "$CONFIG_YAML")

  if [ "$values" = "null" ] || [ -z "$values" ]; then
    log "No overlay values for $section"
    return 0
  fi

  echo "$values" > "$output"
  log "Generated Helm overlay for $section at $output"
}

export CONFIG_YAML
export -f load_config
export -f config_get
export -f config_enabled
export -f config_has
export -f extract_helm_overlay

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
  http_status=$(curl "${args[@]}" "${kkp_host}${endpoint}" 2> /dev/null)
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
  if ! echo "$response" | jq . > /dev/null 2>&1; then
    error "API returned invalid JSON response: $response"
    return 1
  fi

  if echo "$response" | jq -e ".[] | select(.id == \"$template_id\")" > /dev/null; then
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
  if ! echo "$response" | jq . > /dev/null 2>&1; then
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

  if ! echo "$response" | jq . > /dev/null 2>&1; then
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

    if ! echo "$response" | jq . > /dev/null 2>&1; then
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
      local external_ip=$(echo "$response" | jq -r ".[$i].status.addresses[] | select(.type == \"ExternalIP\") | .address" 2> /dev/null)

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
  if command -v htpasswd > /dev/null 2>&1; then
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
    ' "$temp_file" > "$temp_file.new" && mv "$temp_file.new" "$temp_file"

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

# fetch_aws_credentials_from_vault - Gets AWS resource credentials from Vault
# Requires VAULT_AWS_PATH environment variable
# Outputs:
#   Sets AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION environment variables
fetch_aws_credentials_from_vault() {
  if [ -z "$VAULT_AWS_PATH" ]; then
    error "VAULT_AWS_PATH environment variable is required"
    return 1
  fi

  log "Fetching AWS resource credentials from Vault"

  export AWS_ACCESS_KEY_ID=$(vault kv get -field=accessKeyID "$VAULT_AWS_PATH")
  export AWS_SECRET_ACCESS_KEY=$(vault kv get -field=secretAccessKey "$VAULT_AWS_PATH")
  export AWS_REGION=$(vault kv get -field=region "$VAULT_AWS_PATH")

  if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    error "Failed to fetch AWS credentials from Vault"
    return 1
  fi

  success "AWS resource credentials fetched successfully"
}

# fetch_route53_credentials_from_vault - Gets Route53 DNS credentials from Vault
# Requires VAULT_ROUTE53_PATH environment variable
# Outputs:
#   Sets ROUTE53_ACCESS_KEY_ID and ROUTE53_SECRET_ACCESS_KEY environment variables
fetch_route53_credentials_from_vault() {
  if [ -z "$VAULT_ROUTE53_PATH" ]; then
    error "VAULT_ROUTE53_PATH environment variable is required"
    return 1
  fi

  log "Fetching Route53 credentials from Vault"

  export ROUTE53_ACCESS_KEY_ID=$(vault kv get -field=route53AccessKeyID "$VAULT_ROUTE53_PATH")
  export ROUTE53_SECRET_ACCESS_KEY=$(vault kv get -field=route53SecretAccessKey "$VAULT_ROUTE53_PATH")

  if [ -z "$ROUTE53_ACCESS_KEY_ID" ] || [ -z "$ROUTE53_SECRET_ACCESS_KEY" ]; then
    error "Failed to fetch Route53 credentials from Vault"
    return 1
  fi

  success "Route53 credentials fetched successfully"
}

# generate_kubeone_tfvars - Generates terraform.tfvars from environment
# Arguments:
#   None (reads from environment variables)
# Outputs:
#   Creates kubeone-aws/terraform.tfvars
generate_kubeone_tfvars() {
  local tfvars_file="$KKP_FILES_DIR/../kubeone-aws/terraform.tfvars"

  log "Generating terraform.tfvars..."

  cat > "$tfvars_file" << EOF
cluster_name = "$(config_get '.infrastructure.clusterName' 'kkp-test')"
aws_region = "$(config_get '.infrastructure.region' 'eu-central-1')"
vpc_id = "$(config_get '.infrastructure.vpcId' 'default')"
control_plane_type = "$(config_get '.infrastructure.controlPlane.instanceType' 't3.medium')"
control_plane_volume_size = $(config_get '.infrastructure.controlPlane.volumeSize' '50')
control_plane_vm_count = 1
worker_type = "$(config_get '.infrastructure.workers.instanceType' 't3.medium')"
worker_volume_size = $(config_get '.infrastructure.workers.volumeSize' '200')
static_workers_count = $(config_get '.infrastructure.workers.count' '3')
initial_machinedeployment_replicas = 0
os = "ubuntu"
ssh_public_key_file = "$(config_get '.infrastructure.sshPublicKeyFile' '~/.ssh/k8c_bs.pub')"
EOF

  success "Generated terraform.tfvars at $tfvars_file"
}

# render_kubeone_config - Renders kubeone.yaml from template
# Arguments:
#   None
# Outputs:
#   Creates kubeone-aws/kubeone.yaml
render_kubeone_config() {
  local template="$KKP_FILES_DIR/../kubeone-aws/kubeone.yaml.tpl"
  local output="$KKP_FILES_DIR/../kubeone-aws/kubeone.yaml"

  log "Rendering KubeOne configuration..."

  sed -e "s/__CLUSTER_NAME__/$(config_get '.infrastructure.clusterName' 'kkp-test')/g" \
    -e "s/__KUBERNETES_VERSION__/$(config_get '.infrastructure.kubernetesVersion' '1.28.0')/g" \
    "$template" > "$output"

  success "Rendered kubeone.yaml at $output"
}

# provision_kubeone_cluster - Provisions cluster using Terraform + KubeOne
# Arguments:
#   None
# Outputs:
#   Provisions AWS infrastructure and Kubernetes cluster
provision_kubeone_cluster() {
  local kubeone_dir="$KKP_FILES_DIR/../kubeone-aws"

  log "Provisioning KubeOne cluster..."

  pushd "$kubeone_dir" || {
    error "Failed to change to KubeOne directory"
    return 1
  }

  # Initialize Terraform
  log "Initializing Terraform..."
  terraform init || {
    error "Terraform init failed"
    popd
    return 1
  }

  # Apply Terraform
  log "Applying Terraform configuration..."
  terraform apply -auto-approve || {
    error "Terraform apply failed"
    popd
    return 1
  }

  # Generate Terraform output for KubeOne
  log "Generating Terraform output..."
  terraform output -json > tf.json || {
    error "Terraform output failed"
    popd
    return 1
  }

  # Run KubeOne apply
  log "Running KubeOne apply..."
  kubeone apply -y --create-machine-deployments=false -m kubeone.yaml -t tf.json --verbose || {
    error "KubeOne apply failed"
    popd
    return 1
  }

  popd || return 1
  success "KubeOne cluster provisioned successfully"
}

# get_kubeconfig_from_kubeone - Fetches kubeconfig from KubeOne cluster
# Arguments:
#   None
# Outputs:
#   Saves kubeconfig to $KKP_FILES_DIR/kubeconfig-kubeone
get_kubeconfig_from_kubeone() {
  local kubeone_dir="$KKP_FILES_DIR/../kubeone-aws"
  local output="$(cd "$KKP_FILES_DIR" && pwd)/kubeconfig-kubeone"

  mkdir -p "$(dirname "$output")"

  log "Fetching kubeconfig from KubeOne cluster..."

  pushd "$kubeone_dir" || return 1

  kubeone kubeconfig -m kubeone.yaml -t tf.json > "$output" || {
    error "Failed to fetch kubeconfig from KubeOne"
    popd
    return 1
  }

  popd || return 1

  export KUBECONFIG="$output"
  success "Kubeconfig saved to $output"
}

# check_tls_backup - Checks if TLS backup exists and is valid
# Arguments:
#   $1 - backup file path
# Returns:
#   0 if valid backup exists, 1 otherwise
check_tls_backup() {
  local backup_file="$1"

  if [ ! -f "$backup_file" ]; then
    log "No TLS backup found at $backup_file"
    return 1
  fi

  # Check if backup contains valid cert data
  if ! kubectl apply --dry-run=client -f "$backup_file" 2> /dev/null; then
    log "TLS backup exists but may be invalid"
    return 1
  fi

  log "Valid TLS backup found at $backup_file"
  return 0
}

# restore_tls_from_backup - Restores TLS secret from backup
# Arguments:
#   $1 - backup file path
# Outputs:
#   Applies TLS secret to cluster
restore_tls_from_backup() {
  local backup_file="$1"

  log "Restoring TLS certificate from backup..."

  kubectl apply -f "$backup_file" || {
    error "Failed to restore TLS from backup"
    return 1
  }

  success "TLS certificate restored from backup"
}

# get_tls_secret_name_from_certificate - Finds the TLS secret name from Certificate resource
# Arguments:
#   $1 - certificate name (default: kubermatic-tls)
#   $2 - namespace (default: kubermatic)
# Outputs:
#   Prints the secret name to backup (either nextPrivateKeySecretName or spec.secretName)
get_tls_secret_name_from_certificate() {
  local cert_name="${1:-kubermatic-tls}"
  local namespace="${2:-kubermatic}"

  log "Finding TLS secret from Certificate $cert_name in namespace $namespace" >&2

  local cert_yaml
  cert_yaml=$(kubectl get certificate "$cert_name" -n "$namespace" -o yaml 2> /dev/null) || {
    error "Failed to get Certificate $cert_name" >&2
    return 1
  }

  # check for nextPrivateKeySecretName in status
  local next_secret
  next_secret=$(echo "$cert_yaml" | yq eval '.status.nextPrivateKeySecretName // ""' -)

  if [ -n "$next_secret" ]; then
    log "Found nextPrivateKeySecretName: $next_secret" >&2
    echo "$next_secret"
    return 0
  fi

  # fallback to spec.secretName if nextPrivateKeySecretName is not set
  local spec_secret
  spec_secret=$(echo "$cert_yaml" | yq eval '.spec.secretName // ""' -)

  if [ -n "$spec_secret" ]; then
    log "Using spec.secretName: $spec_secret" >&2
    echo "$spec_secret"
    return 0
  fi

  error "Could not find secret name in Certificate $cert_name" >&2
  return 1
}

# backup_tls_secret - Backs up TLS secret to local file
# Arguments:
#   $1 - certificate name (default: kubermatic-tls) - used to find the secret
#   $2 - namespace (default: kubermatic)
#   $3 - backup file path
# Outputs:
#   Saves TLS secret YAML to backup file
backup_tls_secret() {
  local cert_name="${1:-kubermatic-tls}"
  local namespace="${2:-kubermatic}"
  local backup_file="${3:-$KKP_FILES_DIR/tls-backup.yaml}"

  log "Backing up TLS certificate..."

  local secret_name
  secret_name=$(get_tls_secret_name_from_certificate "$cert_name" "$namespace") || {
    error "Failed to determine TLS secret name from Certificate"
    return 1
  }

  kubectl get secret "$secret_name" -n "$namespace" -o yaml > "$backup_file" || {
    error "Failed to backup TLS secret $secret_name"
    return 1
  }

  success "TLS certificate $secret_name backed up to $backup_file"
}

# wait_for_lb_hostname - Polls a kubectl resource until the given jsonpath
# resolves to a non-empty value (the LoadBalancer hostname a CNAME points at).
# Cloud LoadBalancers are provisioned asynchronously, so the address is not
# present the instant the resource is created.
# Arguments:
#   $1 - human-readable description used in log/error messages
#   $2 - jsonpath expression to extract (without the surrounding braces)
#   $3 - timeout in minutes (optional, defaults to 5)
#   $@ - remaining args: kubectl get selectors (e.g. gateway -n kubermatic kubermatic)
# Outputs:
#   Prints the resolved hostname on stdout; all logs go to stderr so the caller
#   can capture stdout with a command substitution.
wait_for_lb_hostname() {
  local description="$1"
  local jsonpath="$2"
  local timeout_minutes="$3"
  shift 3
  local kubectl_selector=("$@")

  local start_time=$(date +%s)
  local end_time=$((start_time + timeout_minutes * 60))
  local retry_interval=15

  while true; do
    local hostname
    hostname=$(kubectl get "${kubectl_selector[@]}" -o jsonpath="{$jsonpath}" 2> /dev/null)

    if [ -n "$hostname" ]; then
      echo "$hostname"
      return 0
    fi

    if [ "$(date +%s)" -ge "$end_time" ]; then
      error "Timeout waiting for ${description} hostname" >&2
      return 1
    fi

    log "Waiting for ${description} hostname, retrying in ${retry_interval}s..." >&2
    sleep $retry_interval
  done
}

# update_route53_dns_records - Creates/updates Route53 DNS records for KKP services
# Arguments:
#   $1 - base domain (e.g., burak.lab.kubermatic.io)
#   $2 - seed name (optional, defaults to "kubermatic")
#   $3 - hosted zone id (optional, defaults to "Z08267412VFVFOL4NEM4P")
#   $4 - gateway API enabled (optional, "true" to read the master LB from the
#        Gateway instead of the nginx-ingress-controller service)
# Requires:
#   ROUTE53_ACCESS_KEY_ID and ROUTE53_SECRET_ACCESS_KEY environment variables
#   kubectl configured with correct kubeconfig
# Outputs:
#   Creates/updates CNAME records in Route53
update_route53_dns_records() {
  local base_domain="$1"
  local seed_name="${2:-kubermatic}"
  local hosted_zone_id="${3:-Z08267412VFVFOL4NEM4P}"
  local gateway_api_enabled="${4:-false}"

  if [ -z "$base_domain" ]; then
    error "update_route53_dns_records: base_domain is required"
    return 1
  fi

  if [ -z "$ROUTE53_ACCESS_KEY_ID" ] || [ -z "$ROUTE53_SECRET_ACCESS_KEY" ]; then
    error "ROUTE53_ACCESS_KEY_ID and ROUTE53_SECRET_ACCESS_KEY must be set"
    return 1
  fi

  log "Updating Route53 DNS records for $base_domain..."

  # the master domain LB comes from the Gateway when Gateway API is on, and from
  # the nginx-ingress-controller service otherwise (nginx is not deployed with
  # Gateway API enabled).
  local master_lb
  if [ "$gateway_api_enabled" = "true" ]; then
    log "Gateway API enabled, reading master LoadBalancer from Gateway kubermatic/kubermatic..."
    master_lb=$(wait_for_lb_hostname "Gateway kubermatic/kubermatic" ".status.addresses[0].value" 5 \
      gateway -n kubermatic kubermatic) || return 1
  else
    master_lb=$(wait_for_lb_hostname "nginx-ingress-controller LoadBalancer" ".status.loadBalancer.ingress[0].hostname" 5 \
      svc -n nginx-ingress-controller nginx-ingress-controller) || return 1
  fi
  log "Found master LoadBalancer: $master_lb"

  local nodeport_lb
  nodeport_lb=$(wait_for_lb_hostname "nodeport-proxy LoadBalancer" ".status.loadBalancer.ingress[0].hostname" 5 \
    svc -n kubermatic nodeport-proxy) || return 1
  log "Found nodeport-proxy LoadBalancer: $nodeport_lb"

  # Create/Update DNS records
  log "Creating/updating Route53 records..."

  local change_batch
  change_batch=$(
    cat << EOF
{
  "Comment": "KKP installer - update DNS records for $base_domain",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$base_domain.",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [{"Value": "$master_lb"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.$base_domain.",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [{"Value": "$master_lb"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.$seed_name.$base_domain.",
        "Type": "CNAME",
        "TTL": 60,
        "ResourceRecords": [{"Value": "$nodeport_lb"}]
      }
    }
  ]
}
EOF
  )

  AWS_ACCESS_KEY_ID="$ROUTE53_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$ROUTE53_SECRET_ACCESS_KEY" \
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$hosted_zone_id" \
    --change-batch "$change_batch" || {
    error "Failed to update Route53 records"
    return 1
  }

  success "Route53 DNS records updated successfully"
  log "  - $base_domain -> $master_lb"
  log "  - *.$base_domain -> $master_lb"
  log "  - *.$seed_name.$base_domain -> $nodeport_lb"
}

# parse_kubermatic_version - Extracts version number from kubermatic-installer --version output
# Arguments:
#   $1 - output from "kubermatic-installer --version" command
# Outputs:
#   Prints version string without 'v' prefix (e.g., "2.29.4") or "unknown" on failure
parse_kubermatic_version() {
  local version_output="$1"

  if [ -z "$version_output" ]; then
    echo "unknown"
    return 1
  fi

  # Output format: "kubermatic-installer version v2.29.4"
  # Extract the last field and strip the 'v' prefix
  local version
  version=$(echo "$version_output" | awk '{print $NF}' | sed 's/^v//')

  if [ -z "$version" ]; then
    echo "unknown"
    return 1
  fi

  echo "$version"
}

# get_kubermatic_installer_version - Gets version from kubermatic-installer binary
# Arguments:
#   $1 - path to kubermatic-installer binary
# Outputs:
#   Prints version string (e.g., "2.29.4") or "unknown" on failure
get_kubermatic_installer_version() {
  local binary_path="$1"

  if [ ! -f "$binary_path" ]; then
    echo "unknown"
    return 1
  fi

  local version_output
  version_output=$("$binary_path" --version 2> /dev/null || echo "unknown")

  parse_kubermatic_version "$version_output"
}

export -f fetch_aws_credentials_from_vault
export -f fetch_route53_credentials_from_vault
export -f generate_kubeone_tfvars
export -f render_kubeone_config
export -f provision_kubeone_cluster
export -f get_kubeconfig_from_kubeone
export -f check_tls_backup
export -f restore_tls_from_backup
export -f get_tls_secret_name_from_certificate
export -f backup_tls_secret
export -f wait_for_lb_hostname
export -f update_route53_dns_records
export -f parse_kubermatic_version
export -f get_kubermatic_installer_version
