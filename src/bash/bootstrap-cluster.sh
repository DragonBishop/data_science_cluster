#!/bin/bash
#
# bootstrap-cluster.sh: First-time cluster bootstrap (see INSTALLATION.md).
# Idempotent — safe to re-run; each phase checks existing state first.
#
set -eu
had_warnings=false

# --- Step 0: Preflight -------------------------------------------------------
echo "🚀 Starting cluster bootstrap..."
for bin in vault tofu helm flux gh gpg openssl python3 just; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "❌ ERROR: '$bin' not found. See INSTALLATION.md Requirements."
        exit 1
    fi
done
if ! gh auth status >/dev/null 2>&1; then
    echo "❌ ERROR: GitHub CLI not authenticated. Run: gh auth login"
    exit 1
fi
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"
transit_initialized=$(vault status -format=json 2>/dev/null | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('initialized', False))
except Exception:
    print('unknown')" 2>/dev/null || echo unknown)
unset VAULT_ADDR VAULT_CACERT
if [ "$transit_initialized" != "True" ]; then
    echo "❌ ERROR: Host Transit Vault not found or not initialized. Run: ./src/bash/bootstrap-transit.sh"
    exit 1
fi
echo "✅ Preflight checks passed."
echo ""

# --- Step 1: Name the cluster (optional) --------------------------------------
CLUSTER_ENV_FILE="$HOME/.config/data_science_cluster/cluster.env"
if [ -f "$CLUSTER_ENV_FILE" ]; then
    echo "✅ Cluster name already set in $CLUSTER_ENV_FILE, skipping."
else
    read -r -p "Name this cluster (used for its kubeconfig context), or press Enter for 'default': " CLUSTER_NAME_INPUT
    if [ -n "$CLUSTER_NAME_INPUT" ]; then
        mkdir -p "$(dirname "$CLUSTER_ENV_FILE")"
        printf 'CLUSTER_NAME=%s\n' "$CLUSTER_NAME_INPUT" > "$CLUSTER_ENV_FILE"
        echo "✅ Wrote $CLUSTER_ENV_FILE (CLUSTER_NAME=$CLUSTER_NAME_INPUT)"
    else
        echo "✅ Keeping 'default'."
    fi
fi
echo ""

# --- Step 2: k3s config + install --------------------------------------------
mkdir -p ~/.kube
sudo mkdir -p /etc/rancher/k3s
printf 'write-kubeconfig-mode: "644"\nwrite-kubeconfig: %s/.kube/config\ndisable:\n  - traefik\n  - servicelb\ndisable-kube-proxy: true\ndisable-network-policy: true\nflannel-backend: none\nsecrets-encryption: true\n' "$HOME" | sudo tee /etc/rancher/k3s/config.yaml > /dev/null

export KUBECONFIG="$HOME/.kube/config"

if command -v k3s >/dev/null 2>&1; then
    echo "✅ k3s already installed, skipping installer."
else
    echo "🚀 Installing k3s..."
    curl -sfL https://get.k3s.io | sh -
    retries=0
    until kubectl get nodes &> /dev/null; do
        sleep 5
        retries=$((retries+1))
        if [ $retries -ge 12 ]; then
            echo "❌ ERROR: API server failed to respond after 60 seconds."
            exit 1
        fi
    done
fi
echo "✅ k3s node present (NotReady is expected until Cilium is installed)."
echo ""

# --- Step 3: cluster-config Terraform (network values) -----------------------
cd terraform/cluster-config
if [ -f terraform.tfvars ]; then
    echo "✅ terraform.tfvars already present, applying as-is."
else
    DETECTED_HOST_IP=$(hostname -I | awk '{print $1}')
    printf 'gateway_ip     = "192.0.2.240"\ncoredns_lan_ip = "192.0.2.242"\nhost_ip        = "%s"\ncilium_version = "1.20.1"\n' "$DETECTED_HOST_IP" > terraform.tfvars
    echo "📝 Wrote terraform.tfvars with defaults (host_ip=${DETECTED_HOST_IP}). Edit this file later if your LAN needs different values, then re-run 'tofu apply' here."
fi
tofu init
tofu apply -auto-approve
cd ../..
echo "✅ cluster-config applied."
echo ""

# --- Step 4: Cilium -----------------------------------------------------------
kubectl apply --server-side -f infrastructure/gateway-api-crds/standard-install.yaml
CILIUM_VERSION=$(grep 'version:' infrastructure/cilium/cilium-release.yaml | tr -d ' "' | cut -d: -f2)
echo "🚀 Installing Cilium ${CILIUM_VERSION}..."
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium --version "$CILIUM_VERSION" \
    --namespace kube-system --create-namespace \
    -f infrastructure/cilium/cilium-values.yaml \
    --atomic --timeout 5m
retries=0
until kubectl get nodes | grep -q " Ready"; do
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 60 ]; then
        echo "❌ ERROR: Node did not reach Ready within 5 minutes of installing Cilium."
        exit 1
    fi
done
echo "✅ Cilium ${CILIUM_VERSION} installed, node Ready."
echo ""

# --- Step 5: Bootstrap Flux ---------------------------------------------------
if flux get kustomizations >/dev/null 2>&1; then
    echo "✅ Flux already bootstrapped, skipping."
else
    echo "🚀 Bootstrapping Flux..."
    export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"
    flux bootstrap github \
        --owner=DragonBishop \
        --repository=data_science_cluster \
        --branch=main \
        --path=clusters/local \
        --personal
    unset GITHUB_TOKEN
fi
echo "✅ Flux reconciling."
echo ""

