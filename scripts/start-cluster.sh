#!/bin/bash
#
# start-cluster.sh — brings up the local k3s cluster, enforces 
# strict dependency startup order, and rehydrates the database.
#
set -e

# --- Step 1: Refuse to start a duplicate instance --------------------------
# Checks whether systemd's k3s.service is already active. Two k3s processes
# managing the same data directory and ports would corrupt cluster state, so
# this exits immediately rather than letting that happen.
if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "⚠️  systemd's k3s.service is already active. Refusing to start a second instance."
    echo "   To adopt a script-managed lifecycle, run: sudo systemctl disable --now k3s"
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# --- Step 2: Launch k3s ------------------------------------------------------
# Starts k3s server as a background process via nohup, so it keeps running
# after this script's shell exits. K3s's own network components (traefik, 
# kube-proxy, flannel) are disabled here to avoid conflicting with Cilium. 
# $! captures the backgrounded process's PID, used below to check it's still
# alive during the wait loops.
echo "🚀 Starting k3s cluster..."
K3S_PID=$(sudo bash -c 'nohup k3s server \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb \
  --disable-kube-proxy \
  --disable-network-policy \
  --flannel-backend=none \
  > /var/log/k3s.log 2>&1 &
  echo $!')

# --- Step 3: Wait for the API server ----------------------------------------
# Polls `kubectl get nodes` every 2 seconds until the API server responds.
# Each iteration also checks the k3s PID is still alive, so a crash during
# startup is caught immediately instead of waiting out the full 60s timeout.
echo "⏳ Waiting for Kubernetes API to become available (pid $K3S_PID)..."
retries=0
until kubectl get nodes &> /dev/null; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died during startup."
        echo "Check logs: sudo tail -n 50 /var/log/k3s.log"
        exit 1
    fi
    sleep 2
    retries=$((retries+1))
    if [ $retries -ge 30 ]; then
        echo "❌ ERROR: API server failed to respond after 60 seconds."
        exit 1
    fi
done
echo "✅ Kubernetes API is up."

# --- Step 4: Wait for the node to go Ready ----------------------------------
# The node won't report Ready until a CNI is installed for Cilium.
until kubectl get nodes | grep -q " Ready"; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died while waiting for node Ready."
        exit 1
    fi
    sleep 2
done
echo "✅ Node is Ready."
echo ""

# --- Step 5: Unseal the Host Transit Vault (CRITICAL DEPENDENCY) -----------
# The Transit Vault re-seals on every host reboot. We check its status first 
# to avoid unnecessary password prompts if already unsealed. If sealed, the 
# 3 unseal keys are decrypted via GPG with a single passphrase and applied.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/transit.crt"

echo "⏳ Checking host Transit Vault seal status..."
if vault status 2>/dev/null | grep -q "Sealed.*false"; then
    echo "✅ Host Transit Vault already unsealed."
else
    echo "🔒 Host Transit Vault is sealed."

    # Path to the GPG-encrypted file holding the 3 Shamir unseal keys,
    # formatted one key per line (see README Step 5 for one-time setup).
    KEYFILE="$HOME/.vault-keys.gpg"
    if [ ! -f "$KEYFILE" ]; then
        echo "❌ ERROR: $KEYFILE not found. Cannot unseal Transit Vault."
        echo "💡 TROUBLESHOOTING: Re-run the GPG keyfile setup from the README (Step 5)."
        exit 1
    fi

    # Decrypts and applies the keys. Shamir's threshold scheme requires keys 
    # to be submitted individually, hence the loop.
    #
    # NOTE: `vault operator unseal` lacks a stdin mode, requiring keys as 
    # arguments. This makes them briefly visible to other processes via `ps`. 
    # This is an accepted tradeoff for a single-user local machine.
    #
    # Wrapped in a function to capture gpg's true exit code via PIPESTATUS, 
    # otherwise the while loop would always exit 0 even on decryption failure.
    decrypt_and_unseal() {
        gpg --quiet --decrypt "$KEYFILE" | while IFS= read -r key; do
            [ -n "$key" ] && vault operator unseal "$key" > /dev/null
        done
        return "${PIPESTATUS[0]}"
    }

    echo "🔑 Enter GPG passphrase to decrypt unseal keys:"
    if ! decrypt_and_unseal; then
        echo "❌ ERROR: GPG decryption failed or was cancelled. Transit Vault remains sealed."
        exit 1
    fi

    # Validate success by checking the actual Vault state directly, rather 
    # than relying solely on the pipeline's exit code.
    if vault status 2>/dev/null | grep -q "Sealed.*false"; then
        echo "✅ Host Transit Vault unsealed successfully."
    else
        echo "❌ ERROR: Transit Vault still sealed after applying keys from $KEYFILE."
        echo "💡 TROUBLESHOOTING: Run 'VAULT_CACERT=$VAULT_CACERT vault status -address=$VAULT_ADDR' manually to inspect."
        exit 1
    fi
fi
echo ""

# --- Step 6: Wait for Cluster Vault and Secrets (CRITICAL DEPENDENCY) -------
# With the Transit Vault unsealed, the in-cluster Main Vault should now be
# able to auto-unseal itself against it. Polls vault-0's own status every
# 3 seconds for up to 45 seconds.
echo "⏳ Waiting for Vault to unseal..."
retries=0
until kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status" 2>/dev/null | grep -q "Sealed.*false"; do
    sleep 3
    retries=$((retries+1))
    if [ $retries -ge 15 ]; then
        echo "❌ ERROR: In-cluster Vault failed to unseal after 45 seconds."
        echo "💡 TROUBLESHOOTING:"
        echo "   1. Check if host Transit Vault is sealed: VAULT_CACERT=/opt/vault/tls/transit.crt vault status -address=https://127.0.0.1:8200"
        echo "   2. Did your WSL IP change? Update vault-values.yaml and restart the vault-0 pod."
        echo "   3. Check logs: kubectl logs -n vault vault-0"
        exit 1
    fi
done
echo "✅ Vault is unsealed."

# Once Vault is unsealed, the Vault Secrets Operator (VSO) still needs a
# moment to sync each VaultStaticSecret into a real Kubernetes Secret.
# Checks each one's SecretSynced condition individually, up to 30s each.
echo "⏳ Waiting for Vault Secrets Operator to sync credentials..."
for vss in postgis-vault-secret minio-vault-secret; do
    retries=0
    until [ "$(kubectl get vaultstaticsecret "$vss" -n databases -o jsonpath='{.status.conditions[?(@.type=="SecretSynced")].status}' 2>/dev/null)" == "True" ]; do
        sleep 2
        retries=$((retries+1))
        if [ $retries -ge 15 ]; then
            echo "❌ ERROR: VSO failed to sync $vss after 30 seconds."
            echo "💡 TROUBLESHOOTING: Run 'kubectl describe vaultstaticsecret $vss -n databases' and check the Events."
            exit 1
        fi
    done
    echo "✅ $vss synced."
done
echo ""

# --- Step 7: Wait for CNPG and Un-hibernate ---------------------------------
# Confirms the CNPG operator pod itself is ready before touching the
# database resource it manages — a non-fatal warning only, since the
# hibernation-recovery attempt below will surface the real failure if the
# operator genuinely isn't available.
echo "⏳ Verifying CNPG operator status..."
kubectl wait --for=condition=Ready pod -n cnpg-system \
  -l app.kubernetes.io/name=cloudnative-pg --timeout=60s 2>/dev/null \
  && echo "✅ CNPG operator pod is Ready" \
  || echo "⚠️  CNPG operator not Ready within 60s. Hibernation recovery may fail."

# If the postgis-cluster resource exists and carries the hibernation
# annotation, flips it off to bring the database back up. Retries the
# annotate call itself (not just a status check) since CNPG's admission
# webhook can transiently reject requests while it's still initializing.
if kubectl get cluster postgis-cluster -n databases &> /dev/null; then
  hib=$(kubectl get cluster postgis-cluster -n databases \
    -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}' 2>/dev/null)
    
  if [ "$hib" == "on" ]; then
    echo "⏳ Rehydrating postgis-cluster from hibernation..."
    
    retries=0
    success=false
    until [ $retries -ge 10 ]; do
        if kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off 2>/dev/null; then
            success=true
            break
        fi
        sleep 3
        retries=$((retries+1))
    done

    if [ "$success" = true ]; then
        echo "✅ postgis-cluster un-hibernated successfully."
    else
        echo "⚠️  Could not un-hibernate postgis-cluster (webhook timed out). Startup continues."
        echo "💡 TROUBLESHOOTING: Once the cluster settles, run manually:"
        echo "   kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off"
    fi
  fi
fi
echo ""

# --- Step 8: Final health checks -----------------------------------------
# This last step is a non-blocking summary: it reports each workload's status
# without exiting on a bad result.
echo "🔎 Final workload health check..."

# Polls a pod's phase by label selector until it's running or the timeout
# elapses; reusable across MinIO and Falco below instead of duplicating
# the same polling loop twice.
check_pod_ready() {
  local timeout=$1 ns=$2 label=$3 desc=$4
  local waited=0 status=""
  while (( waited < timeout )); do
    status=$(kubectl get pods -n "$ns" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$status" == "Running" ]; then
      echo "  ✅ $desc"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  echo "  ⚠️  $desc — not Running after ${timeout}s (last status: ${status:-not found})"
}

check_pod_ready 60 databases "app=minio" "MinIO running"
check_pod_ready 60 falco "app.kubernetes.io/name=falco" "Falco running"

# Check CNPG cluster phase
phase=$(kubectl get cluster postgis-cluster -n databases -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$phase" == "Cluster in healthy state" ]]; then
  echo "  ✅ postgis-cluster: $phase"
else
  echo "  ⚠️  postgis-cluster: ${phase:-not found}"
  echo "💡 TROUBLESHOOTING: Run 'kubectl get cluster postgis-cluster -n databases' to check cluster health."
fi

echo ""
echo "✅ Cluster startup sequence complete."