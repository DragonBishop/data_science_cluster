#!/bin/bash
#
# start-cluster.sh — Brings up the local k3s cluster, unseals the host Transit Vault,
# waits for Vault Secrets Operator (VSO) credential sync, and rehydrates CNPG databases.
#
# Non-fatal startup errors are tracked as warnings to allow independent services
# to continue initializing, returning an exit status of 1 at the end if issues occurred.
#
set -eu
had_warnings=false

# --- Step 1: Prevent duplicate execution ----------------------------------
# Abort immediately if systemd's k3s service is active. Running two k3s instances
# against the same data directory and ports will corrupt cluster state.
if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "⚠️  systemd's k3s.service is already active. Refusing to start a second instance."
    echo "   To adopt a script-managed lifecycle, run: sudo systemctl disable --now k3s"
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# --- Step 2: Launch k3s Server ---------------------------------------------
# Launch k3s server as a background process via nohup. Default networking components
# (traefik, servicelb, kube-proxy, flannel) are disabled so Cilium can handle CNI,
# proxying, ingress, and network policy enforcement.
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

# --- Step 3: Wait for API Server -------------------------------------------
# Poll `kubectl get nodes` every 5 seconds until the API server responds (60s timeout).
# Monitors the k3s process PID on each iteration to catch early process crashes immediately.
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
# Poll node status until reported as 'Ready' (5 min timeout to allow image pulls/CNI init).
# Nodes remain NotReady until Cilium is active. Continues tracking k3s PID health.
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
        echo "   2. On a first-time build, install it now (README Step 2):"
        echo "      cilium install --set gatewayAPI.enabled=true --set kubeProxyReplacement=true"
        exit 1
    fi
    echo "   ...still waiting for node... ($((retries * 5))s elapsed)"
done
echo "✅ Node is Ready."
echo ""

# --- Step 5: Unseal Host Transit Vault ------------------------------------
# Check state of the host Transit Vault. If sealed, decrypt local Shamir unseal keys via GPG.
# Stream keys via standard input using `key=-` to avoid process-list exposure in `/proc/<pid>/cmdline`.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"

# Query state: 0 = unsealed, 2 = sealed, non-zero/non-two = TLS or connectivity issue.
transit_seal_state() {
    local rc=0
    vault status -format=json > /dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo unsealed
    elif [ "$rc" -eq 2 ]; then
        echo sealed
    else
        echo unreachable
    fi
}

echo "⏳ Checking host Transit Vault seal status..."
seal_state=$(transit_seal_state)
if [ "$seal_state" = unsealed ]; then
    echo "✅ Host Transit Vault already unsealed."
elif [ "$seal_state" = unreachable ]; then
    echo "❌ ERROR: Cannot reach the host Transit Vault at $VAULT_ADDR. Continuing..."
    vault status 2>&1 | sed 's/^/   /'
    echo "💡 TROUBLESHOOTING: This is a connection or certificate failure, not a seal."
    echo "   1. Does the CA file exist?  ls -l $VAULT_CACERT"
    echo "   2. Does the cert cover this address? It needs an IP:127.0.0.1 SAN."
    echo "   3. Is the service up?  systemctl status vault"
    had_warnings=true
else
    echo "🔒 Host Transit Vault is sealed."
    KEYFILE="$HOME/.vault-keys.gpg"
    if [ ! -f "$KEYFILE" ]; then
        echo "❌ ERROR: $KEYFILE not found. Cannot unseal Transit Vault."
        echo "💡 TROUBLESHOOTING: Did you create the GPG keyfile setup (README Step 5)?. Continuing..."
        had_warnings=true
    else
        # Decrypt keys and stream via stdin (key=-) to maintain command-line confidentiality.
        # Captures stderr on failure to ensure rejected keys are reported, while hiding JSON stdout on success.
        decrypt_and_unseal() {
            gpg --quiet --decrypt "$KEYFILE" | while IFS= read -r key; do
                [ -n "$key" ] || continue
                if ! err=$(printf '%s\n' "$key" | vault write -format=json sys/unseal key=- 2>&1 >/dev/null); then
                    echo "   ⚠️ Key rejected by Vault: $err"
                fi
            done
            return "${PIPESTATUS[0]}"
        }
        
        echo "🔑 Enter GPG passphrase to decrypt unseal keys:"
        if ! decrypt_and_unseal; then
            echo "❌ ERROR: GPG decryption failed or was cancelled. Transit Vault remains sealed. Continuing..."
            had_warnings=true
        fi

        seal_state=$(transit_seal_state)
        if [ "$seal_state" = unsealed ]; then
            echo "✅ Host Transit Vault unsealed successfully."
        elif [ "$seal_state" = sealed ]; then
            echo "❌ ERROR: Transit Vault still sealed after applying keys from $KEYFILE. Continuing..."
            had_warnings=true
        else
            echo "❌ ERROR: Transit Vault unreachable after applying keys from $KEYFILE. Continuing..."
            vault status 2>&1 | sed 's/^/   /'
            had_warnings=true
        fi
    fi