# --- Step 6: Reconcile vault kustomization, wait for vault-0 -----------------
flux reconcile kustomization vault
retries=0
until kubectl get pods -n vault vault-0 2>/dev/null | grep -q "Running"; do
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 36 ]; then
        echo "⚠️  vault-0 not Running after 3 minutes. Continuing — check 'kubectl get pods -n vault -w'."
        had_warnings=true
        break
    fi
done
echo ""

# --- Step 7: vault-transit-bootstrap Terraform --------------------------------
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"

rc=0
vault status > /dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
    echo "🔒 Host Transit Vault is sealed, unsealing via ~/.vault-keys.gpg..."
    echo "🔑 Enter GPG passphrase to decrypt unseal keys:"
    gpg --quiet --decrypt "$HOME/.vault-keys.gpg" | while IFS= read -r key; do
        [ -n "$key" ] || continue
        printf '%s\n' "$key" | vault write sys/unseal key=- > /dev/null
    done
elif [ "$rc" -ne 0 ]; then
    echo "❌ ERROR: Cannot reach the host Transit Vault at $VAULT_ADDR."
    vault status
    exit 1
fi
export VAULT_TOKEN
VAULT_TOKEN=$(cat ~/.vault-token)
read -rs -p "State encryption passphrase (used for both Terraform state files): " TF_VAR_state_encryption_passphrase; echo
export TF_VAR_state_encryption_passphrase
cd terraform/vault-transit-bootstrap
tofu init
tofu apply -auto-approve
cd ../..

unset VAULT_ADDR VAULT_CACERT VAULT_TOKEN
echo "✅ terraform/vault-transit-bootstrap applied."
echo ""

# --- Step 8: In-cluster Vault init --------------------------------------------
incluster_root_token=""

incluster_status_json=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null) || incluster_status_json=""
incluster_initialized=$(printf '%s' "$incluster_status_json" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('initialized', False))
except Exception:
    print('unknown')" 2>/dev/null || echo unknown)

if [ "$incluster_initialized" = "True" ]; then
    echo "✅ In-cluster Vault already initialized."
else
    echo "🔑 Initializing in-cluster Vault (SAVE THESE — shown once)..."
    incluster_init_json=$(kubectl exec -n vault vault-0 -- vault operator init -format=json)
    echo "$incluster_init_json" | python3 -m json.tool
    incluster_root_token=$(echo "$incluster_init_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])")
    echo "✅ In-cluster Vault initialized."
fi
echo ""

# --- Step 9: vault Terraform (engines, policies) -----------------------------
just vault-pf
if [ -z "$incluster_root_token" ]; then
    read -rs -p "In-cluster Vault root token (this run resumed after init already ran — paste it): " incluster_root_token; echo
fi
export VAULT_ADDR="https://127.0.0.1:8210"
export VAULT_CACERT="$HOME/.vault-certs/vault-internal-ca.crt"
export VAULT_TOKEN="$incluster_root_token"
export TF_VAR_postgres_superuser_password
TF_VAR_postgres_superuser_password=$(openssl rand -base64 24)
export TF_VAR_s3_access_key
TF_VAR_s3_access_key=$(openssl rand -hex 10)
export TF_VAR_s3_secret_key
TF_VAR_s3_secret_key=$(openssl rand -hex 20)
cd terraform/vault
tofu init
tofu apply -auto-approve
cd ../..
echo "== Verify Vault Configuration =="
vault kv get secret/postgis
vault kv get secret/seaweedfs
vault read pki_int/roles/internal-server
vault read auth/kubernetes/role/cert-manager-pki-role

unset VAULT_ADDR VAULT_CACERT VAULT_TOKEN TF_VAR_state_encryption_passphrase TF_VAR_postgres_superuser_password TF_VAR_s3_access_key TF_VAR_s3_secret_key
echo "✅ terraform/vault applied and verified."
echo ""

# --- Step 10: Flux kustomization rollout + verification ----------------------
echo "🚀 Reconciling remaining Flux kustomizations..."
flux reconcile kustomization flux-system --with-source || { echo "⚠️  flux-system reconcile reported an issue, continuing."; had_warnings=true; }
flux get kustomizations || had_warnings=true

kubectl rollout restart deployment coredns -n kube-system || true
kubectl wait --for=condition=Available --timeout=120s -n cert-manager deployment --all || { echo "⚠️  cert-manager deployments not all Available yet."; had_warnings=true; }
kubectl get clusterissuer vault-pki-issuer || had_warnings=true
kubectl rollout status deployment -n cnpg-system plugin-barman-cloud --timeout=60s || { echo "⚠️  barman-cloud rollout not finished yet."; had_warnings=true; }

if ! helm get values cilium -n kube-system 2>/dev/null | grep -q hubble; then
    echo "⏳ Hubble config not yet reflected, reconciling cilium HelmRelease..."
    flux reconcile helmrelease cilium -n kube-system --timeout 5m || { echo "⚠️  Could not reconcile Hubble config."; had_warnings=true; }
fi
echo ""

# --- Step 11: Summary ---------------------------------------------------------
echo "Generated app secrets (postgres/S3) are stored in Vault — retrieve anytime with:"
echo "  vault kv get secret/postgis"
echo "  vault kv get secret/seaweedfs"
echo ""
echo "If migrating existing data, see INSTALLATION.md Requirements for the pg_restore command."
echo ""

if [ "$had_warnings" = true ]; then
    echo "⚠️  Cluster bootstrap complete, review warnings above."
    echo "   Run 'just status' or see INSTALLATION.md Verification for full health checks."
    exit 1
else
    echo "✅ Cluster bootstrap complete."
    echo "   Run 'just status' or see INSTALLATION.md Verification to confirm everything is healthy."
fi
