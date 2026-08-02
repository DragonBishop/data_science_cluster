#!/bin/bash
#
# stop-cluster.sh — Orchestrates graceful CloudNativePG hibernation and k3s teardown.
#
# Determines if k3s is systemd-managed or script-launched to apply the correct stop mechanism.
# Hibernation strictly gates the stop process to ensure PostgreSQL checkpoints gracefully before
# API shutdown, preventing WAL replays on subsequent boots. Use --force to bypass this gate.
#
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

CLUSTER_NAME=postgis-cluster
CLUSTER_NS=databases
CNPG_NS=cnpg-system

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        -h|--help)
            echo "Usage: $0 [--force]"
            echo "  --force   stop k3s even when hibernation cannot be confirmed,"
            echo "            and force-kill leftovers if :6443 stays bound."
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Aborts execution and preserves cluster state if a prerequisite fails, unless --force is passed.
halt() {
    echo ""
    echo "❌ ERROR: $*"
    if [ "$FORCE" = false ]; then
        echo ""
        echo "   k3s has NOT been stopped and the database is still running."
        echo "   Address the cause above, or re-run with --force to stop anyway"
        echo "   (PostgreSQL will crash-recover on the next start)."
        exit 1
    fi
    echo "⚠️  --force supplied — continuing."
    echo ""
}

# --- Step 1: Acquire sudo ---------------------------------------------------
# Pre-authenticates sudo to prevent password prompts from interrupting or 
# timing out the subsequent hibernation polling loops.
if ! sudo -v; then
    echo "❌ ERROR: sudo authentication failed. Cannot inspect or stop k3s."
    exit 1
fi

# --- Step 2: Identify k3s and its supervisor --------------------------------
# Identifies the active k3s process via the API port (6443) and determines its supervisor 
# (systemd vs. standalone). These independent checks inform the teardown mechanism in Step 4.
K3S_PID=$(sudo ss -tlnp 2>/dev/null | grep ':6443 ' | grep -oP 'pid=\K[0-9]+' | head -1)

systemd_owned=false
if systemctl is-active --quiet k3s 2>/dev/null || systemctl is-enabled --quiet k3s 2>/dev/null; then
    systemd_owned=true
fi

if [ -z "$K3S_PID" ] && [ "$systemd_owned" = false ]; then
    echo "ℹ️  k3s is not running (nothing listening on :6443) and k3s.service is not enabled."
    exit 0
fi

# --- Step 3: Hibernate Postgres --------------------------------------------
# Triggers CloudNativePG (CNPG) cluster hibernation via the Kubernetes API. The CNPG operator 
# safely shuts down PostgreSQL and removes the pods while preserving the PVC. Differentiates 
# between an unreachable API (fatal) and an absent database cluster (benign skip).
if ! kubectl get --raw='/readyz' &>/dev/null; then
    halt "Kubernetes API is unreachable, so $CLUSTER_NAME cannot be hibernated.
   Check: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
elif ! kubectl get cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" &>/dev/null; then
    echo "ℹ️  $CLUSTER_NAME not found — skipping."
