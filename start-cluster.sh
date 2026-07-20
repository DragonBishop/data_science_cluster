#!/bin/bash
#
# start-cluster.sh — brings up the local k3s cluster and confirms core
# workloads are healthy.
#
set -e

# --- Step 1: Refuse to start a duplicate instance --------------------------
# If systemd's own k3s.service is active, a second manually-launched k3s
# process would compete for the same ports and datastore. Bail out rather
# than risk that conflict.
if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "⚠️  systemd's k3s.service is already active. Refusing to start a second instance."
    echo "   Run: sudo systemctl stop k3s"
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml


# --- Step 2: Launch k3s ------------------------------------------------------
# Start the server in the background and capture its real PID directly from
# the backgrounded shell, rather than searching for it afterward.
echo "🚀 Starting k3s cluster..."

K3S_PID=$(sudo bash -c 'nohup k3s server \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable kube-proxy \
  --disable-network-policy \
  --flannel-backend=none \
  > /var/log/k3s.log 2>&1 &
  echo $!')


# --- Step 3: Wait for the API server ----------------------------------------
# Poll until kubectl can reach the API. If the process dies during this
# window, fail fast instead of waiting out the full timeout.
echo "⏳ Waiting for Kubernetes API to become available (pid $K3S_PID)..."

until kubectl get nodes &> /dev/null; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died during startup."
        echo "Check logs: sudo tail -n 50 /var/log/k3s.log"
        exit 1
    fi
    sleep 2
done

echo "✅ Kubernetes API is up."


# --- Step 4: Wait for the node to go Ready ----------------------------------
# The API can respond before the node finishes registering as schedulable.
until kubectl get nodes | grep -q " Ready"; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died while waiting for node Ready."
        exit 1
    fi
    sleep 2
done

echo "✅ Node is Ready."
echo ""


# --- Step 5: Awaken Postgres if it was hibernated ------------------------
# Hibernation (set by stop-cluster.sh) does not reverse itself. If the
# annotation is still "on", clear it so CNPG recreates the pod from the
# existing PVC.
if kubectl get cluster postgis-cluster -n databases &> /dev/null; then
  hib=$(kubectl get cluster postgis-cluster -n databases \
    -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}' 2>/dev/null)
  if [ "$hib" == "on" ]; then
    echo "⏳ Rehydrating postgis-cluster from hibernation..."
    kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off
    sleep 5
  fi
fi


# --- Step 6: Workload health checks -----------------------------------------
# Informational only — nothing here blocks the script or fails startup.
echo "🔎 Checking workload health..."

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

check_pod_ready 60 vault "app.kubernetes.io/name=vault" "Vault pod running"

# Confirm transit auto-unseal actually completed, not just that the pod exists.
if kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status" 2>/dev/null | grep -q "Sealed.*false"; then
  echo "  ✅ Vault is unsealed"
else
  echo "  ⚠️  Vault is NOT unsealed — check: kubectl exec -n vault vault-0 -- sh -c \"VAULT_ADDR=http://127.0.0.1:8200 vault status\""
fi

check_pod_ready 60 vault-secrets-operator-system "app.kubernetes.io/name=vault-secrets-operator" "VSO controller running"
check_pod_ready 60 cnpg-system "app.kubernetes.io/name=cloudnative-pg" "CNPG operator running"
check_pod_ready 90 databases "app=minio" "MinIO running"
check_pod_ready 60 falco "app.kubernetes.io/name=falco" "Falco running"

# Confirm each Vault-backed secret actually synced, not just that the CR exists.
for vss in minio-vault-secret postgis-vault-secret; do
  synced=$(kubectl get vaultstaticsecret "$vss" -n databases -o jsonpath='{.status.conditions[?(@.type=="SecretSynced")].status}' 2>/dev/null)
  if [ "$synced" == "True" ]; then
    echo "  ✅ $vss synced"
  else
    echo "  ⚠️  $vss not synced — check: kubectl describe vaultstaticsecret $vss -n databases"
  fi
done

# KNOWN ISSUE: exact string match against CNPG's status.phase field
# ("Cluster in healthy state" as of cloudnative-pg 0.29.0). This wording
# isn't a stable API — a future operator upgrade could reword it and cause
# a false ⚠️ here. If it misfires after a version bump, re-check with:
#   kubectl get cluster postgis-cluster -n databases -o jsonpath='{.status.phase}'
# and update the string below to match.
phase=$(kubectl get cluster postgis-cluster -n databases -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$phase" == "Cluster in healthy state" ]]; then
  echo "  ✅ postgis-cluster: $phase"
else
  echo "  ⚠️  postgis-cluster: ${phase:-not found} — check: kubectl describe cluster postgis-cluster -n databases"
fi

echo "✅ Cluster startup checks complete."