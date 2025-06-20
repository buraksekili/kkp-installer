#!/bin/bash

source utils.sh

KEY_PATH="$HOME/.ssh/kkp-cluster"
KKP_FILES_DIR="$(dirname $0)/kkp-files"
REMOTE_DIR=${REMOTE_DIR:-"/home/ubuntu"}

declare -a required_secrets=(
  "K8C_PROJECT_ID"
  "K8C_CLUSTER_ID"
  "K8C_HOST"
  "K8C_AUTH"
  "KKP_VERSION"
  "KKP_HOST"
  "KKP_EMAIL"
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

check_cluster_match() {
  if kubectl config get-clusters --no-headers 2>/dev/null | grep -q "^${K8C_CLUSTER_ID}$"; then
    log "✅ K8C_CLUSTER_ID matches kubectl config"
    return 0
  else
    error "❌ K8C_CLUSTER_ID ($K8C_CLUSTER_ID) not found in kubectl config, ensure that correct kubeconfig is being used"
    return 1
  fi
}

get_kubeconfig_from_kkp() {
  local project_id="$K8C_PROJECT_ID"
  local cluster_id="$K8C_CLUSTER_ID"
  local kkp_host="$K8C_HOST"
  local kkp_token="$K8C_AUTH"
  local output_file="$KKP_FILES_DIR/kubeconfig-usercluster"

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

generate_random_secret_key() {
  local secret_key_file="$1"
  if [ -z "$secret_key_file" ]; then
    error "secret_key_file is not set"
    return 1
  fi

  if [ -f "$secret_key_file" ] && [ -s "$secret_key_file" ]; then
    log "Using existing random secret key from $secret_key_file"
  else
    log "Generating new random secret key..."

    if command -v openssl >/dev/null 2>&1; then
      openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c32 >"$secret_key_file"
    else
      head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32 >"$secret_key_file"
    fi

    if [ $? -eq 0 ] && [ -s "$secret_key_file" ]; then
      log "Random secret key generated and saved to $secret_key_file"
    else
      error "Failed to generate random secret key"
      return 1
    fi
  fi
}

prepare_kkp_configs() {
  local remote_files_dir="remote-files"
  log "Preparing KKP configs in $remote_files_dir, creating directory if it doesn't exist..."
  mkdir -p "$remote_files_dir"

  log "Generating random secret key for dex client secret..."
  if ! generate_random_secret_key "$remote_files_dir/random-secret-key"; then
    error "Failed to generate random secret key"
    exit 1
  fi

  log "Fetching files from vault. If you are not logged in to vault, please do so via 'vault login'"

  vault kv get -field=presets.yaml "$VAULT_SECRET" >"$remote_files_dir/presets.yaml"
  vault kv get -field=kubermatic.yaml "$VAULT_SECRET" >"$remote_files_dir/kubermatic.yaml"
  vault kv get -field=helm-master.yaml "$VAULT_SECRET" >"$remote_files_dir/helm-master.yaml"
  vault kv get -field=helm-seed-shared.yaml "$VAULT_SECRET" >"$remote_files_dir/helm-seed-shared.yaml"

  # update KubermaticConfiguration
  yq eval '.spec.featureGates.UserClusterMLA = false' -i "$remote_files_dir/kubermatic.yaml"
  yq eval '.spec.featureGates.VerticalPodAutoscaler = false' -i "$remote_files_dir/kubermatic.yaml"
  yq eval '.spec.ingress.domain = "'$KKP_HOST'"' -i "$remote_files_dir/kubermatic.yaml"

  if ! update_helm_master_file "$remote_files_dir/helm-master.yaml"; then
    error "Failed to update helm-master file"
    exit 1
  fi

  if ! remove_yaml_scheduling_config "$remote_files_dir/helm-seed-shared.yaml"; then
    error "Failed to remove YAML scheduling configurations"
    exit 1
  fi

  yq eval '.minio.storeSize = "25Gi"' -i "$remote_files_dir/helm-seed-shared.yaml"

  cp remote/cluster-issuer.yaml "$remote_files_dir"
  yq eval '.spec.acme.email = "'$KKP_EMAIL'"' -i "$remote_files_dir/cluster-issuer.yaml"

  success "Files prepared successfully"
}

install_kubermatic_installer() {
  log "Checking for kubermatic-installer availability..."

  if [[ -f "$KKP_FILES_DIR/kubermatic-installer" && -d "$KKP_FILES_DIR/charts" ]]; then
    log "Found kubermatic-installer in remote-files directory"
    chmod +x "$KKP_FILES_DIR/kubermatic-installer"
    success "Using kubermatic-installer from remote-files directory"
    export KUBERMATIC_BINARY="$KKP_FILES_DIR/kubermatic-installer"
    return 0
  fi

  local os=$(go env GOOS)
  local arch=$(go env GOARCH)

  log "kubermatic-installer not found locally. Downloading KKP $KKP_VERSION ($KKP_EDITION edition) for $os/$arch..."

  local kkp_edition_str="kubermatic-$KKP_EDITION"
  local download_url="https://github.com/kubermatic/kubermatic/releases/download/v${KKP_VERSION}/${kkp_edition_str}-v${KKP_VERSION}-${os}-${arch}.tar.gz"
  local archive_path="$KKP_FILES_DIR/kkp-manifests/${kkp_edition_str}-${KKP_VERSION}.tar.gz"

  mkdir -p "$KKP_FILES_DIR/kkp-manifests"

  log "Downloading from: $download_url"
  if ! curl -L "$download_url" --output "$archive_path"; then
    error "Failed to download kubermatic-installer"
    return 1
  fi

  log "Extracting archive to kkp-manifests directory..."
  if ! tar -xzf "$archive_path" -C "$KKP_FILES_DIR/kkp-manifests"; then
    error "Failed to extract kubermatic-installer archive"
    return 1
  fi

  chmod +x "$KKP_FILES_DIR/kkp-manifests/kubermatic-installer"
  cp "$KKP_FILES_DIR/kkp-manifests/kubermatic-installer" "$KKP_FILES_DIR/kubermatic-installer"
  cp -r "$KKP_FILES_DIR/kkp-manifests/charts" "$KKP_FILES_DIR/charts"
  rm "$archive_path"
  rm -rf "$KKP_FILES_DIR/kkp-manifests"

  export KUBERMATIC_BINARY="$KKP_FILES_DIR/kubermatic-installer"
  success "Successfully installed kubermatic-installer to $KUBERMATIC_BINARY"

  local version=$("$KUBERMATIC_BINARY" version -s 2>/dev/null || echo "unknown")
  log "Installed version: $version"
}

install_kubermatic() {
  install_kubermatic_installer

  log "===> Installing KKP Master Cluster"

  "$KUBERMATIC_BINARY" deploy \
    --config "$KKP_FILES_DIR/kubermatic.yaml" \
    --helm-values "$KKP_FILES_DIR/helm-master.yaml" \
    --kubeconfig "$KKP_FILES_DIR/kubeconfig-usercluster" \
    --deploy-default-app-catalog \
    --storageclass aws \
    --charts-directory "$KKP_FILES_DIR/charts"
}

main() {
  SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-""}

  log "Starting to install KKP within KKP, on dev cluster"

  validate_creds_file

  # Check if K8C_CLUSTER_ID matches kubectl config
  if ! check_cluster_match; then
    error "Cluster ID validation failed. Please ensure K8C_CLUSTER_ID matches a cluster in your kubectl config"
    exit 1
  fi

  prepare_kkp_configs

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

    success "Found node with external IP"
  fi

  echo "Fetching user cluster kubeconfig from kkp"
  if ! get_kubeconfig_from_kkp; then
    error "Failed to fetch kubeconfig from KKP"
    exit 1
  fi

  if ! install_kubermatic; then
    error "Failed to install Kubermatic"
    exit 1
  fi

  success "KKP Master Cluster installed successfully"
}

main
