#!/usr/bin/env bash
#
# uninstall-cluster.sh: Tears down k3s and clears stale local cluster state.
#
set -euo pipefail

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
        if [ -e "$uninstaller" ] || command -v k3s >/dev/null 2>&1 || systemctl cat k3s.service &>/dev/null; then
            echo "❌ ERROR: k3s appears installed but $uninstaller is missing or not executable."
            echo "   Repair the uninstaller before clearing local recovery material."
            return 1
        fi
        echo "ℹ️  k3s-uninstall.sh not found; k3s is not installed."
        return 0
    fi

    echo "🔻 Running k3s-uninstall.sh..."
    sudo "$uninstaller"
}

clear_cilium_host_files() {
    echo "🧹 Clearing Cilium files that persist across reboots..."
    sudo rm -f /etc/cni/net.d/05-cilium.conflist
    # Restore the CNI configs Cilium set aside
    if [ -d /etc/cni/net.d ]; then
        sudo find /etc/cni/net.d -name '*.cilium_bak' -exec sh -c 'mv "$1" "${1%.cilium_bak}"' _ {} \;
    fi
    sudo rm -f /opt/cni/bin/cilium-cni
    sudo rm -f /etc/sysctl.d/99-zzz-override_cilium.conf
    sudo rm -rf /var/lib/cilium
}

# Installed by the opentofu role's trust prompt
remove_trust_anchors() {
    local anchor_dir update_command anchor_name
    if [ -d /etc/pki/ca-trust/source/anchors ]; then
        anchor_dir=/etc/pki/ca-trust/source/anchors
        update_command=update-ca-trust
    elif [ -d /usr/local/share/ca-certificates ]; then
        anchor_dir=/usr/local/share/ca-certificates
        update_command=update-ca-certificates
    else
        return 0
    fi
    echo "🧹 Removing the cluster's CA certificates from the system trust store..."
    for anchor_name in data-science-cluster-desktop-ca.crt data-science-cluster-openbao-ca.crt; do
        sudo rm -f "$anchor_dir/$anchor_name"
    done
    sudo "$update_command"
}

clear_openbao_cache() {
    echo "🧹 Clearing local OpenBao keys and certs (.local/openbao)..."
    rm -rf "$REPO_ROOT/.local/openbao"
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
    remove_trust_anchors

    clear_openbao_cache
    clear_terraform_state

    report_summary
}

main "$@"
