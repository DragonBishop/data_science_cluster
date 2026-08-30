#!/bin/bash
#
# start-cluster.sh: Starts k3s, unseals the in-cluster Vault, and resumes CNPG cluster.
#
set -eu
had_warnings=false

# --- Step 1: Start k3s and wait for it to become ready ---------------------
KUBECONFIG_DEST="$HOME/.kube/config"
mkdir -p "$(dirname "$KUBECONFIG_DEST")"
export KUBECONFIG="$KUBECONFIG_DEST"

K3S_PID=""
if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "ℹ️  k3s is already running via systemd."
elif systemctl cat k3s.service &>/dev/null; then
    echo "🚀 Starting k3s via systemd..."
    sudo systemctl start k3s
else
    echo "🚀 Starting k3s (no systemd unit installed, running directly)..."
    K3S_PID=$(sudo bash -c 'nohup k3s server \
      > /var/log/k3s.log 2>&1 &
      echo $!')
fi

# True while k3s (systemd-supervised or the raw process above) is still alive
k3s_alive() {
    if [ -n "$K3S_PID" ]; then
        sudo kill -0 "$K3S_PID" 2>/dev/null
    else
        systemctl is-active --quiet k3s 2>/dev/null
    fi
}

# Poll until API server responds
echo "⏳ Waiting for Kubernetes API to become available..."
retries=0
until kubectl get nodes &> /dev/null; do
    if ! k3s_alive; then
        echo "❌ ERROR: k3s died during startup."
        echo "Check logs: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
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

# Poll until node reports Ready status
retries=0
until kubectl get nodes | grep -q " Ready"; do
    if ! k3s_alive; then
        echo "❌ ERROR: k3s died while waiting for node Ready."
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

# --- Step 2: Unseal in-cluster Vault ------------------------------------

# Returns seal status: unsealed, sealed, or unreachable
incluster_seal_state() {
    local exit_code=0
    kubectl exec -n vault vault-0 -- vault status -format=json > /dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo unsealed
    elif [ "$exit_code" -eq 2 ]; then
        echo sealed
    else
        echo unreachable
    fi
}

# Decrypts $1 and writes each key to Vault's unseal endpoint via stdin
decrypt_and_unseal() {
    local keyfile="$1"
    gpg --quiet --decrypt "$keyfile" | while IFS= read -r key; do
        [ -n "$key" ] || continue
        if ! error_output=$(printf '%s\n' "$key" | kubectl exec -i -n vault vault-0 -- vault write -format=json sys/unseal key=- 2>&1 >/dev/null); then
            echo "   ⚠️ Key rejected by Vault: $error_output"
        fi
    done
    return "${PIPESTATUS[0]}"
}

unseal_vault() {
    local seal_state
    seal_state=$(incluster_seal_state)

    if [ "$seal_state" = unsealed ]; then
        echo "✅ In-cluster Vault already unsealed."
        return 0
    fi

    if [ "$seal_state" = unreachable ]; then
        echo "❌ ERROR: Cannot reach vault-0. Continuing..."
        kubectl exec -n vault vault-0 -- vault status 2>&1 | sed 's/^/   /'
        echo "💡 TROUBLESHOOTING: Is the pod up?  kubectl get pods -n vault"
        return 1
    fi

    echo "🔒 In-cluster Vault is sealed."
    local keyfile="$HOME/.vault-keys.gpg"
    if [ ! -f "$keyfile" ]; then
        echo "❌ ERROR: $keyfile not found. Cannot unseal Vault."
        echo "💡 TROUBLESHOOTING: Did the GPG keyfile get created during 'just bootstrap' (INSTALLATION.md)?. Continuing..."
        return 1
    fi

    echo "🔑 Enter GPG passphrase to decrypt unseal keys:"
    if ! decrypt_and_unseal "$keyfile"; then
        echo "❌ ERROR: GPG decryption failed or was cancelled. Vault remains sealed. Continuing..."
        return 1
    fi

    seal_state=$(incluster_seal_state)
    case "$seal_state" in
        unsealed)
            echo "✅ In-cluster Vault unsealed successfully."
            ;;
        sealed)
            echo "❌ ERROR: Vault still sealed after applying keys from $keyfile. Continuing..."
            return 1
            ;;
        *)
            echo "❌ ERROR: Vault unreachable after applying keys from $keyfile. Continuing..."
            kubectl exec -n vault vault-0 -- vault status 2>&1 | sed 's/^/   /'
            return 1
            ;;
    esac
}

echo "⏳ Checking in-cluster Vault seal status..."
unseal_vault || had_warnings=true
echo ""

# --- Step 3: Un-hibernate PostGIS and resume backups ------------------------

unhibernate_postgis() {
    kubectl get cluster postgis-cluster -n databases &> /dev/null || return 0

    local hibernation_annotation
    hibernation_annotation=$(kubectl get cluster postgis-cluster -n databases \
        -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}' 2>/dev/null) || hibernation_annotation=""
    [ "$hibernation_annotation" = on ] || return 0

    echo "⏳ Rehydrating postgis-cluster from hibernation..."
    local retries=0
    until kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off 2>/dev/null; do
        retries=$((retries+1))
        if [ $retries -ge 6 ]; then
            echo "⚠️  Could not un-hibernate postgis-cluster (webhook timed out). Startup continues."
            echo "💡 TROUBLESHOOTING: Once the cluster settles, run manually:"
            echo "   kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off"
            return 1
        fi
        sleep 5
        echo "   ...still retrying re-hydration of database... ($((retries * 5))s elapsed)"
    done
    echo "✅ postgis-cluster un-hibernated successfully."
}

resume_scheduled_backups() {
    local scheduled_backups
    scheduled_backups=$(kubectl get scheduledbackup -n databases -o name 2>/dev/null) || scheduled_backups=""
    [ -n "$scheduled_backups" ] || return 0

    echo "▶️  Resuming scheduled backups..."
    local backup
    for backup in $scheduled_backups; do
        kubectl patch "$backup" -n databases --type merge -p '{"spec":{"suspend":false}}' 2>/dev/null || true
    done
}

unhibernate_postgis || had_warnings=true
resume_scheduled_backups
echo ""

if [ "$had_warnings" = true ]; then
    echo "⚠️  Cluster startup sequence complete, review warnings above."
    echo "   Check Headlamp, 'flux get kustomizations', or 'kubectl cnpg status postgis-cluster -n databases' for full health."
    exit 1
else
    echo "✅ Cluster startup sequence complete."
    echo "   Check Headlamp or 'flux get kustomizations' as everything else settles."
fi
