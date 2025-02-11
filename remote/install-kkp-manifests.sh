#!/usr/bin/env bash

if [ -z "${KKP_VERSION:-}" ]; then
  echo "using default KKP_VERSION"
  export KKP_VERSION=2.26.4
fi

echo "==> Installing KKP $KKP_VERSION"
echo "==> HOST: $KKP_HOST"
echo "==> EMAIL: $KKP_EMAIL"

set -e

sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod a+x /usr/local/bin/yq
yq --version

KKP_DIR="$HOME/kkp"
mkdir -p $KKP_DIR
mkdir -p $KKP_DIR/values
mkdir -p $KKP_DIR/kubermatic-ce-"$KKP_VERSION"
mkdir -p ~/.kube

curl -L https://github.com/kubermatic/kubermatic/releases/download/v"$KKP_VERSION"/kubermatic-ce-v"$KKP_VERSION"-linux-amd64.tar.gz \
  --output $KKP_DIR/kubermatic-ce-"$KKP_VERSION".tar.gz
tar -xvf $KKP_DIR/kubermatic-ce-"$KKP_VERSION".tar.gz -C $KKP_DIR/kubermatic-ce-"$KKP_VERSION"
chmod +x $KKP_DIR/kubermatic-ce-"$KKP_VERSION"/kubermatic-installer
rm $KKP_DIR/kubermatic-ce-"$KKP_VERSION".tar.gz

KUBERMATIC_BINARY="$KKP_DIR/kubermatic-ce-$KKP_VERSION/kubermatic-installer"
if [ -f "$KUBERMATIC_BINARY" ]; then
  sudo cp "$KUBERMATIC_BINARY" /usr/local/bin/
  kubermatic-installer --version
  echo "kubermatic-installer has been installed to /usr/local/bin"
else
  echo "Warning: kubermatic-installer binary not found at $KUBERMATIC_BINARY"
  exit 1
fi

cp -r $KKP_DIR/kubermatic-ce-"$KKP_VERSION"/charts $KKP_DIR/charts
cp $KKP_DIR/kubermatic-ce-"$KKP_VERSION"/examples/kubermatic.example.yaml $KKP_DIR/values/kubermatic.yaml
cp $KKP_DIR/kubermatic-ce-"$KKP_VERSION"/examples/values.example.yaml $KKP_DIR/values/values.yaml

randomKey=$(cat /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)
anotherRandomKey=$(cat /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)

sed -i 's/kkp.example.com/'"$KKP_HOST"'/g' $KKP_DIR/values/kubermatic.yaml
sed -i 's/letsencrypt-staging/letsencrypt-prod/g' $KKP_DIR/values/kubermatic.yaml
sed -i 's/<a-random-key>/'$randomKey'/g' $KKP_DIR/values/kubermatic.yaml
sed -i 's/<another-random-key>/'$anotherRandomKey'/g' $KKP_DIR/values/kubermatic.yaml
sed -i 's/skipTokenIssuerTLSVerify: true/skipTokenIssuerTLSVerify: false/g' $KKP_DIR/values/kubermatic.yaml

sed -i 's/kkp.example.com/'"$KKP_HOST"'/g' $KKP_DIR/values/values.yaml
sed -i 's/kubermatic@example.com/'"$KKP_EMAIL"'/g' $KKP_DIR/values/values.yaml
sed -i 's/uuid: \"\"/uuid: \"'$(uuidgen -r)'\"/g' $KKP_DIR/values/values.yaml
sed -i 's/letsencrypt-staging/letsencrypt-prod/g' $KKP_DIR/values/values.yaml
sed -i 's/storeSize: "500Gi"/storeSize: "10Gi"/g' $KKP_DIR/values/values.yaml
sed -i 's/<a-random-key>/'$randomKey'/g' $KKP_DIR/values/values.yaml

BASHRC_PATH="$HOME/.bashrc"
echo "alias k=kubectl" >>"$BASHRC_PATH"
echo "export KUBECONFIG=$HOME/.kube/config" >>"$BASHRC_PATH"
echo 'source <(kubectl completion bash)' >>"$BASHRC_PATH"
echo 'complete -o default -F __start_kubectl k' >>"$BASHRC_PATH"
source "$BASHRC_PATH"

