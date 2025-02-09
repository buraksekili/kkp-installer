Create a file for credentials and start installing kkp-ce within your k8s cluster.

Sample env file can be found in [secrets.template.env](./secrets.template.env) file.

```
K8C_PROJECT_ID: KKP Project ID
K8C_CLUSTER_ID: KKP Cluster ID
K8C_HOST: host name of kkp seed, such as my.k8c.com
K8C_AUTH: service account access token to fetch user cluster's kubeconfig

KKP_VERSION: kkp version, in `x.y.z` format e.g, "2.26.4"
KKP_HOST: host name for the new kkp installation, "<my.dns.hostname>"
KKP_EMAIL: "<my-email@example.com>"
AWS_IP: User cluster's node IP address: "<AWS_NODE_IP>"
```

```bash
export K8C_CREDS="my-creds.env"; ./init.sh
```
