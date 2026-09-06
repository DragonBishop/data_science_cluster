#!/bin/bash
#
# uninstall-cluster.sh: Tears down k3s and clears stale local cluster state.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

acquire_sudo() {
    if ! sudo -v; then
        echo "❌ ERROR: sudo authentication failed. Cannot uninstall k3s."
        exit 1
    fi
}

uninstall_k3s() {
    local uninstaller="/usr/local/bin/k3s-uninstall.sh"
    if [ ! -x "$uninstaller" ]; then
        echo "ℹ️  k3s-uninstall.sh not found; k3s is not installed."
        return 0
    fi

    echo "🔻 Running k3s-uninstall.sh..."
    sudo "$uninstaller"
}

unmount_bpf() {
    local mounts
    mounts=$(mount | grep /sys/fs/bpf | awk '{print $3}') || mounts=""
    [ -n "$mounts" ] || return 0

    echo "🔻 Unmounting leftover BPF filesystems..."
    local m
    for m in $mounts; do
        sudo umount "$m" || echo "   ⚠️  Failed to unmount $m"
    done
}

clear_vault_cache() {
    echo "🧹 Clearing local Vault cache (~/.vault-keys.gpg, ~/.vault-certs)..."
    rm -f "$HOME/.vault-keys.gpg"
    rm -rf "$HOME/.vault-certs"
}

clear_postgres_cache() {
    echo "🧹 Clearing local PostgreSQL cache (~/.postgresql)..."
    rm -rf "$HOME/.postgresql"
}

clear_hubble_cache() {
    echo "🧹 Clearing local Hubble cache (~/.hubble)..."
    rm -rf "$HOME/.hubble"
}

clear_terraform_state() {
    echo "🧹 Clearing orphaned terraform/vault state..."
    rm -f "$REPO_ROOT/terraform/vault/terraform.tfstate" "$REPO_ROOT/terraform/vault/terraform.tfstate.backup"
    rm -rf "$REPO_ROOT/terraform/vault/.terraform"
}

report_summary() {
    echo "✅ Cluster uninstalled and local state cleared."
    echo "   Run 'just bootstrap' to provision a fresh cluster."
}

main() {
    acquire_sudo
    uninstall_k3s
    unmount_bpf

    clear_vault_cache
    clear_postgres_cache
    clear_hubble_cache
    clear_terraform_state

    report_summary
}

main "$@"
