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
  local k8cProjectId=$K8C_PROJECT_ID
  local k8cClusterId=$K8C_CLUSTER_ID
  local k8cHost=$K8C_HOST
  local k8cAuthKey=$K8C_AUTH
  local output_file="$LOCAL_FILES_DIR/kubeconfig-usercluster"

  kubectl --kubeconfig /Users/buraksekili/Downloads/qa.txt get secrets -n cluster-${k8cClusterId} admin-kubeconfig -o jsonpath={.data.kubeconfig} | base64 -d >$output_file
  return 0

  response=$(curl -s -w "%{http_code}" \
    -o "$output_file" \
    -X GET "$k8cHost"/api/v2/projects/"$k8cProjectId"/clusters/"$k8cClusterId"/kubeconfig \
    -H "accept: application/octet-stream" \
    -H "Authorization: Bearer $k8cAuthKey")

  if [ $? -ne 0 ]; then
    echo "Error: Failed to send HTTP request to fetch kubeconfig from kkp"
    rm "$output_file"
    exit 1
  fi

  if [ "$response" -ne 200 ]; then
    echo "Error: HTTP request failed with status code: $response"
    cat "$output_file"
    rm "$output_file"
    exit 1
  fi

  echo "Successfully saved user cluster's kubeconfig response to $output_file"
  return 0
}

check_ssh_connection() {
  if ssh -i "$KEY_PATH" -o ConnectTimeout=5 "$AWS_HOST" exit 2>/dev/null; then
    return 0
  else
    return 1
  fi
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
  ssh -i "$KEY_PATH" "$AWS_HOST" "${export_string}bash -l $REMOTE_DIR/install-kkp-manifests.sh"
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

    # Get the number of replicas from environment variable or default to 1
    replicas=${K8C_CLUSTER_REPLICAS:-1}
    log "Creating $replicas cluster(s) from template $templateId
    If you want to use a different number of replicas, set the K8C_CLUSTER_REPLICAS environment variable."

    # if ! create_cluster_from_template "$templateId" "$K8C_PROJECT_ID" "$K8C_AUTH" "$K8C_HOST" "$replicas"; then
    #   error "Failed to create cluster from template"
    #   exit 1
    # fi

    list_recently_created_clusters "$K8C_PROJECT_ID" "$K8C_AUTH" "$K8C_HOST"

    success "Cluster(s) created successfully"

    # Wait for nodes to have external IPs
    log "Waiting for cluster nodes to be ready with external IPs..."
    wait_timeout=${WAIT_TIMEOUT_MINUTES:-15}
    if ! wait_for_nodes_external_ip "$K8C_PROJECT_ID" "$K8C_CLUSTER_ID" "$K8C_AUTH" "$K8C_HOST" "$wait_timeout"; then
      error "Timed out waiting for cluster nodes to have external IPs"
      exit 1
    fi

    success "Found node with external IP: $AWS_IP"
  fi

  exit 1

  if [ -z "$AWS_HOST" ]; then
    log "AWS_HOST environment variable is not set. Using default username $AWS_HOST_USERNAME and IP $AWS_IP"
    export AWS_HOST="${AWS_HOST_USERNAME}@${AWS_IP}"
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
  get_kubeconfig_from_kkp

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
