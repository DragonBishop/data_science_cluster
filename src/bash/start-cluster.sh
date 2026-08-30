#!/bin/bash
#
# start-cluster.sh: Starts k3s, unseals the in-cluster Vault, and resumes CNPG cluster.
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
        echo "   Run Ansible playbook: ansible-playbook ansible/playbooks/k3s.yml --tags k3s"
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

wait_for_vault_pod() {
    echo "⏳ Waiting for vault-0 pod to be running..."
    local retries=0
    until [ "$(kubectl get pod vault-0 -n vault -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; do
        sleep 5
        retries=$((retries+1))
        if [ $retries -ge 12 ]; then
            echo "⚠️  vault-0 pod not in Running phase after 60s."
            return 1
        fi
        echo "   ...still waiting for vault-0... ($((retries * 5))s elapsed)"
    done
    return 0
}

# Returns seal status: unsealed, sealed, or unreachable
incluster_seal_state() {
    local exit_code=0
    kubectl exec -n vault vault-0 -- vault status -format=json > /dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo unsealed
    elif [ "$exit_code" -eq 2 ]; then
        echo sealed
    else
        echo unreachable
    fi
}

# Decrypts $1 and writes each key to Vault's unseal endpoint via stdin
decrypt_and_unseal() {
    local keyfile="$1"
    gpg --quiet --decrypt "$keyfile" | while IFS= read -r key; do
        [ -n "$key" ] || continue
        if ! error_output=$(printf '%s\n' "$key" | kubectl exec -i -n vault vault-0 -- vault write -format=json sys/unseal key=- 2>&1 >/dev/null); then
            echo "   ⚠️ Key rejected by Vault: $error_output"
        fi
    done
    return "${PIPESTATUS[0]}"
}

attempt_unseal_vault() {
    local seal_state
    seal_state=$(incluster_seal_state)

    if [ "$seal_state" = unsealed ]; then
        echo "✅ In-cluster Vault already unsealed."
        return 0
    fi

    if [ "$seal_state" = unreachable ]; then
        echo "❌ ERROR: Cannot reach vault-0."
        kubectl exec -n vault vault-0 -- vault status 2>&1 | sed 's/^/   /'
        echo "💡 TROUBLESHOOTING: Is the pod up?  kubectl get pods -n vault"
        return 1
    fi

    echo "🔒 In-cluster Vault is sealed."
    local keyfile="$HOME/.vault-keys.gpg"
    if [ ! -f "$keyfile" ]; then
        echo "❌ ERROR: $keyfile not found. Cannot unseal Vault."
        echo "💡 TROUBLESHOOTING: Did the GPG keyfile get created during 'just bootstrap' (INSTALLATION.md)?."
        return 1
    fi

    echo "🔑 Enter GPG passphrase to decrypt unseal keys:"
    if ! decrypt_and_unseal "$keyfile"; then
        echo "❌ ERROR: GPG decryption failed or was cancelled. Vault remains sealed."
        return 1
    fi

    seal_state=$(incluster_seal_state)
    case "$seal_state" in
        unsealed)
            echo "✅ In-cluster Vault unsealed successfully."
            ;;
        sealed)
            echo "❌ ERROR: Vault still sealed after applying keys from $keyfile."
            return 1
            ;;
        *)
            echo "❌ ERROR: Cannot reach Vault after applying keys from $keyfile."
            kubectl exec -n vault vault-0 -- vault status 2>&1 | sed 's/^/   /'
            return 1
            ;;
    esac
}

unseal_vault() {
    echo "⏳ Checking cluster Vault seal status..."
    wait_for_vault_pod || true

    # Retry transient unreachable state while vault process initializes
    local seal_state retries=0
    while [ $retries -lt 6 ]; do
        seal_state=$(incluster_seal_state)
        [ "$seal_state" != "unreachable" ] && break
        sleep 5
        retries=$((retries+1))
    done

    attempt_unseal_vault
    local exit_code=$?
    echo ""
    return "$exit_code"
}

resume_postgis() {
    kubectl get cluster postgis-cluster -n databases &> /dev/null || return 0

    local hibernation_annotation
    hibernation_annotation=$(kubectl get cluster postgis-cluster -n databases \
        -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}' 2>/dev/null) || hibernation_annotation=""
    [ "$hibernation_annotation" = on ] || return 0

    echo "⏳ Reactivating postgis-cluster from hibernation..."
    local retries=0
    until kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off 2>/dev/null; do
        retries=$((retries+1))
        if [ $retries -ge 6 ]; then
            echo "⚠️  Webhook timed out. CNPG cluster inactive."
            echo "💡 TROUBLESHOOTING: Run manually:"
            echo "   kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off"
            return 1
        fi
        sleep 5
        echo "   ...still reactivating database... ($((retries * 5))s elapsed)"
    done
    echo "✅ postgis-cluster reactivated successfully."
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

report_summary() {
    local had_warnings="$1"
    if [ "$had_warnings" = true ]; then
        echo "⚠️  Cluster startup sequence complete, review warnings."
        echo "   Check Headlamp, 'flux get kustomizations', 'kubectl cnpg status postgis-cluster -n databases'."
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

    unseal_vault || had_warnings=true

    resume_postgis || had_warnings=true
    resume_scheduled_backups

    report_summary "$had_warnings"
}

main "$@"
