#!/bin/bash
#
# bootstrap-cluster.sh: First-time cluster bootstrap (see INSTALLATION.md).
# Idempotent — safe to re-run; each phase checks existing state first.
#
set -eu
had_warnings=false

# --- Step 0: Preflight -------------------------------------------------------
echo "🚀 Starting cluster bootstrap..."
./src/bash/preflight.sh
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

# --- Step 3: Cilium -----------------------------------------------------------
kubectl apply --server-side -f infrastructure/gateway-api-crds/standard-install.yaml
CILIUM_VERSION=$(grep 'version:' infrastructure/cilium/cilium-release.yaml | cut -d'"' -f2)
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

# --- Step 4: Bootstrap Flux ---------------------------------------------------
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

# --- Step 5: Reconcile vault kustomization, wait for vault-0 -----------------
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

# --- Step 6: In-cluster Vault init, unseal, GPG keyfile ----------------------
incluster_root_token=""
KEYFILE="$HOME/.vault-keys.gpg"

incluster_status_json=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null) || incluster_status_json=""
incluster_initialized=$(printf '%s' "$incluster_status_json" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('initialized', False))
except Exception:
    print('unknown')" 2>/dev/null || echo unknown)

if [ "$incluster_initialized" = "True" ]; then
    echo "✅ In-cluster Vault already initialized."
    rc=0
    kubectl exec -n vault vault-0 -- vault status > /dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "🔒 In-cluster Vault is sealed, unsealing via $KEYFILE..."
        echo "🔑 Enter GPG passphrase to decrypt unseal keys:"
        gpg --quiet --decrypt "$KEYFILE" | while IFS= read -r key; do
            [ -n "$key" ] || continue
            printf '%s\n' "$key" | kubectl exec -i -n vault vault-0 -- vault write -format=json sys/unseal key=- > /dev/null
        done
        echo "✅ In-cluster Vault unsealed."
    elif [ "$rc" -ne 0 ]; then
        echo "❌ ERROR: Cannot reach vault-0."
        kubectl exec -n vault vault-0 -- vault status
        exit 1
    fi
else
    echo "🔑 Initializing in-cluster Vault (SAVE THESE — shown once)..."
    incluster_init_json=$(kubectl exec -n vault vault-0 -- vault operator init -format=json)
    echo "$incluster_init_json" | python3 -m json.tool
    mapfile -t incluster_unseal_keys < <(echo "$incluster_init_json" | python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)['unseal_keys_b64'][:3]]")
    incluster_root_token=$(echo "$incluster_init_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])")

    for k in "${incluster_unseal_keys[@]}"; do
        printf '%s\n' "$k" | kubectl exec -i -n vault vault-0 -- vault write -format=json sys/unseal key=- > /dev/null
    done
    echo "✅ In-cluster Vault initialized and unsealed."

    echo "🔑 Enter a GPG passphrase to encrypt the unseal keyfile:"
    WORKDIR=/dev/shm/vault-setup
    mkdir -p "$WORKDIR"
    printf '%s\n' "${incluster_unseal_keys[@]}" > "$WORKDIR/keys.txt"
    gpg --batch --yes --cipher-algo AES256 --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 --symmetric "$WORKDIR/keys.txt"
    mv "$WORKDIR/keys.txt.gpg" "$KEYFILE"
    chmod 600 "$KEYFILE"
    rm -rf "$WORKDIR"
    mkdir -p ~/.gnupg
    if ! grep -q "^default-cache-ttl 0$" ~/.gnupg/gpg-agent.conf 2>/dev/null; then
        printf 'default-cache-ttl 0\nmax-cache-ttl 0\n' >> ~/.gnupg/gpg-agent.conf
    fi
    gpgconf --reload gpg-agent
    echo "✅ Wrote $KEYFILE."
fi
echo ""

# --- Step 7: vault Terraform (engines, policies) -----------------------------
just vault-pf
if [ -z "$incluster_root_token" ]; then
    read -rs -p "In-cluster Vault root token (this run resumed after init already ran — paste it): " incluster_root_token; echo
