#!/bin/bash

KEY_PATH="$HOME/.ssh/kkp-cluster"
LOCAL_FILES_DIR="$(dirname $0)/remote"
REMOTE_DIR="/home/ubuntu"

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
  echo "will use credentials in '$k8sCreds'"
  if [ ! -f "$k8sCreds" ]; then
    echo "Error: Secrets file not found at $k8sCreds"
    echo "Please copy secrets.template.env to $k8sCreds and fill in the values"
    exit 1
  fi

  source "$k8sCreds"

  missing_secrets=0
  for secret in "${required_secrets[@]}"; do
    if [ -z "${!secret}" ]; then
      echo "Error: $secret is not set in $k8sCreds"
      missing_secrets=1
    fi
  done

  if [ $missing_secrets -eq 1 ]; then
    exit 1
  fi

  echo "done"
}

get_kubeconfig_from_kkp() {
  local k8cProjectId=$K8C_PROJECT_ID
  local k8cClusterId=$K8C_CLUSTER_ID
  local k8cHost=$K8C_HOST
  local k8cAuthKey=$K8C_AUTH
  local output_file="$LOCAL_FILES_DIR/kubeconfig-usercluster"

  response=$(curl -s -w "%{http_code}" \
    -o "$output_file" \
    -X GET "$k8cHost"/api/v2/projects/"$k8cProjectId"/clusters/"$k8cClusterId"/kubeconfig \
    -H "accept: application/octet-stream" \
    -H "Authorization: Bearer $k8cAuthKey")

  if [ $? -ne 0 ]; then
    echo "Error: Failed to send HTTP request to fetch kubeconfig from kkp"
    rm "$output_file"
    return 1
  fi

  if [ "$response" -ne 200 ]; then
    echo "Error: HTTP request failed with status code: $response"
    cat "$output_file"
    rm "$output_file"
    return 1
  fi

  echo "Successfully saved user cluster's kubeconfig response to $output_file"
  return 0
}

check_ssh_connection() {
  echo "checking SSH connection:"
  echo "    AWS_HOST: ${AWS_HOST}"
  echo "    SSH_KEY_PATH: ${KEY_PATH}"

  if ssh -i "$KEY_PATH" -o ConnectTimeout=5 "$AWS_HOST" exit 2>/dev/null; then
    echo "SSH connection successful"
    return 0
  else
    echo "Failed to establish SSH connection"
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
  validate_creds_file

  export AWS_HOST="ubuntu@$AWS_IP"

  echo "Starting EC2 setup..."

  if ! check_ssh_connection; then
    echo "Error: Cannot establish SSH connection. Please check your AWS_HOST and KEY_PATH."
    exit 1
  fi

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