fi
echo ""

# --- Step 6: Renew Transit Auto-Unseal Token -------------------------------
# Renew the periodic token presented by the in-cluster Vault to the Host Transit Vault (resets 768h window).
# Token is passed via VAULT_TOKEN environment variable rather than positional argument.
echo "⏳ Rolling the Transit auto-unseal token forward..."
transit_token=$(kubectl get secret vault-transit-secret -n vault \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null) || transit_token=""
if [ -z "$transit_token" ]; then
    echo "⚠️  Could not read vault-transit-secret — skipping renewal."
    echo "💡 TROUBLESHOOTING: kubectl get secret vault-transit-secret -n vault"
    had_warnings=true
elif VAULT_TOKEN="$transit_token" vault token renew > /dev/null 2>&1; then
    ttl=$(VAULT_TOKEN="$transit_token" vault token lookup 2>/dev/null \
        | awk '$1=="ttl"{print $2}') || ttl=""
    echo "✅ Transit token renewed (ttl now ${ttl:-unknown})."
else
    echo "⚠️  Transit token renewal failed. Auto-unseal keeps working until the"
    echo "   token's window closes; after that the in-cluster Vault cannot unseal."
    echo "💡 TROUBLESHOOTING: Issue a replacement from the host Transit Vault and"
    echo "   replace the Secret (README Steps 3 and 4):"
    echo "   vault token create -policy=autounseal-policy -period=768h -orphan"
    echo "   kubectl create secret generic vault-transit-secret -n vault \\"
    echo "     --from-literal=token='<new token>' --dry-run=client -o yaml | kubectl apply -f -"
    echo "   kubectl delete pod -n vault vault-0"
    had_warnings=true
fi
echo ""

# --- Step 7: Wait for In-Cluster Vault & VSO Secret Sync --------------------
# Poll vault-0 pod status until auto-unseal completes against the host Transit Vault.
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

# Verify Vault Secrets Operator (VSO) synchronizes VaultStaticSecret CRDs into Kubernetes Secrets.
echo "⏳ Waiting for Vault Secrets Operator to sync credentials..."
for vss in postgis-vault-secret seaweedfs-vault-secret; do
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

# Check VaultDynamicSecret status (non-fatal; pending is expected if database secrets engine is unconfigured).
retries=0
until [ "$(kubectl get vaultdynamicsecret postgis-app-dynamic-secret -n databases -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]; do
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 6 ]; then
        echo "⚠️  postgis-app-dynamic-secret not Ready after 30 seconds — expected if Vault's database secrets engine hasn't been configured yet."
        had_warnings=true
        break
    fi
    echo "   ...still waiting on postgis-app-dynamic-secret ... ($((retries * 5))s elapsed)"
done
[ "$retries" -lt 6 ] && echo "✅ postgis-app-dynamic-secret synced."
echo ""

# --- Step 8: CNPG Operator Verification & PostGIS Rehydration -------------
# Ensure CloudNativePG (CNPG) operator pod is ready before sending commands to database CRDs.
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

# Remove hibernation annotation on postgis-cluster to trigger database pod startup.
# Retries annotation command to account for transient admission webhook readiness delays.
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
echo ""

# --- Step 9: Final Workload Health Checks ---------------------------------
# Perform non-blocking summary checks on key workloads and set overall script exit code.
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

check_pod_ready 60 databases "app=seaweedfs" "SeaweedFS running" || had_warnings=true

# Evaluate CNPG database cluster status phase.
phase=$(kubectl get cluster postgis-cluster -n databases -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
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