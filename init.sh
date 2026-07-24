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

# --- source build helpers (deploy unreleased KKP from a git ref) ---

source_is_enabled() {
	config_has '.kubermatic.source.ref'
}

# Name of the git remote we create inside the kubermatic clone to point at source.repo.
# We fetch from this remote (not the clone's origin) so a fork's origin — which may
# lack the target branch — cannot cause a spurious fetch failure. This name is owned
# by the installer and not user-configurable; ensure_source_clone creates/corrects it.
# The kkp-installer- prefix makes collisions with a user's own remote names unlikely.
readonly SOURCE_REMOTE="kkp-installer-source"

ensure_source_clone() {
	local repo="$1"
	local cloneDir="$2"

	if [ ! -d "$cloneDir/.git" ]; then
		if [ -e "$cloneDir" ]; then
			error "cloneDir '$cloneDir' exists but is not a git repository"
			return 1
		fi

		log "Cloning $repo into $cloneDir"
		if ! git clone "https://github.com/${repo}.git" "$cloneDir"; then
			error "Failed to clone $repo into $cloneDir"
			return 1
		fi
	fi

	# point a dedicated remote at source.repo so fetches don't depend on the clone's
	# origin (which may be a fork lacking the target branch). set-url is idempotent:
	# it creates the remote if missing, and corrects it if it points elsewhere.
	local upstream_url="https://github.com/${repo}.git"
	if ! git -C "$cloneDir" remote set-url "$SOURCE_REMOTE" "$upstream_url" 2>/dev/null; then
		if ! git -C "$cloneDir" remote add "$SOURCE_REMOTE" "$upstream_url"; then
			error "Failed to configure remote '$SOURCE_REMOTE' in $cloneDir"
			return 1
		fi
	fi

	# if the clone is a partial clone (filter=blob:none etc.), git lazily fetches
	# missing blobs from the promisor remote during checkout, which is origin by
	# default. when origin is a fork (or any repo lacking the ref), that fails.
	# repoint the promisor to the upstream remote so lazy fetches reach source.repo.
	configure_partial_clone_promisor "$cloneDir" "$SOURCE_REMOTE"
}

# configure_partial_clone_promisor repoints a partial clone's promisor remote to
# $remote so lazy blob fetches reach source.repo instead of the clone's origin
# (which may be a fork). no-op for a full clone, which has no partialClone extension.
configure_partial_clone_promisor() {
	local cloneDir="$1"
	local remote="$2"

	local current
	current=$(git -C "$cloneDir" config --get extensions.partialClone 2>/dev/null || echo "")
	if [ -z "$current" ] || [ "$current" = "$remote" ]; then
		return 0
	fi

	git -C "$cloneDir" config extensions.partialClone "$remote"
	git -C "$cloneDir" config "remote.${remote}.promisor" true
}

# is_git_sha returns success when $1 looks like a git commit SHA (hex, >=7 chars).
is_git_sha() {
	[[ "$1" =~ ^[0-9a-fA-F]{7,}$ ]]
}

sync_source_ref() {
	local cloneDir="$1"
	local ref="$2"

	# A raw commit SHA cannot be fetched directly over HTTPS
	# ("couldn't find remote ref <sha>"). For SHAs, refresh all refs so the commit is
	# reachable if it exists on any branch/tag, then checkout by SHA. Branch/tag refs
	# are fetched by name. Always fetch from the dedicated upstream remote so a fork's
	# origin (which may lack the branch) does not cause a spurious failure.
	if is_git_sha "$ref"; then
		log "Updating refs in $cloneDir to resolve commit $ref"
		if ! git -C "$cloneDir" fetch "$SOURCE_REMOTE"; then
			error "Failed to fetch from $SOURCE_REMOTE while resolving commit '$ref'"
			return 1
		fi
	else
		log "Fetching ref '$ref' into $cloneDir"
		if ! git -C "$cloneDir" fetch "$SOURCE_REMOTE" "$ref"; then
			error "Failed to fetch ref '$ref' from $SOURCE_REMOTE"
			return 1
		fi
	fi

	# checkout FETCH_HEAD: it always points at what was just fetched from
	# $SOURCE_REMOTE, so resolution does not depend on local/origin tracking refs
	# (a fork's origin may not have the branch). detach quietly; the detached-HEAD
	# notice is noise, real errors still surface via the exit code.
	if ! git -C "$cloneDir" checkout FETCH_HEAD 2>/dev/null; then
		error "Failed to checkout ref '$ref' in $cloneDir"
		return 1
	fi
}

