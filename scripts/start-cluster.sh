#!/bin/bash
#
# start-cluster.sh — brings up the local k3s cluster, enforces 
# strict dependency startup order, and rehydrates the database.
#
# The script tracks non-fatal errors during startup and will report
# them at the end, ensuring independent processes aren't needlessly
# interrupted while still surfacing failures to the user.
#
set -e
had_warnings=false

# --- Step 1: Refuse to start a duplicate instance --------------------------
# Checks whether systemd's k3s.service is already active. Two k3s processes
# managing the same data directory and ports would corrupt cluster state, so
# this exits immediately to prevent a second instance from launching.
if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "⚠️  systemd's k3s.service is already active. Refusing to start a second instance."
    echo "   To adopt a script-managed lifecycle, run: sudo systemctl disable --now k3s"
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# --- Step 2: Launch k3s ------------------------------------------------------
# Starts k3s server as a background process via nohup, so it keeps running
# after this script's shell exits. K3s's own network components (traefik, 
# servicelb, kube-proxy, flannel) are disabled here to avoid conflicting
# with Cilium. $! captures the backgrounded process's PID, used below to
# check it's still alive during the wait loops.
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
# Polls `kubectl get nodes` every 5 seconds until the API server responds.
# Each iteration also checks if the k3s PID is still alive, so a crash during
# startup is caught immediately. Failure here is fatal to avoid an infinite hang.
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

# --- Step 4: Wait for the node to go Ready ----------------------------------
# The node won't report Ready until a CNI is installed for Cilium. This loop
# has no retry cap since a first-time installation takes time, but it continues
# to verify the k3s process remains alive to prevent an indefinite hang.
retries=0
until kubectl get nodes | grep -q " Ready"; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died while waiting for node Ready."
        exit 1
    fi
    sleep 5
    retries=$((retries+1))
    echo "   ...still waiting for node... ($((retries * 5))s elapsed)"
done
echo "✅ Node is Ready."
echo ""

# --- Step 5: Unseal the Host Transit Vault ----------------------------------
# The Transit Vault re-seals on every host reboot. We check its status first 
# to avoid unnecessary password prompts if already unsealed. If sealed, the 
# 3 unseal keys are decrypted via GPG with a single passphrase and applied.
# Failures from this point onward are tracked as warnings but do not halt
# the script, allowing downstream components to report their own status.
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
        echo "💡 TROUBLESHOOTING: Did you create the GPG keyfile setup (README Step 5)?. Continuing..."
        had_warnings=true
    else
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
            echo "❌ ERROR: GPG decryption failed or was cancelled. Transit Vault remains sealed. Continuing..."
            had_warnings=true
        fi

        # Validate success by checking the actual Vault state directly, rather 
        # than relying solely on the pipeline's exit code.
        if vault status 2>/dev/null | grep -q "Sealed.*false"; then
            echo "✅ Host Transit Vault unsealed successfully."
        else
            echo "❌ ERROR: Transit Vault still sealed after applying keys from $KEYFILE. Continuing..."
            had_warnings=true
        fi
    fi
fi
echo ""

# --- Step 6: Wait for Cluster Vault and Secrets -----------------------------
# With the Transit Vault unsealed, the in-cluster Main Vault should now be
# able to auto-unseal itself. Polls vault-0's status every 5 seconds.
echo "⏳ Waiting for Vault to unseal..."
retries=0
until kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status" 2>/dev/null | grep -q "Sealed.*false"; do
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 9 ]; then
        echo "❌ ERROR: In-cluster Vault failed to unseal after 45 seconds. Continuing — VSO sync below will report its own status."
        echo "💡 TROUBLESHOOTING:"
        echo "   1. Is the host Transit Vault sealed? vault status -address=https://vault.local:8200"
        echo "   2. Cert/name mismatch? The seal verifies against 'vault.local' (tls_server_name),"
        echo "      which must be in the Transit cert's SANs and in /etc/hosts."
        echo "   3. Transit token expired? It renews while running, but >32d downtime kills it."
        echo "   4. Check logs: kubectl logs -n vault vault-0"
        had_warnings=true
        break
    fi
    echo "   ...still waiting for Cluster Vault... ($((retries * 5))s elapsed)"
