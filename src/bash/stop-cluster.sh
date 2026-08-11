#!/bin/bash
#
# stop-cluster.sh — Hibernates the CloudNativePG cluster, then stops k3s.
#
# Detects whether k3s is systemd-managed or script-launched and stops it
# accordingly. k3s is not stopped unless hibernation is confirmed; --force
# bypasses that gate and PostgreSQL crash-recovers on the next start.
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
            echo "            If :6443 then stays bound, prompts before running"
            echo "            k3s-killall.sh — never runs it unattended."
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Prints the failure and exits 1, leaving k3s running. With --force, prints and
# returns so the caller continues.
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
# Caches sudo credentials up front so no password prompt appears part-way
# through the hibernation polling loop.
if ! sudo -v; then
    echo "❌ ERROR: sudo authentication failed. Cannot inspect or stop k3s."
    exit 1
fi

# --- Step 2: Identify k3s and its supervisor --------------------------------
# Reads the PID listening on 6443 and whether the k3s systemd unit is active or
# enabled. Step 4 chooses its stop mechanism from these two values. Exits 0 if
# neither is present.
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
# Sets the CNPG hibernation annotation and waits for it to take effect. The
# operator shuts PostgreSQL down and deletes the instance pods, keeping the PVC.
# An unreachable API halts; an absent Cluster is skipped.
if ! kubectl get --raw='/readyz' &>/dev/null; then
    halt "Kubernetes API is unreachable, so $CLUSTER_NAME cannot be hibernated.
   Check: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
elif ! kubectl get cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" &>/dev/null; then
    echo "ℹ️  $CLUSTER_NAME not found — skipping."
else
    # No separate operator-readiness pre-check here: if the operator isn't
    # Available, the hibernation-confirmation poll below surfaces that same
    # failure directly, with a clear message, instead of spending up to 60s
    # confirming it first. Headlamp/`kubectl get pods -n cnpg-system` show
    # operator health live if you want to check before running this at all.
    echo "💤 Hibernating $CLUSTER_NAME..."
    if ! kubectl annotate cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" \
            --overwrite cnpg.io/hibernation=on; then
        halt "Failed to set the hibernation annotation on $CLUSTER_NAME."
    fi
    
    # Captures the list of backups first, avoiding false "none found" messages on command failure.
    sbs=$(kubectl get scheduledbackup -n "$CLUSTER_NS" -o name 2>/dev/null) || sbs=""
    if [ -n "$sbs" ]; then
        echo "⏸️  Pausing scheduled backups..."
        for sb in $sbs; do
            if ! kubectl patch "$sb" -n "$CLUSTER_NS" --type merge -p '{"spec":{"suspend":true}}'; then
                echo "   ⚠️  Failed to pause $sb"
            fi
        done
    fi
    
    # Polls every 5s for up to 300s. Treats either signal as done: the operator
    # writing the cnpg.io/hibernation condition as True, or all instance pods
    # being gone. Retains the last condition status, reason and message for the
    # timeout report.
    #
    # postgis-cluster.yaml sets spec.smartShutdownTimeout to 15s, after which
    # Postgres escalates to a fast shutdown; the remainder of this window covers
    # pod deletion and the operator's own reconciliation.
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
# For a systemd-owned k3s, disables and stops the unit: `stop` alone would be
# undone by Restart=always, and disabling also removes it from boot. Otherwise
# sends SIGTERM to the PID found in Step 2.
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
# Polls port 6443 once a second for 30s. Exits 0 once the socket is released.
# If it is still bound, --force runs k3s-killall.sh; otherwise the script exits
# 1 with the commands to investigate or force the stop.
for i in $(seq 1 30); do
    if ! sudo ss -tlnp 2>/dev/null | grep -q ':6443 '; then
        echo "💤 k3s stopped cleanly."
        # containerd-shim trees and their mounts can outlive the API server.
        # The database PVC is already hibernated at this point.
        exit 0
    fi
    sleep 1
done

echo ""
echo "⚠️  Port 6443 is still bound 30s after the stop request."
if [ "$FORCE" = true ]; then
    # --force skips the hibernation-confirmation gate; it does not by itself
    # authorize k3s-killall.sh, which requires this separate confirmation.
    echo "🔻 --force was supplied, and k3s-killall.sh would force-stop what's left."
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