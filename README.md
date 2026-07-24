# KKP-within-KKP Deployment Script

Create a KKP master/shared cluster within an existing user cluster deployed in KKP!

You'll also need:

- Access to a KKP instance with permissions to create clusters
- A valid KKP API token
- A cluster template configured in your KKP project

> Old branch can be found https://github.com/buraksekili/kkp-installer/tree/old

## Optional: direnv Setup

For automatic credential loading, you can use [direnv](https://direnv.net/):

1. Install direnv: `brew install direnv` (macOS) or see [installation docs](https://direnv.net/docs/installation.html)
2. Hook direnv into your shell: `eval "$(direnv hook bash)"` (add to `~/.bashrc` or `~/.zshrc`)
3. Login to Vault: `vault login`
4. Allow direnv in this directory: `direnv allow`

Now AWS and Route53 credentials will be automatically loaded when you enter this directory.

Without direnv, the script fetches credentials from Vault internally using the same paths.

## Provisioning Methods

The installer supports two provisioning methods:

### KKP-within-KKP (default)

Creates a KKP cluster inside an existing KKP user cluster using ClusterTemplates.

```bash
PROVISIONING_METHOD=kkp ./init.sh
```

### KubeOne AWS

Provisions a standalone AWS cluster using KubeOne and Terraform.

```bash
PROVISIONING_METHOD=kubeone ./init.sh
```

**Required for KubeOne:**
- `VAULT_AWS_PATH` - Vault path for AWS resource credentials (required env var)
- `VAULT_ROUTE53_PATH` - Vault path for Route53 DNS credentials (required env var)
- SSH public key at `SSH_PUBLIC_KEY_FILE`
- Route53 hosted zone for `KKP_HOST` domain

**KubeOne-specific Environment Variables:**

| Variable | Description | Default |
|----------|-------------|---------|
| PROVISIONING_METHOD | Provisioning method | kkp |
| VAULT_AWS_PATH | Vault path for AWS resource credentials | (required) |
| VAULT_ROUTE53_PATH | Vault path for Route53 DNS credentials | (required) |
| KUBEONE_CLUSTER_NAME | Cluster name | kkp-test |
| AWS_REGION | AWS region | eu-central-1 |
| AWS_VPC_ID | VPC ID | default |
| AWS_INSTANCE_TYPE | Control plane EC2 instance type | t3.medium |
| AWS_VOLUME_SIZE | Control plane EBS volume size (GB) | 50 |
| AWS_WORKER_INSTANCE_TYPE | Worker node EC2 instance type | r5.xlarge |
| AWS_WORKER_VOLUME_SIZE | Worker node EBS volume size (GB) | 200 |
| KUBEONE_K8S_VERSION | Kubernetes version | 1.28.0 |
| SSH_PUBLIC_KEY_FILE | SSH public key path | ~/.ssh/k8c_bs.pub |

### Deploying an Unreleased KKP Version

To deploy KKP from an unreleased commit (main, a release branch, or any commit),
set `kubermatic.source` in config.yaml. The installer clones
`kubermatic/kubermatic`, checks out the ref, and builds `kubermatic-installer` +
the matching Helm charts locally. Requires a local Go toolchain.

| Config | Result |
|--------|--------|
| neither | fully released KKP (default) |
| `source` only | unreleased installer + charts; images derived from the resolved commit |
| `imageOverride` only | released installer + charts; custom images |
| both | `imageOverride` wins for images; `source` drives installer + charts |

Image precedence: if `imageOverride` is set, it wins. Otherwise, when `source` is
set, images are derived as `quay.io/kubermatic/kubermatic-<edition>:<commit-sha>`.

Note: `spec.api` is never overridden, because the `kubermatic-api` binary ships in
the dashboard image (`quay.io/kubermatic/dashboard-ee`), not the kubermatic image.

Built artifacts are cached per commit under `kkp-files/<short-sha>/`. Delete old
directories manually to reclaim disk.

#### Source and Image Override fields

These live under `kubermatic:` in config.yaml (not env vars):

| Field | Description | Default |
|-------|-------------|---------|
| `source.ref` | branch, tag, or commit SHA to build from | (unset = released download) |
| `source.repo` | git repo to clone | `kubermatic/kubermatic` |
| `source.cloneDir` | local clone path (reused across runs) | `../kubermatic` |
| `imageOverride.repository` | custom container image repository | (unset = derive from source, else chart default) |
| `imageOverride.tag` | custom image tag | (unset = chart default `v<version>`) |

## TLS Certificate Management

When using KubeOne provisioning, TLS certificates are backed up to `kkp-files/tls-backup.yaml`. This prevents hitting Let's Encrypt rate limits when rebuilding clusters.

The backup is automatically:
- Created after first certificate issuance
- Restored on subsequent runs (before cert-manager runs)

## Setup

1. **Clone this repository:**
2. **Copy the template config and secrets files:**

```bash
cp config.template.yaml config.yaml   # host-specific config (gitignored)
cp secrets.template.env .k8c-creds.env
```

3. **Edit `config.yaml`** with your domain, version, and infrastructure settings.
4. **Edit `.k8c-creds.env`** with your credentials.

5. **Ensure you have a `seeds.yaml` file** in the current directory containing your Seed CR and Secret configuration.

## Environment Variables

| Variable               | Description                                        | Required                                 | Default        |
| ---------------------- | -------------------------------------------------- | ---------------------------------------- | -------------- |
| K8C_PROJECT_ID         | KKP project ID                                     | Yes (kkp method)                         | -              |
| K8C_CLUSTER_ID         | KKP cluster ID                                     | Yes (kkp method)                         | -              |
| K8C_HOST               | KKP API host                                       | Yes (kkp method)                         | -              |
| K8C_AUTH               | KKP API token                                      | Yes (kkp method)                         | -              |
| KKP_VERSION            | KKP version to install                             | Yes                                      | -              |
| KKP_HOST               | Domain for the new KKP instance                    | Yes                                      | -              |
| KKP_EMAIL              | Email for Let's Encrypt and admin user             | Yes                                      | -              |
| ADMIN_PASSWORD         | Password for the KKP admin user                    | Yes                                      | -              |
| PROVISIONING_METHOD    | Provisioning method (kkp or kubeone)               | No                                       | kkp            |
| K8C_CREDS              | Path to credentials file                           | No                                       | .k8c-creds.env |
| K8C_CLUSTER_TEMPLATEID | Template ID for creating a new cluster             | Only if SKIP_CLUSTER_CREATION is not set | -              |
| K8C_CLUSTER_REPLICAS   | Number of cluster replicas to create               | No                                       | 1              |
| SKIP_CLUSTER_CREATION  | Skip cluster creation step                         | No                                       | -              |
| WAIT_TIMEOUT_MINUTES   | Timeout for waiting for nodes to have external IPs | No                                       | 15             |

> You can see the templates in the [secrets.template.env](./secrets.template.env) file.

## How It Works

The `init.sh` script performs the following operations:

1. **Environment Validation**: Checks that all required credentials and environment variables are set
2. **Cluster Creation**: Optionally creates a new Kubernetes cluster from a specified template
3. **Cluster Readiness**: Waits for cluster nodes to be ready and have external IP addresses
4. **Kubeconfig Retrieval**: Fetches the kubeconfig file from the KKP API for the target cluster
5. **Configuration Preparation**: Prepares KKP configuration files and applies necessary customizations
6. **Installer Download**: Downloads the appropriate kubermatic-installer binary for your system
7. **KKP Deployment**: Deploys both KKP Master and Seed components to the target cluster
8. **DNS Configuration**: Provides guidance for manual DNS setup

## Usage Examples

### Basic Usage

Run the script with default settings:

```bash
./init.sh
```

### Using a Custom Credentials File

Specify a different credentials file:

```bash
K8C_CREDS=./my-custom-creds.env ./init.sh
```

### Skip Cluster Creation

If you already have a cluster and want to skip the creation step:

```bash
SKIP_CLUSTER_CREATION=true ./init.sh
```

> Ensure that your cluster information (like ID) is specified in the secret file.

### Create Multiple Cluster Replicas

Create a cluster with multiple worker nodes:

```bash
K8C_CLUSTER_REPLICAS=3 ./init.sh
```

## Directory Structure

- `init.sh`: Main initialization script
- `utils.sh`: Utility functions used by init.sh
- `config.template.yaml`: Template for config.yaml (host-specific, gitignored)
- `remote/cluster-issuer.yaml`: Template for Let's Encrypt cluster issuer
- `secrets.template.env`: Template for credentials file
- `kkp-files/`: Directory created by the script to store KKP configuration files

## Notes

- The script automatically generates a random secret key for Dex client authentication
- DNS records must be updated manually after installation to point to the new KKP instance
- The script modifies several configuration files to adapt them for the nested KKP deployment
- Let's Encrypt certificates are automatically requested and managed
- The installation process may take 10-15 minutes depending on cluster size and network conditions
