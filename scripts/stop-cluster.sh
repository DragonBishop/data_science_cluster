#!/bin/bash
#
# stop-cluster.sh — hibernates the database, then stops k3s through
# whichever supervisor currently owns it.
#
# k3s runs either under systemd or as a background process launched by
# start-cluster.sh, and the two require different stop mechanisms. The script
# establishes which is in play before acting, and tracks non-fatal errors so a
# failed hibernation is surfaced rather than silently leaving the cluster up.
#
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

had_warnings=false

# --- Step 1: Identify k3s and its supervisor --------------------------------
# Locates the process holding the Kubernetes API socket on port 6443, and asks
# systemd separately whether it still claims k3s.service. The two answers are
# independent — the unit can be enabled while nothing is running, and a
# script-launched k3s has no unit behind it at all — and together they select
# the stop mechanism used in Step 3.
K3S_PID=$(sudo ss -tlnp 2>/dev/null | grep ':6443 ' | grep -oP 'pid=\K[0-9]+' | head -1)

systemd_owned=false
if systemctl is-active --quiet k3s 2>/dev/null || systemctl is-enabled --quiet k3s 2>/dev/null; then
    systemd_owned=true
fi

if [ -z "$K3S_PID" ] && [ "$systemd_owned" = false ]; then
    echo "ℹ️  k3s is not running (nothing listening on :6443) and k3s.service is not enabled."
    exit 0
fi

# --- Step 2: Hibernate Postgres --------------------------------------------
# Request CloudNativePG to hibernate the cluster through the Kubernetes API.
# The operator performs a graceful PostgreSQL shutdown before removing the pod,
# while preserving the PersistentVolumeClaim for later restart.
#
# An unreachable API server and an absent cluster resource mean different
# things: the first leaves Postgres to be stopped without hibernating and is
# tracked as a warning, the second is the ordinary state on a cluster that has
# no database deployed yet.
if ! kubectl get nodes &>/dev/null; then
    echo "⚠️  Kubernetes API is unreachable — cannot hibernate postgis-cluster."
    echo "   Postgres will be stopped without a hibernation checkpoint."
    had_warnings=true
elif ! kubectl get cluster postgis-cluster -n databases &>/dev/null; then
    echo "ℹ️  postgis-cluster not found — skipping."
else
    echo "💤 Hibernating postgis-cluster..."
    kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=on

    # Hibernation completes asynchronously, so wait until the operator reports
    # the cluster has fully entered the hibernated state.
    status=""
    for i in $(seq 1 30); do
        status=$(kubectl get cluster postgis-cluster -n databases \
            -o jsonpath='{.status.conditions[?(@.type=="cnpg.io/hibernation")].status}' 2>/dev/null) || status=""
        [ "$status" == "True" ] && { echo "  ✅ Hibernated cleanly."; break; }
        sleep 2
    done

    if [ "$status" != "True" ]; then
        echo "  ⚠️  Hibernation didn't confirm within 60s — check: kubectl cnpg status postgis-cluster -n databases"
        had_warnings=true
    fi
fi
echo ""

# --- Step 3: Stop k3s -------------------------------------------------------
# The systemd unit carries Restart=always with a five second delay, so a signal
# delivered straight to the process is reversed shortly after it exits.
# Stopping through systemd suppresses that restart policy, and `disable` clears
# the boot-time enablement in the same call, handing the cluster lifecycle to
# start-cluster.sh from this point on.
#
# A k3s launched by start-cluster.sh has nothing supervising it, so SIGTERM
# alone is sufficient and final.
if [ "$systemd_owned" = true ]; then
    echo "🔻 systemd owns k3s.service — stopping and disabling the unit."
    echo "   k3s will no longer start automatically at boot; use start-cluster.sh."

    if ! sudo systemctl disable --now k3s; then
        echo "❌ ERROR: 'systemctl disable --now k3s' failed."
        echo "   Check: systemctl status k3s"
        exit 1
    fi
else
    echo "Sending graceful stop to k3s (pid $K3S_PID)..."
    sudo kill -TERM "$K3S_PID"
fi

# --- Step 4: Confirm the API server is down ---------------------------------
# Watches the listening socket rather than a single PID, so a process that has
# been restarted by a supervisor still registers as running. If the socket is
# still bound after the timeout, the decision to force-stop is left to the
# administrator.
for i in $(seq 1 15); do
    if ! sudo ss -tlnp 2>/dev/null | grep -q ':6443 '; then
        echo "💤 k3s stopped cleanly."
        # Container processes outlive the API server. k3s-killall.sh reaps the
        # leftover containerd-shim trees and unmounts /run/k3s and
        # /var/lib/kubelet/pods; with the database hibernated and its PVC on
        # local-path they are harmless until the next start.
        [ "$had_warnings" = true ] && exit 1
        exit 0
    fi
    sleep 1
done

echo "⚠️  Port 6443 is still bound 15s after the stop request."
echo "   Check: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
echo "   Force-stop if needed: sudo k3s-killall.sh"
exit 1