# resolve_build_key sets BUILD_KEY and KKP_ARTIFACTS_DIR.
# BUILD_KEY is the resolved commit short SHA for source builds, or v<version>
# for the released download path. KKP_ARTIFACTS_DIR caches the binary + charts
# per build key, separate from KKP_FILES_DIR (prepared configs, regenerated).
resolve_build_key() {
	if source_is_enabled; then
		local repo cloneDir ref
		repo=$(config_get '.kubermatic.source.repo' 'kubermatic/kubermatic')
		cloneDir=$(config_get '.kubermatic.source.cloneDir' '../kubermatic')
		ref=$(config_get '.kubermatic.source.ref')

		if ! ensure_source_clone "$repo" "$cloneDir"; then
			return 1
		fi
		if ! sync_source_ref "$cloneDir" "$ref"; then
			return 1
		fi

		# declare separately so a failed rev-parse is not masked by export
		local full_sha short_sha
		full_sha=$(git -C "$cloneDir" rev-parse HEAD) || {
			error "Failed to resolve commit for ref '$ref'"
			return 1
		}
		short_sha=$(git -C "$cloneDir" rev-parse --short HEAD) || {
			error "Failed to resolve short commit for ref '$ref'"
			return 1
		}
		export RESOLVED_COMMIT="$full_sha"
		export BUILD_KEY="$short_sha"
		log "Resolved source ref '$ref' -> commit $RESOLVED_COMMIT (key: $BUILD_KEY)"
	else
		export RESOLVED_COMMIT=""
		export BUILD_KEY="v${KKP_VERSION#v}"
	fi

	export KKP_ARTIFACTS_DIR="$KKP_FILES_DIR/$BUILD_KEY"
	mkdir -p "$KKP_ARTIFACTS_DIR"
}

# export_kkp_env sets the KKP_* env vars that downstream functions (resolve_build_key,
# install_kubermatic_installer_build, apply_image_override) read from the environment.
# Called by both provisioning paths so the build path works under either method.
export_kkp_env() {
	local version edition host email
	version=$(config_get '.kubermatic.version')
	edition=$(config_get '.kubermatic.edition' 'ee')
	host=$(config_get '.kubermatic.domain')
	email=$(config_get '.kubermatic.email')

	export KKP_VERSION="$version"
	export KKP_EDITION="$edition"
	export KKP_HOST="$host"
	export KKP_EMAIL="$email"
}

# apply_image_override rewrites the operator image (helm values) and the controller
# component repos (KubermaticConfiguration CR) to the given repo/tag.
# spec.api is intentionally NOT overridden: the kubermatic-api binary ships in the
# dashboard image (quay.io/kubermatic/dashboard-ee), so overriding its repo crashes
# the api pod. The operator tag propagates to the controllers at runtime.
apply_image_override() {
	local repo="$1"
	local tag="$2"

	local helm_values="$KKP_FILES_DIR/helm-master-gateway.yaml"
	local kkp_cfg="$KKP_FILES_DIR/kubermatic.yaml"

	yq eval ".kubermaticOperator.image.repository = \"$repo\"" -i "$helm_values"
	if [ -n "$tag" ]; then
		yq eval ".kubermaticOperator.image.tag = \"$tag\"" -i "$helm_values"
	fi

	yq eval ".spec.seedController.dockerRepository = \"$repo\"" -i "$kkp_cfg"
	yq eval ".spec.masterController.dockerRepository = \"$repo\"" -i "$kkp_cfg"
	yq eval ".spec.webhook.dockerRepository = \"$repo\"" -i "$kkp_cfg"

	log "Applied image override: repo=$repo tag=${tag:-<chart default>}"
}

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

# install_kubermatic_installer_build builds kubermatic-installer + charts from the
# source clone checked out by resolve_build_key, into KKP_ARTIFACTS_DIR.
# resolve_git_version returns a valid semver string for GIT_VERSION, passed to
# `make kubermatic-installer` so the binary's Versions.GitVersion parses. The installer
# calls semver MustParse on this at startup (validation.go:65); a bare commit SHA
# (produced by `git describe --always` when no v* tag is reachable, e.g. a release-branch
# tip ahead of its last tag) would panic. Prefer git describe when it yields a tag-based
# version; otherwise synthesize <major>.<minor>.0-dev from a release/vX.Y ref.
resolve_git_version() {
	local cloneDir="$1"
	local ref="$2"

	local described
	described=$(git -C "$cloneDir" describe --tags --always --match='v*' 2>/dev/null || echo "")
	# describe output starting with "v" and a digit is tag-based (valid semver or prerelease).
	if [[ "$described" =~ ^v[0-9] ]]; then
		echo "$described"
		return
	fi

	# no reachable tag: synthesize from a release/vMAJOR.MINOR ref.
	if [[ "$ref" =~ ^release/v([0-9]+)\.([0-9]+)$ ]]; then
		echo "v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.0-dev"
		return
	fi

	# last resort: a clearly-dev semver so MustParse does not panic.
	echo "v0.0.0-dev"
}

