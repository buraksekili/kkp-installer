# KKP-within-KKP Deployment Script

Create a KKP master/shared cluster within an existing user cluster deployed in KKP!

You'll also need:

- Access to a KKP instance with permissions to create clusters
- A valid KKP API token
- A cluster template configured in your KKP project

> Old branch can be found https://github.com/buraksekili/kkp-installer/tree/old

## Setup

1. **Clone this repository:**
2. **Copy the template secrets file:**

```bash
cp secrets.template.env .k8c-creds.env
```

3. **Edit the credentials file with your values:**

4. **Ensure you have a `seeds.yaml` file** in the current directory containing your Seed CR and Secret configuration.

## Environment Variables

| Variable               | Description                                        | Required                                 | Default        |
| ---------------------- | -------------------------------------------------- | ---------------------------------------- | -------------- |
| K8C_PROJECT_ID         | KKP project ID                                     | Yes                                      | -              |
| K8C_CLUSTER_ID         | KKP cluster ID                                     | Yes                                      | -              |
| K8C_HOST               | KKP API host                                       | Yes                                      | -              |
| K8C_AUTH               | KKP API token                                      | Yes                                      | -              |
| KKP_VERSION            | KKP version to install                             | Yes                                      | -              |
| KKP_HOST               | Domain for the new KKP instance                    | Yes                                      | -              |
| KKP_EMAIL              | Email for Let's Encrypt and admin user             | Yes                                      | -              |
| ADMIN_PASSWORD         | Password for the KKP admin user                    | Yes                                      | -              |
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
- `remote/cluster-issuer.yaml`: Template for Let's Encrypt cluster issuer
- `secrets.template.env`: Template for credentials file
- `kkp-files/`: Directory created by the script to store KKP configuration files

## Troubleshooting

### Cluster Creation Fails

**Problem**: The script fails to create a new cluster.

**Solutions**:

- Verify your KKP credentials are correct and have sufficient permissions
- Ensure the template ID exists in your project: `kubectl get clustertemplates`
- Check that your project has available quota for new clusters
- Review the KKP API logs for detailed error messages

### Kubeconfig Retrieval Fails

**Problem**: Unable to fetch kubeconfig from KKP API.

**Solutions**:

- Verify your cluster ID is correct and the cluster exists
- Ensure your KKP token has sufficient permissions
- Check that the cluster is in a healthy state
- Verify the KKP API endpoint is accessible

## Post-Installation

### DNS Configuration

After successful installation, you'll need to manually configure DNS:

1. Find the external IP of your cluster's load balancer:

```bash
kubectl get services -n nginx-ingress-controller
```

2. Create DNS A records pointing your KKP_HOST domain to this IP address.

## Notes

- The script automatically generates a random secret key for Dex client authentication
- DNS records must be updated manually after installation to point to the new KKP instance
- The script modifies several configuration files to adapt them for the nested KKP deployment
- Let's Encrypt certificates are automatically requested and managed
- The installation process may take 10-15 minutes depending on cluster size and network conditions
