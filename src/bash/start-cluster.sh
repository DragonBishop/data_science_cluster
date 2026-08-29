#!/bin/bash
#
# start-cluster.sh: Starts k3s, unseals the in-cluster Vault, and resumes CNPG cluster.
#
set -eu
had_warnings=false

# --- Step 1: Prevent duplicate execution ----------------------------------
# Exit if systemd k3s service is already active
if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "⚠️  systemd's k3s.service is already active. Refusing to start a second instance."
    echo "   To adopt a script-managed lifecycle, run: sudo systemctl disable --now k3s"
    exit 1
fi

KUBECONFIG_DEST="$HOME/.kube/config"
mkdir -p "$(dirname "$KUBECONFIG_DEST")"
export KUBECONFIG="$KUBECONFIG_DEST"

# --- Step 2: Launch k3s Server ---------------------------------------------
# Start k3s using configuration from /etc/rancher/k3s/config.yaml
echo "🚀 Starting k3s cluster..."
K3S_PID=$(sudo bash -c 'nohup k3s server \
  > /var/log/k3s.log 2>&1 &
  echo $!')

# --- Step 3: Wait for API Server -------------------------------------------
# Poll until API server responds
echo "⏳ Waiting for Kubernetes API to become available (pid $K3S_PID)..."
retries=0
until kubectl get nodes &> /dev/null; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died during startup."
        echo "Check logs: sudo tail -n 50 /var/log/k3s.log"
        exit 1
    fi
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 12 ]; then
        echo "❌ ERROR: API server failed to respond after 60 seconds."
        exit 1
    fi
    echo "   ...still waiting for API... ($((retries * 5))s elapsed)"
done
echo "✅ Kubernetes API is up."

# --- Step 4: Wait for Node Readiness ---------------------------------------
# Poll until node reports Ready status
retries=0
until kubectl get nodes | grep -q " Ready"; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died while waiting for node Ready."
        exit 1
    fi
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 60 ]; then
        echo "❌ ERROR: Node did not reach Ready within 5 minutes."
        echo "💡 TROUBLESHOOTING: A node with no CNI stays NotReady indefinitely."
        echo "   1. Is Cilium installed?  cilium status --wait"
        echo "   2. On a first-time build, install it now:"
        echo "      helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \\"
        echo "        --version <chart-version> --namespace kube-system -f infrastructure/cilium/cilium-values.yaml"
        exit 1
    fi
    echo "   ...still waiting for node... ($((retries * 5))s elapsed)"
done
echo "✅ Node is Ready."
echo ""

# --- Step 5: Rename kubeconfig identity -------------------------------------
# k3s hardcodes cluster/context/user as "default" every time it (re)writes
# KUBECONFIG_DEST via config.yaml's write-kubeconfig setting, so this runs on
# every start to keep the chosen name in place. Name comes from
# ~/.config/data_science_cluster/cluster.env (set via `just cluster-name`);
# falls back to "default" if that hasn't been run.
CLUSTER_ENV_FILE="$HOME/.config/data_science_cluster/cluster.env"
CLUSTER_NAME="default"
[ -f "$CLUSTER_ENV_FILE" ] && . "$CLUSTER_ENV_FILE"
KUBECONFIG_ALIAS="${CLUSTER_NAME:-default}"
python3 - "$KUBECONFIG_DEST" "default" "$KUBECONFIG_ALIAS" <<'EOF'
import sys
import yaml

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    cfg = yaml.safe_load(f)

changed = False
for section in ("clusters", "users"):
    for item in cfg.get(section, []):
        if item.get("name") == old:
            item["name"] = new
            changed = True
for ctx in cfg.get("contexts", []):
    if ctx.get("name") == old:
        ctx["name"] = new
        changed = True
    c = ctx.get("context", {})
    if c.get("cluster") == old:
        c["cluster"] = new
        changed = True
    if c.get("user") == old:
        c["user"] = new
        changed = True
if cfg.get("current-context") == old:
    cfg["current-context"] = new
    changed = True

if changed:
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
EOF

# --- Step 6: Unseal in-cluster Vault ------------------------------------
# Check seal state and unseal via GPG keyfile if necessary

# Returns seal status: unsealed, sealed, or unreachable
incluster_seal_state() {
    local rc=0
    kubectl exec -n vault vault-0 -- vault status -format=json > /dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo unsealed
    elif [ "$rc" -eq 2 ]; then
        echo sealed
    else
        echo unreachable
    fi
}

