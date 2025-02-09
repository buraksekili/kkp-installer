#!/usr/bin/env bash

if [ -z "${KKP_VERSION:-}" ]; then
  echo "using default KKP_VERSION"
  export KKP_VERSION=2.26.4
fi

echo "==> Installing KKP $KKP_VERSION"
echo "==> HOST: $KKP_HOST"
echo "==> EMAIL: $KKP_EMAIL"

set -e

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

echo "==> KKP should be installed, wait for pods in kubermatic namespace to be ready"