fi
read -rs -p "State encryption passphrase (used for terraform/vault's state file): " TF_VAR_state_encryption_passphrase; echo
export TF_VAR_state_encryption_passphrase
export VAULT_ADDR="https://127.0.0.1:8210"
export VAULT_CACERT="$HOME/.vault-certs/vault-internal-ca.crt"
export VAULT_TOKEN="$incluster_root_token"
SECRETS_ENV_FILE="$HOME/.config/data_science_cluster/vault-secrets.env"
if [ -f "$SECRETS_ENV_FILE" ] && [ "${ROTATE_VAULT_SECRETS:-false}" != "true" ]; then
    echo "✅ Reusing persisted app secrets from $SECRETS_ENV_FILE (set ROTATE_VAULT_SECRETS=true to rotate)."
    # shellcheck disable=SC1090
    . "$SECRETS_ENV_FILE"
else
    if [ -f "$SECRETS_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$SECRETS_ENV_FILE"
        SECRETS_WO_VERSION=$((SECRETS_WO_VERSION + 1))
        echo "🔄 ROTATE_VAULT_SECRETS=true — generating new app secrets (version ${SECRETS_WO_VERSION})..."
    else
        SECRETS_WO_VERSION=1
        echo "🔑 Generating app secrets (first run)..."
    fi
    TF_VAR_postgres_superuser_password=$(openssl rand -base64 24)
    TF_VAR_s3_access_key=$(openssl rand -hex 10)
    TF_VAR_s3_secret_key=$(openssl rand -hex 20)
    mkdir -p "$(dirname "$SECRETS_ENV_FILE")"
    (
        umask 077
        {
            printf 'TF_VAR_postgres_superuser_password=%q\n' "$TF_VAR_postgres_superuser_password"
            printf 'TF_VAR_s3_access_key=%q\n' "$TF_VAR_s3_access_key"
            printf 'TF_VAR_s3_secret_key=%q\n' "$TF_VAR_s3_secret_key"
            printf 'SECRETS_WO_VERSION=%s\n' "$SECRETS_WO_VERSION"
        } > "$SECRETS_ENV_FILE"
    )
fi
export TF_VAR_postgres_superuser_password TF_VAR_s3_access_key TF_VAR_s3_secret_key
export TF_VAR_secrets_wo_version="$SECRETS_WO_VERSION"
cd terraform/vault
tofu init
tofu apply -auto-approve
cd ../..
echo "== Verify Vault Configuration =="
printf '%s\n' "$incluster_root_token" | kubectl exec -i -n vault vault-0 -- vault login -no-print -
kubectl exec -n vault vault-0 -- vault kv get secret/postgis
kubectl exec -n vault vault-0 -- vault kv get secret/seaweedfs
kubectl exec -n vault vault-0 -- vault read pki_int/roles/internal-server
kubectl exec -n vault vault-0 -- vault read auth/kubernetes/role/cert-manager-pki-role

unset VAULT_ADDR VAULT_CACERT VAULT_TOKEN TF_VAR_state_encryption_passphrase TF_VAR_postgres_superuser_password TF_VAR_s3_access_key TF_VAR_s3_secret_key TF_VAR_secrets_wo_version
echo "✅ terraform/vault applied and verified."
echo ""

# --- Step 8: Flux kustomization rollout + verification ----------------------
echo "🚀 Reconciling remaining Flux kustomizations..."
flux reconcile kustomization flux-system --with-source || { echo "⚠️  flux-system reconcile reported an issue, continuing."; had_warnings=true; }
flux reconcile kustomization gateway || { echo "⚠️  gateway not yet converged (expected until vault-pki-issuer settles); it will retry automatically."; had_warnings=true; }
flux reconcile kustomization databases || { echo "⚠️  databases not yet converged (expected until vault-pki-issuer settles); it will retry automatically."; had_warnings=true; }
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

# --- Step 9: Summary ---------------------------------------------------------
echo "Generated app secrets (postgres/S3) are stored in Vault — retrieve anytime with:"
echo "  kubectl exec -n vault vault-0 -- vault kv get secret/postgis"
echo "  kubectl exec -n vault vault-0 -- vault kv get secret/seaweedfs"
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