echo "⏳ Checking in-cluster Vault seal status..."
seal_state=$(incluster_seal_state)
if [ "$seal_state" = unsealed ]; then
    echo "✅ In-cluster Vault already unsealed."
elif [ "$seal_state" = unreachable ]; then
    echo "❌ ERROR: Cannot reach vault-0. Continuing..."
    kubectl exec -n vault vault-0 -- vault status 2>&1 | sed 's/^/   /'
    echo "💡 TROUBLESHOOTING: Is the pod up?  kubectl get pods -n vault"
    had_warnings=true
else
    echo "🔒 In-cluster Vault is sealed."
    KEYFILE="$HOME/.vault-keys.gpg"
    if [ ! -f "$KEYFILE" ]; then
        echo "❌ ERROR: $KEYFILE not found. Cannot unseal Vault."
        echo "💡 TROUBLESHOOTING: Did the GPG keyfile get created during 'just bootstrap' (INSTALLATION.md)?. Continuing..."
        had_warnings=true
    else
        # Decrypts keys and writes to Vault unseal endpoint via stdin
        decrypt_and_unseal() {
            gpg --quiet --decrypt "$KEYFILE" | while IFS= read -r key; do
                [ -n "$key" ] || continue
                if ! err=$(printf '%s\n' "$key" | kubectl exec -i -n vault vault-0 -- vault write -format=json sys/unseal key=- 2>&1 >/dev/null); then
                    echo "   ⚠️ Key rejected by Vault: $err"
                fi
            done
            return "${PIPESTATUS[0]}"
        }

        echo "🔑 Enter GPG passphrase to decrypt unseal keys:"
        if ! decrypt_and_unseal; then
            echo "❌ ERROR: GPG decryption failed or was cancelled. Vault remains sealed. Continuing..."
            had_warnings=true
        fi

        seal_state=$(incluster_seal_state)
        if [ "$seal_state" = unsealed ]; then
            echo "✅ In-cluster Vault unsealed successfully."
        elif [ "$seal_state" = sealed ]; then
            echo "❌ ERROR: Vault still sealed after applying keys from $KEYFILE. Continuing..."
            had_warnings=true
        else
            echo "❌ ERROR: Vault unreachable after applying keys from $KEYFILE. Continuing..."
            kubectl exec -n vault vault-0 -- vault status 2>&1 | sed 's/^/   /'
            had_warnings=true
        fi
    fi
fi
echo ""

# --- Step 7: Un-hibernate PostGIS and resume backups ------------------------
# Resume CNPG cluster and scheduled backups
if kubectl get cluster postgis-cluster -n databases &> /dev/null; then
  hib=$(kubectl get cluster postgis-cluster -n databases \
    -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}' 2>/dev/null) || hib=""

  if [ "$hib" == "on" ]; then
    echo "⏳ Rehydrating postgis-cluster from hibernation..."

    retries=0
    success=false
    until [ $retries -ge 6 ]; do
        if kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off 2>/dev/null; then
            success=true
            break
        fi
        sleep 5
        retries=$((retries+1))
        echo "   ...still retrying re-hydration of database... ($((retries * 5))s elapsed)"
    done
    if [ "$success" = true ]; then
        echo "✅ postgis-cluster un-hibernated successfully."
    else
        echo "⚠️  Could not un-hibernate postgis-cluster (webhook timed out). Startup continues."
        echo "💡 TROUBLESHOOTING: Once the cluster settles, run manually:"
        echo "   kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off"
        had_warnings=true
    fi
  fi
fi

sbs=$(kubectl get scheduledbackup -n databases -o name 2>/dev/null) || sbs=""
if [ -n "$sbs" ]; then
    echo "▶️  Resuming scheduled backups..."
    for sb in $sbs; do
        kubectl patch "$sb" -n databases --type merge -p '{"spec":{"suspend":false}}' 2>/dev/null || true
    done
fi
echo ""

if [ "$had_warnings" = true ]; then
    echo "⚠️  Cluster startup sequence complete, review warnings above."
    echo "   Check Headlamp, 'flux get kustomizations', or 'kubectl cnpg status postgis-cluster -n databases' for full health."
    exit 1
else
    echo "✅ Cluster startup sequence complete."
    echo "   Check Headlamp or 'flux get kustomizations' as everything else settles."
fi