else
    # Verifies the CNPG operator deployment is available. Writing the hibernation 
    # annotation to an unmonitored cluster succeeds at the API level but hangs indefinitely.
    echo "🔎 Verifying the CNPG operator is Available..."
    if ! kubectl get deployment -n "$CNPG_NS" -l app.kubernetes.io/name=cloudnative-pg \
            -o name 2>/dev/null | grep -q .; then
        halt "No CloudNativePG operator Deployment in namespace $CNPG_NS, but a
   Cluster resource exists. Hibernation cannot be performed."
    elif ! kubectl wait --for=condition=Available deployment \
            -l app.kubernetes.io/name=cloudnative-pg \
            -n "$CNPG_NS" --timeout=60s &>/dev/null; then
        echo ""
        kubectl get deployment -n "$CNPG_NS" -l app.kubernetes.io/name=cloudnative-pg
        halt "The CNPG operator is not Available. The hibernation annotation would
   be written and never acted on.
   Check: kubectl get pods -n $CNPG_NS"
    fi
    echo "  ✅ Operator is Available."

    echo "💤 Hibernating $CLUSTER_NAME..."
    if ! kubectl annotate cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" \
            --overwrite cnpg.io/hibernation=on; then
        halt "Failed to set the hibernation annotation on $CLUSTER_NAME."
    fi

    # Polls for asynchronous hibernation completion up to 300s (accounting for CNPG's default 
    # 180s .spec.smartShutdownTimeout). Succeeds if the operator reports the condition as 'True' 
    # OR if all instance pods are successfully removed. Captures detailed conditions for timeouts.
    hib_status=""; hib_reason=""; hib_message=""
    hibernated=false
    retries=0
    while [ $retries -lt 60 ]; do
        raw=$(kubectl get cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" \
            -o jsonpath='{range .status.conditions[?(@.type=="cnpg.io/hibernation")]}{.status}|{.reason}|{.message}{end}' \
            2>/dev/null) || raw=""
        hib_status=${raw%%|*}
        rest=${raw#*|}
        hib_reason=${rest%%|*}
        hib_message=${rest#*|}

        if [ "$hib_status" == "True" ]; then
            hibernated=true
            echo "  ✅ Operator reports hibernated: ${hib_message:-Cluster has been hibernated}"
            break
        fi

        if [ -z "$(kubectl get pods -n "$CLUSTER_NS" \
                -l "cnpg.io/cluster=$CLUSTER_NAME" -o name 2>/dev/null)" ]; then
            hibernated=true
            echo "  ✅ All instance pods removed."
            break
        fi

        sleep 5
        retries=$((retries+1))
        echo "   ...still hibernating... ($((retries * 5))s elapsed, ${hib_reason:-no condition written yet})"
    done

    if [ "$hibernated" = false ]; then
        echo ""
        kubectl get pods -n "$CLUSTER_NS" -l "cnpg.io/cluster=$CLUSTER_NAME"
        halt "Hibernation not confirmed within 300s.
   condition status : ${hib_status:-<none>}
   condition reason : ${hib_reason:-<no condition written>}
   condition message: ${hib_message:-<none>}
   Check: kubectl cnpg status $CLUSTER_NAME -n $CLUSTER_NS
          kubectl logs -n $CNPG_NS -l app.kubernetes.io/name=cloudnative-pg --tail=50"
    fi
fi
echo ""

# --- Step 4: Stop k3s -------------------------------------------------------
# Terminates k3s based on its supervisor. Disables the systemd unit to prevent 
# Restart=always loops and removes boot-time enablement, or sends SIGTERM directly 
# to the standalone process PID.
if [ "$systemd_owned" = true ]; then
    echo "🔻 systemd owns k3s.service — stopping and disabling the unit."
    echo "   k3s will no longer start automatically at boot; use start-cluster.sh."
    if ! sudo systemctl disable --now k3s; then
        echo "❌ ERROR: 'systemctl disable --now k3s' failed."
        echo "   Check: systemctl status k3s"
        exit 1
    fi
elif [ -n "$K3S_PID" ]; then
    echo "🔻 Sending graceful stop to k3s (pid $K3S_PID)..."
    if ! sudo kill -TERM "$K3S_PID"; then
        echo "❌ ERROR: Failed to signal pid $K3S_PID."
        exit 1
    fi
fi

# --- Step 5: Confirm the API server is down ---------------------------------
# Polls port 6443 to ensure the API server fully relinquishes the socket. If it fails 
# to close within 30s, falls back to manual administrator intervention or automated 
# k3s-killall.sh reaping if --force is active.
for i in $(seq 1 30); do
    if ! sudo ss -tlnp 2>/dev/null | grep -q ':6443 '; then
        echo "💤 k3s stopped cleanly."
        # Container processes safely outlive the API server. Leftover containerd-shim 
        # trees and mounts remain harmless until the next start since the database 
        # PVC is already safely hibernated.
        exit 0
    fi
    sleep 1
done

echo ""
echo "⚠️  Port 6443 is still bound 30s after the stop request."
if [ "$FORCE" = true ]; then
    echo "🔻 --force supplied — running k3s-killall.sh."
    sudo k3s-killall.sh
    if sudo ss -tlnp 2>/dev/null | grep -q ':6443 '; then
        echo "❌ ERROR: :6443 is still bound after k3s-killall.sh."
        exit 1
    fi
    echo "💤 k3s force-stopped."
    exit 0
fi
echo "   Check: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
echo "   Force-stop: $0 --force   (or: sudo k3s-killall.sh)"
exit 1