#!/bin/bash
#
# stop-cluster.sh: Hibernates CloudNativePG cluster and stops k3s.
#
set -uo pipefail
export KUBECONFIG="$HOME/.kube/config"

CLUSTER_NAME=postgis-cluster
CLUSTER_NS=databases
CNPG_NS=cnpg-system

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        -h|--help)
            echo "Usage: $0 [--force]"
            echo "  --force   stop k3s even when hibernation cannot be confirmed."
            echo "            Prompts before running k3s-killall.sh if port 6443 remains bound."
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Halts execution on error, or continues if --force is set
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
    echo "⚠️  --force supplied: continuing."
    echo ""
}

# --- Step 1: Acquire sudo ---------------------------------------------------
# Authenticate sudo
if ! sudo -v; then
    echo "❌ ERROR: sudo authentication failed. Cannot inspect or stop k3s."
    exit 1
fi

# --- Step 2: Identify k3s process and supervisor ---------------------------
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
# Annotate CNPG cluster to hibernate and pause scheduled backups
if ! kubectl get --raw='/readyz' &>/dev/null; then
    halt "Kubernetes API is unreachable, so $CLUSTER_NAME cannot be hibernated.
   Check: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
elif ! kubectl get cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" &>/dev/null; then
    echo "ℹ️  $CLUSTER_NAME not found: skipping."
else
    echo "💤 Hibernating $CLUSTER_NAME..."
    if ! kubectl annotate cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" \
            --overwrite cnpg.io/hibernation=on; then
        halt "Failed to set the hibernation annotation on $CLUSTER_NAME."
    fi
    
    # Capture scheduled backups to pause
    sbs=$(kubectl get scheduledbackup -n "$CLUSTER_NS" -o name 2>/dev/null) || sbs=""
    if [ -n "$sbs" ]; then
        echo "⏸️  Pausing scheduled backups..."
        for sb in $sbs; do
            if ! kubectl patch "$sb" -n "$CLUSTER_NS" --type merge -p '{"spec":{"suspend":true}}'; then
                echo "   ⚠️  Failed to pause $sb"
            fi
        done
    fi
    
    # Poll until hibernation completes or all instance pods are terminated
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
# Stop k3s via systemd or SIGTERM
if [ "$systemd_owned" = true ]; then
    echo "🔻 Stopping and disabling systemd k3s.service..."
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
# Poll port 6443 until socket is released
for i in $(seq 1 30); do
    if ! sudo ss -tlnp 2>/dev/null | grep -q ':6443 '; then
        echo "💤 k3s stopped cleanly."
        exit 0
    fi
    sleep 1
done

echo ""
echo "⚠️  Port 6443 is still bound 30s after the stop request."
if [ "$FORCE" = true ]; then
    # Prompt before running k3s-killall.sh
    echo "🔻 --force was supplied, and k3s-killall.sh would force-stop remaining processes."
    read -r -p "   Run k3s-killall.sh now? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo "   Skipped. Nothing was killed."
            echo "   Check: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
            echo "   Force-stop manually: sudo k3s-killall.sh"
            exit 1 ;;
    esac
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