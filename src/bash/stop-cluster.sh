#!/bin/bash
#
# stop-cluster.sh: Hibernates CloudNativePG cluster and stops k3s.
#
set -uo pipefail

CLUSTER_NAME=postgis-cluster
CLUSTER_NS=databases
CNPG_NS=cnpg-system
FORCE=false

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --force) FORCE=true ;;
            -h|--help)
                echo "Usage: $0 [--force]"
                echo "  --force   stops k3s without confirmed hibernation"
                echo "            (Check for PostgreSQL crash-recovery on next start)."
                exit 0 ;;
            *) echo "Unknown argument: $arg" >&2; exit 2 ;;
        esac
    done
}

acquire_sudo() {
    if ! sudo -v; then
        echo "❌ ERROR: sudo authentication failed. Cannot inspect or stop k3s."
        exit 1
    fi
}

exit_if_k3s_not_running() {
    if ! systemctl is-active --quiet k3s 2>/dev/null; then
        if systemctl is-enabled --quiet k3s 2>/dev/null; then
            sudo systemctl disable k3s 2>/dev/null || true
        fi
        echo "ℹ️  k3s.service is already inactive."
        exit 0
    fi
}

# Halts execution on error, or continues if --force is set
halt() {
    echo ""
    echo "❌ ERROR: $*"
    if [ "$FORCE" = false ]; then
        echo ""
        echo "   stop-cluster.sh failed, k3s and the database is still running."
        echo "   Review warnings, or re-run with --force to force stop"
        echo "   (Monitor PostgreSQL crash-recovery on the next start)."
        exit 1
    fi
    echo "⚠️  --force applied: continuing..."
    echo ""
}

pause_scheduled_backups() {
    local scheduled_backups
    scheduled_backups=$(kubectl get scheduledbackup -n "$CLUSTER_NS" -o name 2>/dev/null) || scheduled_backups=""
    [ -n "$scheduled_backups" ] || return 0

    echo "⏸️  Pausing scheduled backups..."
    local backup
    for backup in $scheduled_backups; do
        kubectl patch "$backup" -n "$CLUSTER_NS" --type merge -p '{"spec":{"suspend":true}}' \
            || echo "   ⚠️  Failed to pause $backup"
    done
}

# Polls up to 300s for the operator to confirm hibernation, or halts.
wait_for_hibernation() {
    local hibernation_status hibernation_reason hibernation_message
    local condition_raw condition_remainder retries=0
    while [ $retries -lt 60 ]; do
        condition_raw=$(kubectl get cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" \
            -o jsonpath='{range .status.conditions[?(@.type=="cnpg.io/hibernation")]}{.status}|{.reason}|{.message}{end}' \
            2>/dev/null) || condition_raw=""
        hibernation_status=${condition_raw%%|*}
        condition_remainder=${condition_raw#*|}
        hibernation_reason=${condition_remainder%%|*}
        hibernation_message=${condition_remainder#*|}

        if [ "$hibernation_status" = "True" ]; then
            echo "  ✅ Operator reports hibernated: ${hibernation_message:-Cluster has been hibernated}"
            return 0
        fi
        if [ -z "$(kubectl get pods -n "$CLUSTER_NS" -l "cnpg.io/cluster=$CLUSTER_NAME" -o name 2>/dev/null)" ]; then
            echo "  ✅ All instance pods removed."
            return 0
        fi

        sleep 5
        retries=$((retries+1))
        echo "   ...still hibernating... ($((retries * 5))s elapsed, ${hibernation_reason:-no condition written yet})"
    done

    echo ""
    kubectl get pods -n "$CLUSTER_NS" -l "cnpg.io/cluster=$CLUSTER_NAME"
    halt "Hibernation not confirmed within 300s.
   condition status : ${hibernation_status:-<none>}
   condition reason : ${hibernation_reason:-<no condition written>}
   condition message: ${hibernation_message:-<none>}
   Check: kubectl cnpg status $CLUSTER_NAME -n $CLUSTER_NS
          kubectl logs -n $CNPG_NS -l app.kubernetes.io/name=cloudnative-pg --tail=50"
}

attempt_hibernate_postgis() {
    if ! kubectl get --raw='/readyz' &>/dev/null; then
        halt "$CLUSTER_NAME cannot be hibernated, Kubernetes API is unreachable.
   Check: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
        return 0
    fi
    if ! kubectl get cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" &>/dev/null; then
        echo "ℹ️  $CLUSTER_NAME not found. Unable to hibernate."
        return 0
    fi

    echo "💤 Hibernating $CLUSTER_NAME..."
    if ! kubectl annotate cluster "$CLUSTER_NAME" -n "$CLUSTER_NS" --overwrite cnpg.io/hibernation=on; then
        halt "$CLUSTER_NAME hibernation annotation failed."
        return 0
    fi

    pause_scheduled_backups
    wait_for_hibernation
}

hibernate_postgis() {
    attempt_hibernate_postgis
    local exit_code=$?
    echo ""
    return "$exit_code"
}

stop_k3s() {
    echo "🔻 Stopping systemd k3s.service..."
    echo "   Use start-cluster.sh to restart cluster."
    if ! sudo systemctl disable --now k3s; then
        echo "❌ ERROR: 'systemctl disable --now k3s' failed."
        echo "   Check: systemctl status k3s"
        echo "   Force stop manually: sudo systemctl kill --signal=SIGKILL k3s"
        echo "   (or: sudo k3s-killall.sh)"
        exit 1
    fi
    # disable --now blocks until systemd confirms the unit has stopped.
    echo "💤 k3s deactivated."
}

main() {
    export KUBECONFIG="$HOME/.kube/config"

    parse_args "$@"
    acquire_sudo
    exit_if_k3s_not_running

    hibernate_postgis
    stop_k3s
}

main "$@"