install_kubermatic_installer_build() {
	local cloneDir ref
	cloneDir=$(config_get '.kubermatic.source.cloneDir' '../kubermatic')
	ref=$(config_get '.kubermatic.source.ref')

	if ! command -v go >/dev/null 2>&1; then
		error "Go toolchain not found. Install Go to build kubermatic-installer from source."
		return 1
	fi

	local git_version
	git_version=$(resolve_git_version "$cloneDir" "$ref")
	log "Building kubermatic-installer from $cloneDir at commit $RESOLVED_COMMIT (GIT_VERSION=$git_version)"

	pushd "$cloneDir" >/dev/null || {
		error "cloneDir '$cloneDir' not found"
		return 1
	}
	# pass GIT_VERSION as a make argument, not an env var: the Makefile uses
	# `GIT_VERSION = $(shell git describe ...)` (plain assignment), which ignores
	# an env override. On a shallow clone or an untagged commit, git describe hits
	# --always and yields a bare SHA, which panics the installer's semver MustParse
	# (validation.go:65). A make command-line arg overrides even a `=` assignment,
	# so resolve_git_version's valid semver actually takes effect.
	if ! KUBERMATIC_EDITION="$KKP_EDITION" make kubermatic-installer GIT_VERSION="$git_version"; then
		error "Failed to build kubermatic-installer"
		popd >/dev/null || return 1
		return 1
	fi
	popd >/dev/null || return 1

	mkdir -p "$KKP_ARTIFACTS_DIR"
	if ! cp "$cloneDir/_build/kubermatic-installer" "$KKP_ARTIFACTS_DIR/"; then
		error "Failed to copy kubermatic-installer to $KKP_ARTIFACTS_DIR"
		return 1
	fi
	if ! cp -r "$cloneDir/charts" "$KKP_ARTIFACTS_DIR/"; then
		error "Failed to copy charts to $KKP_ARTIFACTS_DIR"
		return 1
	fi
	chmod +x "$KKP_ARTIFACTS_DIR/kubermatic-installer"

	success "Built kubermatic-installer into $KKP_ARTIFACTS_DIR"
}

# install_kubermatic_installer_download fetches the released kubermatic-installer
# tarball for KKP_VERSION into KKP_ARTIFACTS_DIR (cached per build key).
install_kubermatic_installer_download() {
	# normalize KKP_VERSION by stripping 'v' prefix for URL construction
	local normalized_kkp_version="${KKP_VERSION#v}"

	local os arch
	os=$(go env GOOS)
	arch=$(go env GOARCH)

	log "Downloading KKP $KKP_VERSION ($KKP_EDITION edition) for $os/$arch..."

	local kkp_edition_str="kubermatic-$KKP_EDITION"
	local download_url="https://github.com/kubermatic/kubermatic/releases/download/v${normalized_kkp_version}/${kkp_edition_str}-v${normalized_kkp_version}-${os}-${arch}.tar.gz"
	local archive_path="$KKP_ARTIFACTS_DIR/${kkp_edition_str}-${normalized_kkp_version}.tar.gz"

	mkdir -p "$KKP_ARTIFACTS_DIR"

	log "Downloading from: $download_url"
	if ! curl -L "$download_url" --output "$archive_path"; then
		error "Failed to download kubermatic-installer"
		return 1
	fi

	log "Extracting archive into $KKP_ARTIFACTS_DIR..."
	if ! tar -xzf "$archive_path" -C "$KKP_ARTIFACTS_DIR"; then
		error "Failed to extract kubermatic-installer archive"
		return 1
	fi

	chmod +x "$KKP_ARTIFACTS_DIR/kubermatic-installer"
	rm -f "$archive_path"

	success "Downloaded kubermatic-installer to $KKP_ARTIFACTS_DIR"
}

