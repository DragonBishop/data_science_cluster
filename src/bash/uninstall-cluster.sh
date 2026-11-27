#!/usr/bin/env bash
#
# uninstall-cluster.sh: Tears down k3s and clears stale local cluster state.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
storage_to_remove=()

acquire_sudo() {
    if ! sudo -v; then
        echo "❌ ERROR: sudo authentication failed. Cannot uninstall k3s."
        exit 1
    fi
}

select_persistent_storage() {
    [[ -t 0 && -t 2 ]] || return 0

    local -a paths=() selected=()
    local config="$REPO_ROOT/infrastructure/cluster-config/storage.yaml"
    local store key path answer

    echo "Deleting SeaweedFS removes all buckets, including database backups, OpenBao snapshots, Loki logs and Zot images."
    for store in SEAWEEDFS PROMETHEUS ALERTMANAGER LOKI ALLOY; do
        key="${store}_HOST_PATH"
        # An empty local patch lets kubectl read the file without a cluster.
        if ! path=$(kubectl patch --local -f "$config" --type=merge -p '{}' -o "jsonpath={.data.$key}") ||
            ! is_storage_path "$path" "${paths[@]}"; then
            echo "⚠️  Invalid or overlapping storage path for $key. Preserving persistent data." >&2
            return 0
        fi
        paths+=("$path")

        read -r -p "Permanently delete local $store storage [$path]? [y/N] " answer || return 0
        [[ $answer == [yY] ]] || continue
        selected+=("$path")
    done
    storage_to_remove=("${selected[@]}")
}

is_storage_path() {
    local path="$1" other
    shift

    # Require a specific absolute directory and reject symlinks and parent references.
    [[ $path == /*/*/* && $path != *[[:cntrl:]]* ]] || return 1
    [[ $path == "$(sudo realpath -m -- "$path")" ]] || return 1

    for other in "$@"; do
        [[ $path == "$other" || $path == "$other/"* || $other == "$path/"* ]] && return 1
    done
    return 0
}

clear_selected_storage() {
    local path
    for path in "${storage_to_remove[@]}"; do
        sudo test -d "$path" || continue
        echo "🧹 Clearing persistent data in $path..."
        sudo find "$path" -xdev -mindepth 1 -delete
    done
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

# Installed by workstation_trust
remove_trust_anchors() {
    local anchor_dir update_command anchor_name
    if [ -d /etc/pki/ca-trust/source/anchors ]; then
        anchor_dir=/etc/pki/ca-trust/source/anchors
        update_command=update-ca-trust
    elif [ -d /etc/ca-certificates/trust-source/anchors ]; then
        anchor_dir=/etc/ca-certificates/trust-source/anchors
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

# Installed by workstation_trust
remove_application_trust() {
    local nss_database nickname
    nss_database="$HOME/.local/share/pki/nssdb"
    [ -d "$HOME/.pki/nssdb" ] && nss_database="$HOME/.pki/nssdb"
    if command -v certutil >/dev/null && [ -f "$nss_database/cert9.db" ]; then
        for nickname in "data-science-cluster Desktop CA" "openbao-local-ca"; do
            if certutil -L -d "sql:$nss_database" -n "$nickname" >/dev/null 2>&1; then
                echo "🧹 Removing $nickname from $nss_database..."
                certutil -D -d "sql:$nss_database" -n "$nickname"
            fi
        done
    fi
    sudo rm -f /var/lib/flatpak/extension/org.mozilla.firefox.systemconfig/"$(uname -m)"/stable/policies/policies.json
}

# workstation_trust's block and the k3s role's Zot line
remove_gateway_hosts() {
    echo "🧹 Removing the Gateway hostnames from /etc/hosts..."
    sudo sed -i '/^# BEGIN data-science-cluster Gateway hostnames$/,/^# END data-science-cluster Gateway hostnames$/d; / # data-science-cluster-zot$/d' /etc/hosts
}

remove_inotify_limits() {
    sudo rm -f /etc/sysctl.d/90-data-science-cluster-inotify.conf
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
    select_persistent_storage
    uninstall_k3s
    remove_gateway_hosts
    clear_cilium_host_files
    remove_inotify_limits
    remove_trust_anchors
    remove_application_trust

    clear_openbao_cache
    clear_terraform_state
    clear_selected_storage

    report_summary
}

main "$@"
