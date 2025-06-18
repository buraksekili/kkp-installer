#!/bin/bash

source utils.sh

KEY_PATH="$HOME/.ssh/kkp-cluster"
LOCAL_FILES_DIR="$(dirname $0)/remote"
REMOTE_DIR=${REMOTE_DIR:-"/home/ubuntu"}
AWS_HOST_USERNAME=${AWS_HOST_USERNAME:-"ubuntu"}

declare -a required_secrets=(
  "K8C_PROJECT_ID"
  "K8C_CLUSTER_ID"
  "K8C_HOST"
  "K8C_AUTH"
  "KKP_VERSION"
  "KKP_HOST"
  "KKP_EMAIL"
  "AWS_IP"
)

validate_creds_file() {
  k8sCreds=${K8C_CREDS:-".k8c-creds.env"}

  log "Validating credentials in $k8sCreds file.
  You can set \$K8C_CREDS to a different file if you want to use a different file.
  For example:
    \$K8C_CREDS=./k8c-creds.env ./init.sh"

  if [ ! -f "$k8sCreds" ]; then
    error "Secrets file not found at $k8sCreds. Please copy secrets.template.env to $k8sCreds and fill in the values"
    exit 1
  fi

  source "$k8sCreds"

  missing_secrets=0
  for secret in "${required_secrets[@]}"; do
    if [ -z "${!secret}" ]; then
      error "$secret is not set in $k8sCreds"
      missing_secrets=1
    fi
  done

  if [ $missing_secrets -eq 1 ]; then
    exit 1
  fi

  log "Secrets file is valid, the script will use the credentials in '$k8sCreds' file"
}

get_kubeconfig_from_kkp() {
  local project_id="${1:-$K8C_PROJECT_ID}"
  local cluster_id="${2:-$K8C_CLUSTER_ID}"
  local kkp_host="${3:-$K8C_HOST}"
  local kkp_token="${4:-$K8C_AUTH}"
  local output_file="${5:-$LOCAL_FILES_DIR/kubeconfig-usercluster}"

  if [ -z "$project_id" ] || [ -z "$cluster_id" ] || [ -z "$kkp_host" ] || [ -z "$kkp_token" ]; then
    error "Missing required parameters for get_kubeconfig_from_kkp"
    return 1
  fi

  local output_dir=$(dirname "$output_file")
  if [ ! -d "$output_dir" ]; then
    log "Creating output directory: $output_dir"
    mkdir -p "$output_dir"
    if [ $? -ne 0 ]; then
      error "Failed to create output directory: $output_dir"
      return 1
    fi
  fi

  log "Fetching kubeconfig for cluster $cluster_id from project $project_id"

  local temp_file
  temp_file=$(mktemp)
  trap 'rm -f "$temp_file"' RETURN

  local http_status
  http_status=$(curl -s -w "%{http_code}" \
    -o "$temp_file" \
    -X GET "${kkp_host}/api/v2/projects/${project_id}/clusters/${cluster_id}/kubeconfig" \
    -H "accept: application/octet-stream" \
    -H "Authorization: Bearer $kkp_token" 2>/dev/null)

  local curl_exit_code=$?

  if [[ $curl_exit_code -ne 0 ]]; then
    error "Failed to send HTTP request to fetch kubeconfig (curl exit code: $curl_exit_code)"
    return 1
  fi

  if [[ "$http_status" -ne 200 ]]; then
    error "HTTP request failed with status code: $http_status"
    if [[ -s "$temp_file" ]]; then
      error "API response: $(cat "$temp_file")"
    fi
    return 1
  fi

  if [[ ! -s "$temp_file" ]]; then
    error "Downloaded kubeconfig file is empty"
    return 1
  fi

  if ! grep -q "apiVersion\|kind.*Config" "$temp_file" 2>/dev/null; then
    error "Downloaded file doesn't appear to be a valid kubeconfig"
    return 1
  fi

  if ! mv "$temp_file" "$output_file"; then
    error "Failed to save kubeconfig to $output_file"
    return 1
  fi

  success "Successfully downloaded kubeconfig to $output_file"
  log "Kubeconfig details:"
  log "  Project ID: $project_id"
  log "  Cluster ID: $cluster_id"
  log "  Output file: $output_file"

  return 0
}

check_ssh_connection() {
  local max_retries=10
  local retry_count=0

  while true; do
    if ssh -i "$KEY_PATH" -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$AWS_HOST" exit 2>/dev/null; then
      return 0
    else
      log "SSH connection failed, retrying in 5 seconds..."
      sleep 5
    fi

    retry_count=$((retry_count + 1))
    if [ $retry_count -ge $max_retries ]; then
      error "Failed to establish SSH connection after $max_retries retries"
      return 1
    fi
  done
}