install_kubermatic_installer() {
	log "Checking for kubermatic-installer at build key $BUILD_KEY..."

	# cache hit: a runnable binary and matching charts already exist for this key
	if [ -x "$KKP_ARTIFACTS_DIR/kubermatic-installer" ] && [ -d "$KKP_ARTIFACTS_DIR/charts" ]; then
		log "Reusing cached build at $KKP_ARTIFACTS_DIR"
		export KUBERMATIC_BINARY="$KKP_ARTIFACTS_DIR/kubermatic-installer"
		return 0
	fi

	if source_is_enabled; then
		if ! install_kubermatic_installer_build; then
			error "Failed to build kubermatic-installer from source"
			return 1
		fi
	else
		if ! install_kubermatic_installer_download; then
			error "Failed to download kubermatic-installer"
			return 1
		fi
	fi

	export KUBERMATIC_BINARY="$KKP_ARTIFACTS_DIR/kubermatic-installer"

	local version
	version=$("$KUBERMATIC_BINARY" version -s 2>/dev/null || echo "unknown")
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
		--charts-directory "$KKP_ARTIFACTS_DIR/charts" \
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
		--charts-directory "$KKP_ARTIFACTS_DIR/charts" \
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
		--charts-directory "$KKP_ARTIFACTS_DIR/charts" \
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
		--charts-directory "$KKP_ARTIFACTS_DIR/charts" \
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

	# --- image precedence: imageOverride wins, else derive from source ---
	local image_repo=""
	local image_tag=""

	if config_has '.kubermatic.imageOverride.repository'; then
		image_repo=$(config_get '.kubermatic.imageOverride.repository' '')
		image_tag=$(config_get '.kubermatic.imageOverride.tag' '')
	elif source_is_enabled; then
		# imageOverride absent and source set: derive a coherent image set from the commit.
		# controllers inherit the operator tag at runtime, so pinning the operator tag
		# (the resolved commit) pins every component.
		# use the FULL sha (RESOLVED_COMMIT) as the image tag, matching what kubermatic CI
		# pushes to quay (KUBERMATICDOCKERTAG = git rev-parse HEAD for untagged commits).
		# BUILD_KEY is the short sha, kept short only for the cache dir name; quay has no
		# :<short-sha> tag, so deploying it would ImagePullBackOff.
		image_repo="quay.io/kubermatic/kubermatic-${KKP_EDITION}"
		image_tag="$RESOLVED_COMMIT"
		log "imageOverride absent; deriving images from source commit $RESOLVED_COMMIT"
	fi

	if [ -n "$image_repo" ]; then
		apply_image_override "$image_repo" "$image_tag"
	fi

	# dashboard (api + ui) image tag: the dashboard ships in a SEPARATE repo
	# (quay.io/kubermatic/dashboard-<edition>, built from kubermatic/dashboard),
	# which is NOT tagged with the kubermatic commit sha we pin the operator to.
	# without this, the api pod defaults to versions.KubermaticContainerTag (the
	# kubermatic sha -> ImagePullBackOff) and ui defaults to the operator's
	# uiContainerTag (NA when built by init.sh). pin both to a released dashboard
	# tag for the branch, e.g. v2.30.5. the operator honors spec.{api,ui}.dockerTag
	# over its baked-in defaults (api.go:250, ui.go:58).
	local dashboard_tag
	dashboard_tag=$(config_get '.kubermatic.dashboardTag' '')
	if [ -n "$dashboard_tag" ]; then
		yq eval ".spec.api.dockerTag = \"$dashboard_tag\"" -i "$KKP_FILES_DIR/kubermatic.yaml"
		yq eval ".spec.ui.dockerTag = \"$dashboard_tag\"" -i "$KKP_FILES_DIR/kubermatic.yaml"
		log "Pinned dashboard (api + ui) image tag to $dashboard_tag"
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
		--charts-directory "$KKP_ARTIFACTS_DIR/charts" \
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
		--charts-directory "$KKP_ARTIFACTS_DIR/charts" \
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
			--charts-directory "$KKP_ARTIFACTS_DIR/charts" \
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
			--charts-directory "$KKP_ARTIFACTS_DIR/charts" \
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

	# set env vars that downstream functions still read from env
	export_kkp_env

	# resolve the build key (resolved commit or v<version>) so install_kubermatic_installer
	# and the deploy step have KKP_ARTIFACTS_DIR set, matching the kubeone path.
	if ! resolve_build_key; then
		error "Failed to resolve build key"
		exit 1
	fi

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
	export_kkp_env

	# resolve the build key (resolved commit or v<version>) before any work that
	# depends on KKP_ARTIFACTS_DIR or the resolved commit. Runs regardless of
	# skipInfra so the key is always known.
	if ! resolve_build_key; then
		error "Failed to resolve build key"
		exit 1
	fi

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