done
if [ "$retries" -lt 9 ]; then
    echo "✅ Vault is unsealed."
fi

# Once Vault is unsealed, the Vault Secrets Operator (VSO) needs a moment to
# sync each VaultStaticSecret into a Kubernetes Secret. Checks the 'Ready'
# condition of each secret independently, allowing one to fail without
# blocking the check for the other.
echo "⏳ Waiting for Vault Secrets Operator to sync credentials..."
for vss in postgis-vault-secret minio-vault-secret; do
    retries=0
    until [ "$(kubectl get vaultstaticsecret "$vss" -n databases -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]; do
        sleep 5
        retries=$((retries+1))
        if [ $retries -ge 6 ]; then
            echo "❌ ERROR: VSO failed to sync $vss after 30 seconds. Continuing to check the remaining secrets/workloads."
            echo "💡 TROUBLESHOOTING: Run 'kubectl describe vaultstaticsecret $vss -n databases' and check the Events."
            had_warnings=true
            break
        fi
        echo "   ...still waiting on $vss ... ($((retries * 5))s elapsed)"
    done
    if [ "$retries" -lt 6 ]; then
        echo "✅ $vss synced."
    fi
done
echo ""

# --- Step 7: Wait for CNPG and Un-hibernate ---------------------------------
# Confirms the CNPG operator pod itself is ready before touching the database
# resource it manages. Tracks failures as warnings without halting the script.
echo "⏳ Verifying CNPG operator status..."
retries=0
until [ "$(kubectl get pods -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]; do
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 12 ]; then
        echo "⚠️  CNPG operator not Ready within 60s. Hibernation recovery may fail."
        had_warnings=true
        break
    fi
    echo "   ...still waiting for CNPG operator... ($((retries * 5))s elapsed)"
done
[ "$retries" -lt 12 ] && echo "✅ CNPG operator pod is Ready"

# If the postgis-cluster resource exists and carries the hibernation
# annotation, flips it off to bring the database back up. Retries the
# annotate call itself since CNPG's admission webhook can transiently reject
# requests while it's still initializing.
if kubectl get cluster postgis-cluster -n databases &> /dev/null; then
  hib=$(kubectl get cluster postgis-cluster -n databases \
    -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}' 2>/dev/null)
    
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
echo ""

# --- Step 8: Final health checks -----------------------------------------
# A non-blocking summary that reports workload statuses and captures any
# final warnings to reflect in the script's final exit code.
echo "🔎 Final workload health check..."

check_pod_ready() {
  local timeout=$1 ns=$2 label=$3 desc=$4
  local waited=0 status=""
  while (( waited < timeout )); do
    status=$(kubectl get pods -n "$ns" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$status" == "Running" ]; then
      echo "  ✅ $desc"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    if (( waited < timeout )); then
      echo "   ...still waiting on $desc (${waited}s elapsed)"
    fi
  done
  echo "  ⚠️  $desc — not Running after ${timeout}s (last status:${status:-not found})"
  return 1
}

check_pod_ready 60 databases "app=minio" "MinIO running" || had_warnings=true

phase=$(kubectl get cluster postgis-cluster -n databases -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$phase" == "Cluster in healthy state" ]]; then
  echo "  ✅ postgis-cluster: $phase"
else
  echo "  ⚠️  postgis-cluster: ${phase:-not found}"
  echo "💡 TROUBLESHOOTING: Run 'kubectl get cluster postgis-cluster -n databases' to check cluster health."
  had_warnings=true
fi

echo ""
if [ "$had_warnings" = true ]; then
    echo "⚠️  Cluster startup sequence complete, review warnings."
    exit 1
else
    echo "✅ Cluster startup sequence complete."
fi