# --- Step 1: Hibernate Postgres --------------------------------------------
# Request CloudNativePG to hibernate the cluster through the Kubernetes API.
# The operator performs a graceful PostgreSQL shutdown before removing the pod,
# while preserving the PersistentVolumeClaim for later restart.
if kubectl get cluster postgis-cluster -n databases &> /dev/null; then
  echo "💤 Hibernating postgis-cluster..."
  kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=on

  # Hibernation completes asynchronously, so wait until the operator reports
  # the cluster has fully entered the hibernated state.
  status=""
  for i in $(seq 1 30); do
    status=$(kubectl get cluster postgis-cluster -n databases \
      -o jsonpath='{.status.conditions[?(@.type=="cnpg.io/hibernation")].status}' 2>/dev/null)
    [ "$status" == "True" ] && { echo "  ✅ Hibernated cleanly."; break; }
    sleep 2
  done

  if [ "$status" != "True" ]; then
    echo "  ⚠️  Hibernation didn't confirm within 60s — check: kubectl cnpg status postgis-cluster -n databases"
  fi
else
  echo "ℹ️  postgis-cluster not found — skipping."
fi


# --- Step 2: Find the k3s server PID ---------------------------------------
# Locate the running k3s server by finding the process that owns the Kubernetes
# API server socket on port 6443.
K3S_PID=$(sudo ss -tlnp 2>/dev/null | grep ':6443 ' | grep -oP 'pid=\K[0-9]+' | head -1)

if [ -z "$K3S_PID" ]; then
    echo "k3s is not running (nothing listening on :6443)."
    exit 0
fi


# --- Step 3: Gracefully stop k3s -------------------------------------------
# Send SIGTERM and wait for k3s to shut down normally. If it doesn't exit
# within the timeout, report the condition and leave the decision to force-stop
# to the administrator.
echo "Sending graceful stop to k3s (pid $K3S_PID)..."
sudo kill -TERM "$K3S_PID"

for i in $(seq 1 15); do
    sudo kill -0 "$K3S_PID" 2>/dev/null || { echo "💤 k3s stopped cleanly."; exit 0; }
    sleep 1
done

echo "⚠️  k3s (pid $K3S_PID) did not stop within 15s of SIGTERM."
echo "   Check: sudo tail -n 50 /var/log/k3s.log"
echo "   Force-stop if needed: sudo k3s-killall.sh"
exit 1