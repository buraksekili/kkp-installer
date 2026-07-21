#!/bin/bash

set -euo pipefail

# disable the interactive pager so aws CLI output goes directly to stdout
export AWS_PAGER=""

source utils.sh

KKP_FILES_DIR="$(dirname $0)/kkp-files"
REMOTE_DIR=${REMOTE_DIR:-"/home/ubuntu"}

declare -a required_secrets_kkp=(
	"K8C_PROJECT_ID"
	"K8C_HOST"
	"K8C_AUTH"
	"KKP_VERSION"
	"KKP_HOST"
	"KKP_EMAIL"
)

declare -a required_secrets_kubeone=(
	"ADMIN_PASSWORD"
	"VAULT_SECRET"
	"VAULT_AWS_PATH"
	"VAULT_ROUTE53_PATH"
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

	local secrets_list
	if [ "$PROVISIONING_METHOD" = "kubeone" ]; then
		secrets_list=("${required_secrets_kubeone[@]}")
	else
		secrets_list=("${required_secrets_kkp[@]}")
	fi

	missing_secrets=0
	for secret in "${secrets_list[@]}"; do
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
	if kubectl config get-clusters 2>/dev/null | tail -n +2 | grep -q "^${K8C_CLUSTER_ID}$"; then
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
	local k8c_host="$K8C_HOST"
	local kkp_token="$K8C_AUTH"
	local output_file="$KKP_FILES_DIR/kubeconfig-usercluster"

	if [ -z "$project_id" ] || [ -z "$cluster_id" ] || [ -z "$k8c_host" ] || [ -z "$kkp_token" ]; then
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

	local temp_file=$(mktemp)
	trap 'rm -f "$temp_file"' RETURN

	local http_status
	http_status=$(curl -s -w "%{http_code}" \
		-o "$temp_file" \
		-X GET "${k8c_host}/api/v2/projects/${project_id}/clusters/${cluster_id}/kubeconfig" \
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

	export KUBECONFIG="$output_file"

	success "Successfully downloaded kubeconfig to $output_file"
	log "Kubeconfig details:"
	echo "  Project ID: $project_id"
	echo "  Cluster ID: $cluster_id"
	echo "  Output file: $output_file"
	echo "  KUBECONFIG: $KUBECONFIG"

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
	log "Preparing KKP configs in $KKP_FILES_DIR, creating directory if it doesn't exist..."
	mkdir -p "$KKP_FILES_DIR"

	log "Generating random secret key for dex client secret..."
	if ! generate_random_secret_key "$KKP_FILES_DIR/random-secret-key"; then
		error "Failed to generate random secret key"
		exit 1
	fi

	log "Fetching files from vault. If you are not logged in to vault, please do so via 'vault login'"

	vault kv get -field=presets.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/presets.yaml"
	vault kv get -field=kubermatic.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/kubermatic.yaml"
	vault kv get -field=helm-master.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/helm-master.yaml"
	vault kv get -field=helm-seed-shared.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/helm-seed-shared.yaml"
	vault kv get -field=helm-seed-shared-mla.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/values-seed-mla.yaml"

	# update KubermaticConfiguration

	yq eval 'del(.spec.applications)' -i "$KKP_FILES_DIR/kubermatic.yaml"

	yq eval '.spec.featureGates.UserClusterMLA = true' -i "$KKP_FILES_DIR/kubermatic.yaml"
	yq eval '.spec.featureGates.VerticalPodAutoscaler = false' -i "$KKP_FILES_DIR/kubermatic.yaml"
	yq eval '.spec.ingress.domain = "'$KKP_HOST'"' -i "$KKP_FILES_DIR/kubermatic.yaml"

	# update helm master file
	if ! update_helm_master_file "$KKP_FILES_DIR/helm-master.yaml"; then
		error "Failed to update helm-master file"
		exit 1
	fi

	# update seed manifest
	if ! remove_yaml_scheduling_config "$KKP_FILES_DIR/helm-seed-shared.yaml"; then
		error "Failed to remove YAML scheduling configurations"
		exit 1
	fi

	yq eval '.minio.storeSize = "25Gi"' -i "$KKP_FILES_DIR/helm-seed-shared.yaml"

	##########################################
	# update seed mla values
	##########################################
	yq eval '.prometheus.tsdb.retentionTime = "1h"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	# disable backup
	yq eval '.prometheus.backup.enabled = false' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	# reduce resources
	yq eval '.prometheus.containers.prometheus.resources.requests.cpu = "0.5"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval '.prometheus.containers.prometheus.resources.requests.memory = "500Mi"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	# disable blackbox exporter
	yq eval '.prometheus.scraping.blackBoxExporter.enabled = false' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	# yq eval '.prometheus.scraping.configs = []' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	sed -i '' 's/dev.kubermatic.io/'"$KKP_HOST"'/g' "$KKP_FILES_DIR/values-seed-mla.yaml"
	# remove loki services
	yq eval 'del(.prometheus.provisioning.datasources.lokiServices)' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	# decrease the number of alertmanager replicas
	yq eval '.alertmanager.replicaCount = 1' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	# aws ebs io1 volume supports 4Gi at least
	yq eval '.alertmanager.persistence.size = "4Gi"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"

	# cortex persistence sizing - aws ebs io1 requires minimum 4Gi
	yq eval '.cortex.alertmanager.persistentVolume.size = "4Gi"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval '.cortex.ingester.persistentVolume.size = "4Gi"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval '.cortex.store_gateway.persistentVolume.size = "4Gi"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval '.cortex.compactor.persistentVolume.size = "4Gi"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"

	# loki-distributed persistence sizing
	yq eval '
		.loki-distributed.ingester.persistence.claims[0].name = "data" |
		.loki-distributed.ingester.persistence.claims[0].size = "4Gi" |
		.loki-distributed.ingester.persistence.claims[0].storageClass = "kubermatic-fast"
	' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval '.loki-distributed.querier.persistence.size = "4Gi"' -i "$KKP_FILES_DIR/values-seed-mla.yaml"

	# fix grafana.dashboards - must be a map of provider names, not configuration properties
	# the vault-stored file has incorrect structure (editable/datasourceHide) that causes helm template errors
	yq eval '.grafana.dashboards = {}' -i "$KKP_FILES_DIR/values-seed-mla.yaml"

	# remove loki, karma, promtail, kube-state-metrics, helm-exporter
	yq eval 'del(.loki)' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval 'del(.karma)' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval 'del(.promtail)' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval 'del(.kube-state-metrics)' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval 'del(.helm-exporter)' -i "$KKP_FILES_DIR/values-seed-mla.yaml"

	if ! remove_yaml_scheduling_config "$KKP_FILES_DIR/values-seed-mla.yaml"; then
		error "Failed to remove YAML scheduling configurations"
		exit 1
	fi

	cp remote/cluster-issuer.yaml "$KKP_FILES_DIR"
	yq eval '.spec.acme.email = "'$KKP_EMAIL'"' -i "$KKP_FILES_DIR/cluster-issuer.yaml"

	success "Files prepared successfully"
}

install_kubermatic_installer() {
	log "Checking for kubermatic-installer availability for $KKP_VERSION..."

	# normalize KKP_VERSION by stripping 'v' prefix for comparison and URL construction
	local normalized_kkp_version="${KKP_VERSION#v}"

	if [[ -f "$KKP_FILES_DIR/kubermatic-installer" && -d "$KKP_FILES_DIR/charts" ]]; then
		local installed_version
		installed_version=$(get_kubermatic_installer_version "$KKP_FILES_DIR/kubermatic-installer")

		if [[ "$installed_version" == "$normalized_kkp_version" ]]; then
			log "Found kubermatic-installer v$installed_version in kkp-files directory (matches requested version)"
			chmod +x "$KKP_FILES_DIR/kubermatic-installer"
			success "Using kubermatic-installer from kkp-files directory"
			export KUBERMATIC_BINARY="$KKP_FILES_DIR/kubermatic-installer"
			return 0
		fi

		log "Found kubermatic-installer v$installed_version but v$KKP_VERSION is required. Downloading..."
		rm -f "$KKP_FILES_DIR/kubermatic-installer"
		rm -rf "$KKP_FILES_DIR/charts"
	fi

	local os=$(go env GOOS)
	local arch=$(go env GOARCH)

	log "kubermatic-installer not found locally. Downloading KKP $KKP_VERSION ($KKP_EDITION edition) for $os/$arch..."

	local kkp_edition_str="kubermatic-$KKP_EDITION"
	local download_url="https://github.com/kubermatic/kubermatic/releases/download/v${normalized_kkp_version}/${kkp_edition_str}-v${normalized_kkp_version}-${os}-${arch}.tar.gz"
	local archive_path="$KKP_FILES_DIR/kkp-manifests/${kkp_edition_str}-${normalized_kkp_version}.tar.gz"

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
	if ! install_kubermatic_installer; then
		error "failed to install kubermatic_installer"
		return 1
	fi

	log "===> Installing KKP Master Cluster"

	kubectl apply -f "seeds.yaml"

	if ! $KUBERMATIC_BINARY deploy kubermatic-master \
		--config "$KKP_FILES_DIR/kubermatic.yaml" \
		--helm-values "$KKP_FILES_DIR/helm-master-gateway.yaml" \
		--kubeconfig "$KKP_FILES_DIR/kubeconfig-usercluster" \
		--deploy-default-app-catalog \
		--storageclass aws \
		--mla-include-iap \
		--migrate-gateway-api \
		--charts-directory "$KKP_FILES_DIR/charts" \
		--verbose; then
		error "Failed to deploy KKP Master Cluster"
		return 1
	fi
	
	kubectl apply -f "$KKP_FILES_DIR/cluster-issuer.yaml"

	success "KKP Master Cluster installed successfully"

	$KUBERMATIC_BINARY convert-kubeconfig "$KKP_FILES_DIR/kubeconfig-kubeone" >"$KKP_FILES_DIR/kubeconfig-seed"

	# if you deploy seed CR before deploying seed cluster, you'll get useful
	# log messages to set DNS, which is helpful.
	encodedSeedKubeconfig=$(base64 -i "$KKP_FILES_DIR/kubeconfig-seed" | tr -d '\n')
	yq eval '(select(.kind == "Secret" and .metadata.name == "kubeconfig-seed-kkp-qa-env") | .data.kubeconfig) = "'"$encodedSeedKubeconfig"'"' -i seeds.yaml
	kubectl apply -f "seeds.yaml"

	if ! $KUBERMATIC_BINARY deploy kubermatic-seed \
		--config "$KKP_FILES_DIR/kubermatic.yaml" \
		--helm-values "$KKP_FILES_DIR/helm-seed-shared.yaml" \
		--kubeconfig "$KKP_FILES_DIR/kubeconfig-kubeone" \
		--mla-include-iap \
		--migrate-gateway-api \
		--charts-directory "$KKP_FILES_DIR/charts" \
		--verbose; then
		error "Failed to deploy KKP Seed Cluster"
		return 1
	fi

	kubectl apply -f "$KKP_FILES_DIR/presets.yaml"

	success "KKP Seed Cluster installed successfully"

	log "Installing KKP Seed MLA..."

	if ! $KUBERMATIC_BINARY deploy seed-mla \
		--config "$KKP_FILES_DIR/kubermatic.yaml" \
		--helm-values "$KKP_FILES_DIR/values-seed-mla.yaml" \
		--kubeconfig "$KKP_FILES_DIR/kubeconfig-kubeone" \
		--charts-directory "$KKP_FILES_DIR/charts" \
		--mla-include-iap \
		--migrate-gateway-api \
		--verbose; then
		error "Failed to deploy KKP Seed MLA"
		return 1
	fi

	success "KKP Seed MLA installed"

	log "Installing KKP UserCluster MLA..."

	if ! $KUBERMATIC_BINARY deploy usercluster-mla \
		--config "$KKP_FILES_DIR/kubermatic.yaml" \
		--helm-values "$KKP_FILES_DIR/values-seed-mla.yaml" \
		--kubeconfig "$KKP_FILES_DIR/kubeconfig-kubeone" \
		--charts-directory "$KKP_FILES_DIR/charts" \
		--helm-timeout="10m" \
		--mla-include-iap \
		--migrate-gateway-api \
		--verbose; then
		error "Failed to deploy KKP UserCluster MLA"
		return 1
	fi

	success "KKP UserCluster MLA installed"
}

prepare_kkp_configs_kubeone() {
	log "Preparing KKP configs for KubeOne deployment..."
	mkdir -p "$KKP_FILES_DIR"

	if ! generate_random_secret_key "$KKP_FILES_DIR/random-secret-key"; then
		error "Failed to generate random secret key"
		exit 1
	fi

	log "Fetching KKP configs from Vault..."
	vault kv get -field=presets.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/presets.yaml"
	vault kv get -field=kubermatic.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/kubermatic.yaml"
	vault kv get -field=helm-master.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/helm-master.yaml"
	vault kv get -field=helm-seed-shared.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/helm-seed-shared.yaml"
	vault kv get -field=helm-seed-shared-mla.yaml "$VAULT_SECRET" >"$KKP_FILES_DIR/values-seed-mla.yaml"

	# --- kubermatic.yaml ---
	local kkp_domain
	kkp_domain=$(config_get '.kubermatic.domain')
	local expose_strategy
	expose_strategy=$(config_get '.kubermatic.exposeStrategy' 'Tunneling')

	yq eval 'del(.spec.applications)' -i "$KKP_FILES_DIR/kubermatic.yaml"

	if config_enabled '.features.userClusterMLA'; then
		yq eval '.spec.featureGates.UserClusterMLA = true' -i "$KKP_FILES_DIR/kubermatic.yaml"
	else
		yq eval '.spec.featureGates.UserClusterMLA = false' -i "$KKP_FILES_DIR/kubermatic.yaml"
	fi

	if config_enabled '.features.verticalPodAutoscaler'; then
		yq eval '.spec.featureGates.VerticalPodAutoscaler = true' -i "$KKP_FILES_DIR/kubermatic.yaml"
	else
		yq eval '.spec.featureGates.VerticalPodAutoscaler = false' -i "$KKP_FILES_DIR/kubermatic.yaml"
	fi

	yq eval ".spec.ingress.domain = \"$kkp_domain\"" -i "$KKP_FILES_DIR/kubermatic.yaml"
	yq eval ".spec.exposeStrategy = \"$expose_strategy\"" -i "$KKP_FILES_DIR/kubermatic.yaml"

	# --- helm-master.yaml ---
	# update_helm_master_file reads KKP_HOST and KKP_EMAIL from env.
	# set them from config so the function works without changes.
	export KKP_HOST="$kkp_domain"
	export KKP_EMAIL=$(config_get '.kubermatic.email')

	if ! update_helm_master_file "$KKP_FILES_DIR/helm-master.yaml"; then
		error "Failed to update helm-master file"
		exit 1
	fi

	# if gateway API is enabled, inject gateway-specific fields into helm-master
	# and write the result as helm-master-gateway.yaml (which deploy commands reference)
	if config_enabled '.features.gatewayAPI'; then
		cp "$KKP_FILES_DIR/helm-master.yaml" "$KKP_FILES_DIR/helm-master-gateway.yaml"
		yq eval '.migrateGatewayAPI = true' -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		yq eval '.httpRoute.gatewayName = "kubermatic"' -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		yq eval '.httpRoute.gatewayNamespace = "kubermatic"' -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		yq eval ".httpRoute.domain = \"$kkp_domain\"" -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		yq eval '.httpRoute.timeout = "3600s"' -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		yq eval '.cert-manager.config.apiVersion = "controller.config.cert-manager.io/v1alpha1"' -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		yq eval '.cert-manager.config.kind = "ControllerConfiguration"' -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		yq eval '.cert-manager.config.enableGatewayAPI = true' -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		log "Generated helm-master-gateway.yaml with Gateway API fields"
	else
		# non-gateway: deploy commands still reference helm-master-gateway.yaml,
		# so copy the base file under that name
		cp "$KKP_FILES_DIR/helm-master.yaml" "$KKP_FILES_DIR/helm-master-gateway.yaml"
	fi

	# --migrate-gateway-api is passed to every deploy step when gatewayAPI is on,
	# and each step requires migrateGatewayAPI=true in its own helm-values file.
	# the master file is handled above; set it on the seed and MLA value files too.
	if config_enabled '.features.gatewayAPI'; then
		yq eval '.migrateGatewayAPI = true' -i "$KKP_FILES_DIR/helm-seed-shared.yaml"
		yq eval '.migrateGatewayAPI = true' -i "$KKP_FILES_DIR/values-seed-mla.yaml"
		log "Set migrateGatewayAPI=true on seed and MLA helm values"
	fi

	# --- image override ---
	local image_repo
	image_repo=$(config_get '.kubermatic.imageOverride.repository' '')
	if [ -n "$image_repo" ] && [ "$image_repo" != "null" ]; then
		local image_tag
		image_tag=$(config_get '.kubermatic.imageOverride.tag' '')

		log "Applying image override: repository=$image_repo tag=${image_tag:-<derived from version>}"

		# operator pod image (helm-master-gateway.yaml is the final file used by the installer)
		yq eval ".kubermaticOperator.image.repository = \"$image_repo\"" -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		if [ -n "$image_tag" ] && [ "$image_tag" != "null" ]; then
			yq eval ".kubermaticOperator.image.tag = \"$image_tag\"" -i "$KKP_FILES_DIR/helm-master-gateway.yaml"
		fi

		# KKP component images managed by the operator.
		# NOTE: spec.api is intentionally NOT overridden. The kubermatic-api binary
		# ships in the dashboard image (quay.io/kubermatic/dashboard-ee), not the
		# kubermatic-ee image. Overriding it with the kubermatic-ee repo makes the
		# api pod crash with "kubermatic-api: executable file not found in $PATH".
		yq eval ".spec.seedController.dockerRepository = \"$image_repo\"" -i "$KKP_FILES_DIR/kubermatic.yaml"
		yq eval ".spec.masterController.dockerRepository = \"$image_repo\"" -i "$KKP_FILES_DIR/kubermatic.yaml"
		yq eval ".spec.webhook.dockerRepository = \"$image_repo\"" -i "$KKP_FILES_DIR/kubermatic.yaml"

		log "Image override applied"
	fi

	# --- helm-seed-shared.yaml ---
	if ! remove_yaml_scheduling_config "$KKP_FILES_DIR/helm-seed-shared.yaml"; then
		error "Failed to update seed manifest"
		exit 1
	fi
	extract_helm_overlay "helmSeed" "$KKP_FILES_DIR/values-seed-overlay.yaml"
	if [ -f "$KKP_FILES_DIR/values-seed-overlay.yaml" ]; then
		yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
			"$KKP_FILES_DIR/helm-seed-shared.yaml" "$KKP_FILES_DIR/values-seed-overlay.yaml" \
			> "$KKP_FILES_DIR/helm-seed-shared-merged.yaml"
		mv "$KKP_FILES_DIR/helm-seed-shared-merged.yaml" "$KKP_FILES_DIR/helm-seed-shared.yaml"
		rm "$KKP_FILES_DIR/values-seed-overlay.yaml"
	fi

	# --- values-seed-mla.yaml ---
	# base cleanup: domain substitution and structural removals
	sed -i '' "s/dev.kubermatic.io/$kkp_domain/g" "$KKP_FILES_DIR/values-seed-mla.yaml"
	yq eval 'del(.prometheus.provisioning.datasources.lokiServices)' -i "$KKP_FILES_DIR/values-seed-mla.yaml"

	# grafana.dashboards must be a map, not configuration properties
	# the vault-stored file has incorrect structure that causes helm template errors
	yq eval '.grafana.dashboards = {}' -i "$KKP_FILES_DIR/values-seed-mla.yaml"

	if ! remove_yaml_scheduling_config "$KKP_FILES_DIR/values-seed-mla.yaml"; then
		error "Failed to update MLA values"
		exit 1
	fi

	# apply overlay from config (sizing, disabling, nulling keys)
	extract_helm_overlay "seedMLA" "$KKP_FILES_DIR/values-seed-mla-overlay.yaml"
	if [ -f "$KKP_FILES_DIR/values-seed-mla-overlay.yaml" ]; then
		yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
			"$KKP_FILES_DIR/values-seed-mla.yaml" "$KKP_FILES_DIR/values-seed-mla-overlay.yaml" \
			> "$KKP_FILES_DIR/values-seed-mla-merged.yaml"
		mv "$KKP_FILES_DIR/values-seed-mla-merged.yaml" "$KKP_FILES_DIR/values-seed-mla.yaml"
		rm "$KKP_FILES_DIR/values-seed-mla-overlay.yaml"
	fi

	# --- ClusterIssuer (DNS01 with Route53) ---
	cat >"$KKP_FILES_DIR/cluster-issuer.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $KKP_EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
    - dns01:
        route53:
          region: ${AWS_REGION:-eu-central-1}
          accessKeyIDSecretRef:
            name: route53-credentials
            key: access-key-id
          secretAccessKeySecretRef:
            name: route53-credentials
            key: secret-access-key
EOF

	cat >"$KKP_FILES_DIR/route53-credentials.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: route53-credentials
  namespace: cert-manager
type: Opaque
stringData:
  access-key-id: $ROUTE53_ACCESS_KEY_ID
  secret-access-key: $ROUTE53_SECRET_ACCESS_KEY
EOF

	success "KKP configs prepared for KubeOne deployment"
}

install_kubermatic_kubeone() {
	if ! install_kubermatic_installer; then
		error "Failed to install kubermatic-installer"
		return 1
	fi

	export KUBERMATIC_BINARY="$KKP_FILES_DIR/kubermatic-installer"

	log "Installing KKP on KubeOne cluster..."

	# build feature flags from config
	local feature_flags=()
	if config_enabled '.features.gatewayAPI'; then
		feature_flags+=(--migrate-gateway-api)
	fi
	if config_enabled '.features.mlaIncludeIAP'; then
		feature_flags+=(--mla-include-iap)
	fi
	if config_enabled '.features.appCatalog'; then
		feature_flags+=(--deploy-default-app-catalog)
	fi

	local storage_class
	storage_class=$(config_get '.kubermatic.storageClass' '')
	local storageclass_flag=()
	if [ -n "$storage_class" ] && [ "$storage_class" != "null" ]; then
		storageclass_flag=(--storageclass "$storage_class")
	fi

	# Seed CR (hardcoded, not templated)
	cat >"$KKP_FILES_DIR/seed.yaml" <<EOF
apiVersion: kubermatic.k8c.io/v1
kind: Seed
metadata:
  name: kubermatic
  namespace: kubermatic
spec:
  country: DE
  location: Frankfurt
  exposeStrategy: Tunneling
  kubeconfig:
    apiVersion: v1
    kind: Secret
    name: kubeconfig-kubermatic
    namespace: kubermatic
    fieldPath: kubeconfig
  mla:
    userClusterMLAEnabled: true
  datacenters:
    aws-eu-central-1:
      country: DE
      location: EU (Frankfurt)
      spec:
        aws:
          region: eu-central-1
    byo-europe-west3-c:
      country: DE
      location: Frankfurt
      spec:
        bringyourown: {}
EOF

	log "Installing KKP Master Cluster on KubeOne cluster..."
	if ! $KUBERMATIC_BINARY deploy kubermatic-master \
		--config "$KKP_FILES_DIR/kubermatic.yaml" \
		--helm-values "$KKP_FILES_DIR/helm-master-gateway.yaml" \
		--kubeconfig "$KUBECONFIG" \
		"${storageclass_flag[@]}" \
		"${feature_flags[@]}" \
		--charts-directory "$KKP_FILES_DIR/charts" \
		--verbose; then
		error "Failed to deploy KKP Master"
		return 1
	fi

	# Apply Route53 credentials for cert-manager
	kubectl apply -f "$KKP_FILES_DIR/route53-credentials.yaml"

	# Apply ClusterIssuer
	kubectl apply -f "$KKP_FILES_DIR/cluster-issuer.yaml"

	success "KKP Master installed"

	# Create in-cluster kubeconfig for Seed
	$KUBERMATIC_BINARY convert-kubeconfig "$KUBECONFIG" >"$KKP_FILES_DIR/kubeconfig-seed"

	# Create kubeconfig secret
	kubectl create secret generic kubeconfig-kubermatic \
		--namespace kubermatic \
		--from-file=kubeconfig="$KKP_FILES_DIR/kubeconfig-seed" \
		--dry-run=client -o yaml | kubectl apply -f -

	# Apply Seed CR
	kubectl apply -f "$KKP_FILES_DIR/seed.yaml"

	log "Installing KKP Seed Cluster on KubeOne cluster..."
	if ! $KUBERMATIC_BINARY deploy kubermatic-seed \
		--config "$KKP_FILES_DIR/kubermatic.yaml" \
		--helm-values "$KKP_FILES_DIR/helm-seed-shared.yaml" \
		--kubeconfig "$KUBECONFIG" \
		"${feature_flags[@]}" \
		--charts-directory "$KKP_FILES_DIR/charts" \
		--verbose; then
		error "Failed to deploy KKP Seed"
		return 1
	fi

	# Apply presets
	kubectl apply -f "$KKP_FILES_DIR/presets.yaml"

	success "KKP Seed installed"

	# seed MLA
	if config_enabled '.seedMLA.enabled'; then
		log "Installing KKP Seed MLA..."
		if ! $KUBERMATIC_BINARY deploy seed-mla \
			--config "$KKP_FILES_DIR/kubermatic.yaml" \
			--helm-values "$KKP_FILES_DIR/values-seed-mla.yaml" \
			--kubeconfig "$KUBECONFIG" \
			"${feature_flags[@]}" \
			--charts-directory "$KKP_FILES_DIR/charts" \
			--verbose; then
			error "Failed to deploy KKP Seed MLA"
			return 1
		fi
		success "KKP Seed MLA installed"
	else
		log "Seed MLA disabled, skipping"
	fi

	# usercluster MLA
	if config_enabled '.userClusterMLA.enabled'; then
		log "Installing KKP UserCluster MLA..."
		local helm_timeout
		helm_timeout=$(config_get '.userClusterMLA.helmTimeout' '15m')
		if ! $KUBERMATIC_BINARY deploy usercluster-mla \
			--config "$KKP_FILES_DIR/kubermatic.yaml" \
			--helm-values "$KKP_FILES_DIR/values-seed-mla.yaml" \
			--kubeconfig "$KUBECONFIG" \
			--helm-timeout "$helm_timeout" \
			"${feature_flags[@]}" \
			--charts-directory "$KKP_FILES_DIR/charts" \
			--verbose; then
			error "Failed to deploy KKP UserCluster MLA"
			return 1
		fi
		success "KKP UserCluster MLA installed"
	else
		log "UserCluster MLA disabled, skipping"
	fi
}

provision_with_kkp() {
	log "Using KKP-within-KKP provisioning method"

	# if SKIP_CLUSTER_CREATION is set, we need proper K8C_CLUSTER_ID to be set
	# if K8C_CLUSTER_ID is not set, thrown an error
	if [[ -n "$SKIP_CLUSTER_CREATION" && -z "$K8C_CLUSTER_ID" ]]; then
		error "If the cluster creation is skipped via SKIP_CLUSTER_CREATION environment variable, please provide K8C_CLUSTER_ID environment variable to point out the cluster where KKP will be installed"
		exit 1
	fi

	prepare_kkp_configs
	log "KKP files are populated in $KKP_FILES_DIR"

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

		if ! list_recently_created_clusters "$K8C_PROJECT_ID" "$K8C_AUTH" "$K8C_HOST"; then
			error "failed to create the cluster"
			exit 1
		fi

		log "Waiting for cluster nodes to be ready with external IPs..."
		wait_timeout=${WAIT_TIMEOUT_MINUTES:-15}
		if ! wait_for_nodes_external_ip "$K8C_PROJECT_ID" "$K8C_CLUSTER_ID" "$K8C_AUTH" "$K8C_HOST" "$wait_timeout"; then
			error "Timed out waiting for cluster nodes to have external IPs"
			exit 1
		fi

		success "Found node with external IP"
	fi

	log "Waiting for cluster nodes to be ready with external IPs..."
	wait_timeout=${WAIT_TIMEOUT_MINUTES:-15}
	if ! wait_for_nodes_external_ip "$K8C_PROJECT_ID" "$K8C_CLUSTER_ID" "$K8C_AUTH" "$K8C_HOST" "$wait_timeout"; then
		error "Timed out waiting for cluster nodes to have external IPs"
		exit 1
	fi

	echo "Fetching user cluster kubeconfig from kkp"
	if ! get_kubeconfig_from_kkp; then
		error "Failed to fetch kubeconfig from KKP"
		exit 1
	fi

	if ! check_cluster_match; then
		error "Cluster ID validation failed. Please ensure K8C_CLUSTER_ID matches a cluster in your kubectl config"
		exit 1
	fi

	if ! install_kubermatic; then
		error "Failed to install Kubermatic"
		exit 1
	fi

	success "KKP Master & Seed (shared) cluster should be installed successfully"
	log "Ensure that DNS records are updated accordingly"
}

vault_login() {
	if vault token lookup >/dev/null 2>&1; then
		log "Already logged in to Vault"
		return 0
	fi

	log "Not logged in to Vault. Please log in to Vault to proceed."
	exit 1
}

provision_with_kubeone() {
	vault_login

	# set env vars that downstream functions still read from env
	export KKP_VERSION=$(config_get '.kubermatic.version')
	export KKP_EDITION=$(config_get '.kubermatic.edition' 'ee')
	export KKP_HOST=$(config_get '.kubermatic.domain')
	export KKP_EMAIL=$(config_get '.kubermatic.email')

	# SKIP_INFRA env var overrides the config default when set to a non-empty value.
	local skip_infra=false
	if config_enabled '.skipInfra'; then
		skip_infra=true
	fi
	if [ -n "${SKIP_INFRA:-}" ]; then
		skip_infra=true
	fi

	log "Using KubeOne AWS provisioning method"

	# Check for TLS backup
	local tls_backup_file="$KKP_FILES_DIR/tls-backup.yaml"
	local tls_backup_exists=false
	if check_tls_backup "$tls_backup_file"; then
		tls_backup_exists=true
	fi

	if [ "$skip_infra" = false ]; then
		# Fetch AWS resource credentials from Vault
		if ! fetch_aws_credentials_from_vault; then
			error "Failed to fetch AWS resource credentials"
			exit 1
		fi

		# Fetch Route53 DNS credentials from Vault
		if ! fetch_route53_credentials_from_vault; then
			error "Failed to fetch Route53 credentials"
			exit 1
		fi

		generate_kubeone_tfvars
		render_kubeone_config

		if ! provision_kubeone_cluster; then
			error "Failed to provision KubeOne cluster"
			exit 1
		fi

		if ! get_kubeconfig_from_kubeone; then
			error "Failed to fetch kubeconfig"
			exit 1
		fi
	else
		log "Skipping infrastructure provisioning (skipInfra is true)"
		export KUBECONFIG="$KKP_FILES_DIR/kubeconfig-kubeone"
		if [ ! -f "$KUBECONFIG" ]; then
			error "Kubeconfig not found at $KUBECONFIG. Infrastructure must be provisioned first."
			exit 1
		fi
	fi

	# Fetch Route53 credentials for cert-manager (needed even when skipping infra)
	if ! fetch_route53_credentials_from_vault; then
		error "Failed to fetch Route53 credentials"
		exit 1
	fi

	# Prepare KKP configs (reuse existing function)
	prepare_kkp_configs_kubeone

	# # Restore TLS if backup exists (before cert-manager)
	# if [ "$tls_backup_exists" = true ]; then
	#   restore_tls_from_backup "$tls_backup_file"
	# fi

	# Install KKP
	if ! install_kubermatic_kubeone; then
		error "Failed to install Kubermatic"
		exit 1
	fi

	# Update Route53 DNS records directly (replaces ExternalDNS)
	local gateway_api_enabled=false
	if config_enabled '.features.gatewayAPI'; then
		gateway_api_enabled=true
	fi
	if ! update_route53_dns_records "$KKP_HOST" "kubermatic" "" "$gateway_api_enabled"; then
		error "Failed to update Route53 DNS records"
		exit 1
	fi

	# Backup TLS certificate (after successful installation)
	backup_tls_secret "kubermatic-tls" "kubermatic" "$tls_backup_file"

	success "KKP installed successfully on KubeOne cluster"
}

main() {
	SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-""}

	# load config to determine provisioning method
	load_config
	PROVISIONING_METHOD=$(config_get '.provisioningMethod' 'kubeone')

	log "Starting KKP installation with provisioning method: $PROVISIONING_METHOD"

	# Validate seeds.yaml exists (only for KKP method)
	if [ "$PROVISIONING_METHOD" = "kkp" ]; then
		if [ ! -f "seeds.yaml" ]; then
			error "seeds.yaml not found in the current directory
      Ensure that Seed CR (including its Secret) is present in the current directory, as it will be used to install the seed cluster.
      "
			exit 1
		fi
	fi

	validate_creds_file

	# Branch based on provisioning method
	case "$PROVISIONING_METHOD" in
	kubeone)
		provision_with_kubeone
		;;
	kkp)
		provision_with_kkp
		;;
	*)
		error "Unknown provisioningMethod: $PROVISIONING_METHOD. Use 'kubeone' or 'kkp'."
		exit 1
		;;
	esac
}

main