copy_files() {
  echo "setting up preset CR"

  cp "$LOCAL_FILES_DIR/preset-tpl.yaml" "$LOCAL_FILES_DIR/preset.yaml"
  yq eval -i ".spec.aws.accessKeyID = \"$KKP_PRESET_AWS_ACCESSKEYID\"" "$LOCAL_FILES_DIR/preset.yaml"
  yq eval -i ".spec.aws.datacenter = \"$KKP_PRESET_AWS_DATACENTER\"" "$LOCAL_FILES_DIR/preset.yaml"
  yq eval -i ".spec.aws.secretAccessKey = \"$KKP_PRESET_AWS_SECRETACCESSKEY\"" "$LOCAL_FILES_DIR/preset.yaml"
  yq eval -i ".spec.aws.vpcID = \"$KKP_PRESET_AWS_VPCID\"" "$LOCAL_FILES_DIR/preset.yaml"

  cp "$LOCAL_FILES_DIR/seed-mla-tpl.values.yaml" "$LOCAL_FILES_DIR/seed-mla.values.yaml"
  yq eval -i ".prometheus.host = \"$KKP_HOST\"" "$LOCAL_FILES_DIR/seed-mla.values.yaml"
  yq eval -i ".alertmanager.host = \"$KKP_HOST\"" "$LOCAL_FILES_DIR/seed-mla.values.yaml"

  echo "Copying setup script files to EC2..."
  scp -i "$KEY_PATH" -r "$LOCAL_FILES_DIR"/* "$AWS_HOST:$REMOTE_DIR"
  if [ $? -eq 0 ]; then
    echo "Files copied successfully"
    return 0
  else
    echo "Failed to copy files"
    return 1
  fi
}

install_dependencies() {
  echo "installing KKP manifests..."
  local export_string=""

  for var in "${required_secrets[@]}"; do
    if [ -n "${!var}" ]; then
      export_string+="export $var='${!var}' && "
    fi
  done

  echo "export string: $export_string"
  exit 1
  # ssh -i "$KEY_PATH" "$AWS_HOST" "${export_string}bash -l $REMOTE_DIR/install-kkp-manifests.sh"
}

main() {
  SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-""}

  log "Starting to install KKP within KKP, on dev cluster"

  validate_creds_file

  # If SKIP_CLUSTER_CREATION is not set, create a cluster from the template
  if [ -z "$SKIP_CLUSTER_CREATION" ]; then
    log "SKIP_CLUSTER_CREATION is not set, creating a cluster from the template"
    templateId=${K8C_CLUSTER_TEMPLATEID:-""}
    if [ -z "$templateId" ]; then
      error "K8C_CLUSTER_TEMPLATEID is not set. Ensure that the K8C_CLUSTER_TEMPLATEID environment variable is set"
      exit 1
    fi

    replicas=${K8C_CLUSTER_REPLICAS:-1}
    log "Creating $replicas cluster(s) from template $templateId
    If you want to use a different number of replicas, set the K8C_CLUSTER_REPLICAS environment variable."

    if ! create_cluster_from_template "$templateId" "$K8C_PROJECT_ID" "$K8C_AUTH" "$K8C_HOST" "$replicas"; then
      error "Failed to create cluster from template"
      exit 1
    fi

    success "Cluster(s) created successfully"
    log "Sleeping for 10 seconds to let the cluster settle..."
    sleep 10

    list_recently_created_clusters "$K8C_PROJECT_ID" "$K8C_AUTH" "$K8C_HOST"

    log "Waiting for cluster nodes to be ready with external IPs..."
    wait_timeout=${WAIT_TIMEOUT_MINUTES:-15}
    if ! wait_for_nodes_external_ip "$K8C_PROJECT_ID" "$K8C_CLUSTER_ID" "$K8C_AUTH" "$K8C_HOST" "$wait_timeout"; then
      error "Timed out waiting for cluster nodes to have external IPs"
      exit 1
    fi

    success "Found node with external IP: $AWS_IP"
  fi

  AWS_HOST=${AWS_HOST:-""}

  if [ -z "$AWS_HOST" ]; then
    export AWS_HOST="${AWS_HOST_USERNAME}@${AWS_IP}"
    log "AWS_HOST environment variable is not set. Using default username $AWS_HOST_USERNAME and IP $AWS_IP
Host: $AWS_HOST"
  fi

  log "AWS_HOST is being set to $AWS_HOST, trying to establish SSH connection..."

  if ! check_ssh_connection; then
    log "Cannot establish SSH connection. Please check the following:
  1. SSH connectivity to the target host
  2. KEY_PATH variable is correctly defined in the secrets file
  3. AWS_IP variable is correctly defined in the secrets file
  4. If you need to override the hostname, set the AWS_HOST variable while running the script"

    exit 1
  fi

  success "SSH connection successful"

  echo "Fetching user cluster kubeconfig from kkp"
  if ! get_kubeconfig_from_kkp; then
    error "Failed to fetch kubeconfig from KKP"
    exit 1
  fi

  if ! copy_files; then
    echo "Error: Failed to copy files to EC2"
    exit 1
  fi

  if ! install_dependencies; then
    echo "Error: Failed to install dependencies"
    exit 1
  fi

  echo "***********************************"
  echo "EC2 setup completed successfully!"
  echo "  HOST: ${AWS_HOST}"
  echo "ssh -i \"$KEY_PATH\" -o ConnectTimeout=5 \"$AWS_HOST\""
  echo "***********************************"
}

main
