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

clear_cilium_host_files() {
    echo "🧹 Clearing Cilium files that persist across reboots..."
    sudo rm -f /etc/cni/net.d/05-cilium.conflist
    # Restore CNI configs Cilium set aside, as its own post-uninstall-cleanup does
    sudo find /etc/cni/net.d -name '*.cilium_bak' -exec sh -c 'mv "$1" "${1%.cilium_bak}"' _ {} \;
    sudo rm -f /opt/cni/bin/cilium-cni
    sudo rm -f /etc/sysctl.d/99-zzz-override_cilium.conf
    sudo rm -rf /var/lib/cilium
}

clear_openbao_cache() {
    echo "🧹 Clearing local OpenBao keys and certs (.local/openbao)..."
    rm -rf "$REPO_ROOT/.local/openbao"
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
    echo "🧹 Clearing orphaned terraform/openbao state..."
    rm -f "$REPO_ROOT/terraform/openbao/terraform.tfstate" "$REPO_ROOT/terraform/openbao/terraform.tfstate.backup"
    rm -rf "$REPO_ROOT/terraform/openbao/.terraform"
}

report_summary() {
    echo "✅ Cluster uninstalled and local state cleared."
    echo "⚠️  Reboot before 'just bootstrap': Cilium's BPF programs stay attached in the kernel until then."
}

main() {
    acquire_sudo
    uninstall_k3s
    clear_cilium_host_files

    clear_openbao_cache
    clear_postgres_cache
    clear_hubble_cache
    clear_terraform_state

    report_summary
}

main "$@"
