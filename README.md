Create a file for credentials and start installing kkp-ce within your k8s cluster.

Sample env file can be found in [secrets.template.env](./secrets.template.env) file.

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

Directory Structure
-------------------

-   `init.sh`: Main initialization script
-   `utils.sh`: Utility functions used by init.sh
-   `remote/cluster-issuer.yaml`: Template for Let's Encrypt cluster issuer
-   `secrets.template.env`: Template for credentials file
-   `kkp-files/`: Directory created by the script to store KKP configuration files

Notes
-----

-   The script will automatically generate a random secret key for Dex client authentication
-   DNS records must be updated manually after installation to point to the new KKP instance
-   The script modifies several configuration files to adapt them for the nested KKP deployment

