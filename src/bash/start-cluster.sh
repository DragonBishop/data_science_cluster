#!/usr/bin/env bash
#
# start-cluster.sh: Starts k3s, checks the in-cluster OpenBao, and resumes CNPG cluster.
#
set -eu

configure_kubeconfig() {
    local kubeconfig_dest="$HOME/.kube/config"
    mkdir -p "$(dirname "$kubeconfig_dest")"
    export KUBECONFIG="$kubeconfig_dest"
}

start_k3s_service() {
    if systemctl is-active --quiet k3s 2>/dev/null; then
        echo "ℹ️  k3s is running via systemd."
    elif systemctl cat k3s.service &>/dev/null; then
        echo "🚀 Starting k3s via systemd..."
        sudo systemctl start k3s
    else
        echo "❌ ERROR: no k3s.service systemd unit found."
        echo "   Run Ansible playbook: just bootstrap --tags k3s"
        exit 1
    fi
}
#
k3s_alive() {
    systemctl is-active --quiet k3s 2>/dev/null
}

wait_for_api() {
    echo "⏳ Waiting for Kubernetes API to become available..."
    local retries=0
    until kubectl get nodes &> /dev/null; do
        if ! k3s_alive; then
            echo "❌ ERROR: k3s died during startup."
            echo "Check logs: sudo tail -n 50 /var/log/k3s.log   (or: journalctl -u k3s -n 50)"
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
}

wait_for_node_ready() {
    local retries=0
    until kubectl get nodes | grep -q " Ready"; do
        if ! k3s_alive; then
            echo "❌ ERROR: k3s died while waiting for node Ready."
            exit 1
        fi
        sleep 5
        retries=$((retries+1))
        if [ $retries -ge 60 ]; then
            echo "❌ ERROR: Node not Ready within 5 minutes."
            echo "💡 TROUBLESHOOTING: CNI (Cilium) needed for node to report Ready."
            echo "   1. Is Cilium installed?  cilium status --wait"
            echo "   2. On a first-time build, install it now:"
            echo "      helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \\"
            echo "        --version <chart-version> --namespace kube-system -f infrastructure/cilium/cilium-values.yaml"
            exit 1
        fi
        echo "   ...still waiting for node... ($((retries * 5))s elapsed)"
    done
    echo "✅ Node is Ready."
    echo ""
}

# Waits until bao answers inside openbao-0; the pod phase is stale right after boot
wait_for_openbao_process() {
    echo "⏳ Waiting for OpenBao to respond in openbao-0..."
    local retries=0
    until [ "$(incluster_seal_state)" != unreachable ]; do
        sleep 5
        retries=$((retries+1))
        if [ $retries -ge 36 ]; then
            echo "⚠️  OpenBao did not respond within 3 minutes."
            return 1
        fi
        echo "   ...still waiting for OpenBao... ($((retries * 5))s elapsed)"
    done
    return 0
}

# Returns seal status: unsealed, sealed, or unreachable
incluster_seal_state() {
    local exit_code=0
    kubectl exec -n openbao openbao-0 -- bao status -format=json > /dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo unsealed
    elif [ "$exit_code" -eq 2 ]; then
        echo sealed
    else
        echo unreachable
    fi
}

# OpenBao unseals itself from its static seal key; this only reports whether it did
check_openbao() {
    wait_for_openbao_process || true

    local seal_state
    seal_state=$(incluster_seal_state)

    case "$seal_state" in
        unsealed)
            echo "✅ In-cluster OpenBao unsealed itself."
            ;;
        sealed)
            echo "❌ ERROR: In-cluster OpenBao is still sealed. It should unseal itself from Secret openbao-seal-key."
            echo "💡 TROUBLESHOOTING: kubectl get secret openbao-seal-key -n openbao"
            echo "                    kubectl logs openbao-0 -n openbao"
            return 1
            ;;
        *)
            echo "❌ ERROR: Cannot reach openbao-0."
            kubectl exec -n openbao openbao-0 -- bao status 2>&1 | sed 's/^/   /'
            echo "💡 TROUBLESHOOTING: Is the pod up?  kubectl get pods -n openbao"
            return 1
            ;;
    esac
}

resume_databases() {
    kubectl get cluster postgres-cluster -n databases &> /dev/null || return 0

    local hibernation_annotation
    hibernation_annotation=$(kubectl get cluster postgres-cluster -n databases \
        -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}' 2>/dev/null) || hibernation_annotation=""
    [ "$hibernation_annotation" = on ] || return 0

    echo "⏳ Reactivating postgres-cluster from hibernation..."
    local retries=0
    until kubectl annotate cluster postgres-cluster -n databases --overwrite cnpg.io/hibernation=off 2>/dev/null; do
        retries=$((retries+1))
        if [ $retries -ge 6 ]; then
            echo "⚠️  Webhook timed out. CNPG cluster inactive."
            echo "💡 TROUBLESHOOTING: Run manually:"
            echo "   kubectl annotate cluster postgres-cluster -n databases --overwrite cnpg.io/hibernation=off"
            return 1
        fi
        sleep 5
        echo "   ...still reactivating database... ($((retries * 5))s elapsed)"
    done
    echo "✅ postgres-cluster reactivated successfully."
}

resume_scheduled_backups() {
    local scheduled_backups
    scheduled_backups=$(kubectl get scheduledbackup -n databases -o name 2>/dev/null) || scheduled_backups=""
    [ -n "$scheduled_backups" ] || return 0

    echo "▶️  Resuming scheduled backups..."
    local backup
    for backup in $scheduled_backups; do
        kubectl patch "$backup" -n databases --type merge -p '{"spec":{"suspend":false}}' 2>/dev/null || true
    done
    echo ""

}

# Runs preflight's version checks in a subshell, keeping preflight's shell options out of this script
check_host_tools() {
    echo "== Host tools =="
    (
        # shellcheck source=src/bash/preflight.sh
        source "$(dirname "${BASH_SOURCE[0]}")/preflight.sh"
        check_kubectl_versions
    )
}

report_summary() {
    local had_warnings="$1"
    if [ "$had_warnings" = true ]; then
        echo "⚠️  Cluster startup sequence complete, review warnings."
        echo "   Check Headlamp, 'flux get kustomizations', 'kubectl cnpg status postgres-cluster -n databases'."
        exit 1
    else
        echo "✅ Cluster startup sequence complete."
        echo "   Check Headlamp, use 'flux get kustomizations' to monitor reconciliation."
    fi
}

main() {
    local had_warnings=false

    configure_kubeconfig
    start_k3s_service
    wait_for_api
    wait_for_node_ready

    check_openbao || had_warnings=true
    echo ""

    resume_databases || had_warnings=true
    resume_scheduled_backups

    check_host_tools || had_warnings=true
    echo ""

    report_summary "$had_warnings"
}

main "$@"