mv ./cluster-issuer.yaml "$KKP_DIR"
sed -i 's/<your_email>/'$KKP_EMAIL'/g' $KKP_DIR/cluster-issuer.yaml

KUBECONFIG=$HOME/.kube/config
mv ./kubeconfig-usercluster $KUBECONFIG

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "==> starting to install KKP"
kubermatic-installer deploy \
  --config "$KKP_DIR"/values/kubermatic.yaml \
  --helm-values "$KKP_DIR"/values/values.yaml \
  --kubeconfig "$KUBECONFIG" \
  --charts-directory "$KKP_DIR/charts" \
  --storageclass aws

kubectl apply -f $KKP_DIR/cluster-issuer.yaml

echo "==> KKP master should be installed, wait for pods in kubermatic namespace to be ready"
echo ""
echo "==> ***************************"
echo "==> Installing KKP Seed cluster"
echo ""

kubermatic-installer convert-kubeconfig "$KUBECONFIG" > "$HOME"/kubeconfig-seed
encodedSeedKubeconfig=$(base64 -w0 kubeconfig-seed)
mv $HOME/seed.yaml $KKP_DIR/seed.yaml
sed -i 's/<base64 encoded kubeconfig>/'$encodedSeedKubeconfig'/g' $KKP_DIR/seed.yaml
kubectl apply -f $KKP_DIR/seed.yaml


ACCESS_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
SECRET_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

yq eval -i '.minio.credentials.accessKey = "'$ACCESS_KEY'" | .minio.credentials.secretKey = "'$SECRET_KEY'"' $KKP_DIR/values/values.yaml

echo "==> Installing KKP Seed cluster dependencies"
kubermatic-installer deploy kubermatic-seed \
  --kubeconfig "$KUBECONFIG" \
  --charts-directory "$KKP_DIR/charts" \
  --config "$KKP_DIR"/values/kubermatic.yaml \
  --helm-values "$KKP_DIR"/values/values.yaml \
  --verbose

mv "$HOME"/preset.yaml $KKP_DIR
kubectl apply -f "$KKP_DIR"/preset.yaml
echo "==> KKP seed cluster must be added. Ensure that DNS settings are up-to-date in the AWS"

sed -i 's/<host>/burak.sekili@kubermatic.com/g' seed-mla.values.yaml
kubermatic-installer deploy seed-mla \
  --kubeconfig "$KUBECONFIG" \
  --charts-directory "$KKP_DIR/charts" \
  --config "$KKP_DIR"/values/kubermatic.yaml \
  --helm-values seed-mla.yaml
  --verbose

mv seed-mla.values.yaml $KKP_DIR

grafanaRandomKeyForDex=$(cat /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)
yq eval -i '.dex.clients += {"id": "grafana", "name": "Grafana", "secret": "'$grafanaRandomKeyForDex'", "RedirectURIs": ["https://grafana." + env(KKP_HOST)]}' $KKP_DIR/values/values.yaml

iapRandomKey=$(cat /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c32)
cat << EOF >> $KKP_DIR/values/values.yaml
iap:
  oidc_issuer_url: https://$KKP_HOST/dex
  deployments:
    grafana:
      name: grafana
      client_id: grafana
      client_secret: "$grafanaRandomKeyForDex"
      encryption_key: "$iapRandomKey" # created via `cat /dev/urandom | tr -dc A-Za-z0-9 | head -c32`
      config:
        scope: "groups openid email"
        email_domains:
          - "*"
        skip_auth_regex:
          - "/api/health"
        pass_user_headers: true
      upstream_service: grafana.monitoring.svc.cluster.local
      upstream_port: 3000
      ingress:
        host: "grafana.$KKP_HOST"
        annotations: {}
EOF

echo "=======> upgrading oauth"
helm --namespace oauth upgrade --install --wait --atomic --values $KKP_DIR/values/values.yaml oauth $KKP_DIR/charts/oauth
echo "=======> upgrading/installing IAP"
helm --namespace iap upgrade --install --create-namespace --wait --atomic --values $KKP_DIR/values/values.yaml iap $KKP_DIR/charts/iap 
