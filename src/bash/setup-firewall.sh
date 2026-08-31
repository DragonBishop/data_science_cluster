#!/bin/bash
#
# setup-firewall.sh: Configures host firewall rules for Kubernetes & Cilium.
# Supports Fedora/RHEL (firewalld) and Ubuntu/Debian (ufw).
#
set -euo pipefail

# CLI options
parse_args() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            -h|--help)
                echo "Usage: $0 [options]"
                echo ""
                echo "Configures host firewall rules for Kubernetes and Cilium."
                echo "Supports Fedora/RHEL (firewalld) and Ubuntu/Debian (ufw)."
                echo ""
                echo "Options:"
                echo "  -h, --help    Show this help message"
                exit 0
                ;;
            *)
                echo "❌ ERROR: Unknown argument: $argument" >&2
                exit 2
                ;;
        esac
    done
}

# Prerequisites
acquire_sudo() {
    if ! sudo -v; then
        echo "❌ ERROR: sudo authentication failed. Cannot configure host firewall."
        exit 1
    fi
}

detect_distro() {
    local distro_id="unknown"
    local distro_family="unknown"

    if [ ! -f /etc/os-release ]; then
        echo "$distro_family $distro_id"
        return 0
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    distro_id="${ID:-unknown}"
    case " ${ID:-} ${ID_LIKE:-} " in
        *" ubuntu "*|*" debian "*) distro_family="debian" ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) distro_family="fedora" ;;
    esac

    echo "$distro_family $distro_id"
}

get_cluster_pod_cidr() {
    local script_dir
    local config_file
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    config_file="$script_dir/../../infrastructure/cluster-config/cluster-config.yaml"

    if [ -f "$config_file" ]; then
        grep 'POD_CIDR:' "$config_file" | head -n 1 | awk -F'"' '{print $2}'
        return 0
    fi

    echo "10.42.0.0/16"
}

print_header() {
    echo "🔒 Host Firewall Setup"
}

print_detected_os() {
    local distro_family="$1"
    local distro_id="$2"
    echo "   Detected OS family: $distro_family ($distro_id)"
}

print_unsupported_os() {
    local distro_family="$1"
    local distro_id="$2"
    echo "⚠️  Unsupported or unrecognized OS family '$distro_family' ($distro_id)."
    echo "   Please refer to INSTALLATION.md for manual firewall configuration."
}

print_next_steps() {
    echo ""
    echo "💡 Next step: Run 'just preflight' to verify host readiness."
}

# Ubuntu / Debian (UFW)
ufw_is_active() {
    sudo ufw status 2>/dev/null | grep -q "Status: active"
}

configure_ufw_default_forward() {
    local target_config_file="/etc/default/ufw"
    echo "   -> Setting DEFAULT_FORWARD_POLICY=\"ACCEPT\" in $target_config_file..."

    if [ ! -f "$target_config_file" ]; then
        echo "⚠️  $target_config_file not found, skipping default forward policy edit."
        return 0
    fi

    if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' "$target_config_file"; then
        sudo sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' "$target_config_file"
        return 0
    fi

    if ! grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' "$target_config_file"; then
        echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' | sudo tee -a "$target_config_file" >/dev/null
    fi
}

configure_ufw_ports() {
    echo "   -> Allowing ingress port 443/tcp (Gateway API)..."
    sudo ufw allow 443/tcp comment "k8s gateway api" >/dev/null
}

configure_ufw_interfaces() {
    local virtual_interface
    echo "   -> Allowing ingress traffic on Cilium virtual interfaces..."
    for virtual_interface in cilium_host cilium_net cilium_vxlan "lxc+"; do
        echo "      - allowing in on $virtual_interface"
        sudo ufw allow in on "$virtual_interface" comment "cilium $virtual_interface" >/dev/null
    done
}

configure_ufw_cluster_subnets() {
    local pod_cidr="$1"
    echo "   -> Allowing cluster pod ($pod_cidr) routing..."
    sudo ufw allow from "$pod_cidr" comment "k8s pod cidr" >/dev/null
    sudo ufw allow to "$pod_cidr" comment "k8s pod cidr" >/dev/null
}

reload_ufw() {
    echo "   -> Reloading ufw..."
    sudo ufw reload >/dev/null
}

setup_debian_firewall() {
    local pod_cidr="$1"

    if ! command -v ufw >/dev/null 2>&1; then
        echo "ℹ️  ufw is not installed on this system. Skipping."
        return 0
    fi

    if ! ufw_is_active; then
        echo "ℹ️  ufw is inactive. No firewall rules required."
        return 0
    fi

    echo "🔥 Configuring UFW for Kubernetes & Cilium..."
    configure_ufw_default_forward
    configure_ufw_ports
    configure_ufw_interfaces
    configure_ufw_cluster_subnets "$pod_cidr"
    reload_ufw
    echo "✅ UFW configured and reloaded successfully."
}

# Fedora / RHEL (firewalld)
firewalld_is_active() {
    systemctl is-active --quiet firewalld 2>/dev/null
}

configure_networkmanager_unmanaged() {
    local nm_conf="/etc/NetworkManager/conf.d/99-cilium.conf"
    if [ -d "/etc/NetworkManager/conf.d" ]; then
        echo "   -> Setting unmanaged-devices for cilium and lxc interfaces in NetworkManager..."
        sudo tee "$nm_conf" >/dev/null << 'CONF'
[keyfile]
unmanaged-devices=interface-name:cilium*;interface-name:lxc*
CONF
        sudo systemctl reload NetworkManager 2>/dev/null || true
    fi
}

configure_firewalld_base_zone() {
    local active_zone="$1"
    echo "   -> Configuring base zone '$active_zone' (DNS, 443/tcp, forward)..."
    # Masquerade is Cilium's job, not firewalld's.
    sudo firewall-cmd --zone="$active_zone" --add-service=dns --permanent >/dev/null
    sudo firewall-cmd --zone="$active_zone" --add-port=443/tcp --permanent >/dev/null
    sudo firewall-cmd --zone="$active_zone" --add-forward --permanent >/dev/null
}

configure_firewalld_trusted_zone() {
    local pod_cidr="$1"
    echo "   -> Configuring 'trusted' zone (DNS, pod CIDR $pod_cidr, Cilium interfaces)..."
    sudo firewall-cmd --zone=trusted --add-service=dns --permanent >/dev/null
    sudo firewall-cmd --zone=trusted --add-source="$pod_cidr" --permanent >/dev/null
    sudo firewall-cmd --zone=trusted --add-interface=cilium_host --permanent >/dev/null
    sudo firewall-cmd --zone=trusted --add-interface=cilium_net --permanent >/dev/null
    sudo firewall-cmd --zone=trusted --add-interface=cilium_vxlan --permanent >/dev/null
}

cleanup_legacy_firewalld_policies() {
    local legacy_policy
    for legacy_policy in k8s-host-to-pods k8s-pods-to-host k8s-pods-to-wan; do
        if firewall-cmd --get-policies 2>/dev/null | grep -q "$legacy_policy"; then
            echo "   -> Removing legacy policy '$legacy_policy'..."
            sudo firewall-cmd --permanent --delete-policy="$legacy_policy" >/dev/null 2>&1 || true
        fi
    done
}

configure_firewalld_forwarding_policies() {
    echo "   -> Configuring container forwarding policies (priority -1: ANY <-> trusted, HOST -> ANY)..."

    # Ingress policy: ANY -> trusted
    sudo firewall-cmd --permanent --new-policy=k8s-forwarding-in 2>/dev/null || true
    sudo firewall-cmd --permanent --policy=k8s-forwarding-in --set-priority=-1 >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-in --add-ingress-zone=ANY >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-in --add-egress-zone=trusted >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-in --set-target=ACCEPT >/dev/null

    # Egress policy: trusted -> ANY
    sudo firewall-cmd --permanent --new-policy=k8s-forwarding-out 2>/dev/null || true
    sudo firewall-cmd --permanent --policy=k8s-forwarding-out --set-priority=-1 >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-out --add-ingress-zone=trusted >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-out --add-egress-zone=ANY >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-out --set-target=ACCEPT >/dev/null

    # Host-to-pod policy: HOST -> ANY
    sudo firewall-cmd --permanent --new-policy=k8s-forwarding-host 2>/dev/null || true
    sudo firewall-cmd --permanent --policy=k8s-forwarding-host --set-priority=-1 >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-host --add-ingress-zone=HOST >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-host --add-egress-zone=ANY >/dev/null
    sudo firewall-cmd --permanent --policy=k8s-forwarding-host --set-target=ACCEPT >/dev/null
}

reload_firewalld() {
    echo "   -> Reloading firewalld..."
    sudo firewall-cmd --reload >/dev/null
}

setup_fedora_firewall() {
    local pod_cidr="$1"

    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "ℹ️  firewall-cmd is not installed on this system. Skipping."
        return 0
    fi

    if ! firewalld_is_active; then
        echo "ℹ️  firewalld is inactive. No firewall rules required."
        return 0
    fi

    local active_zone
    active_zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "FedoraWorkstation")

    echo "🔥 Configuring firewalld for Kubernetes & Cilium..."
    configure_networkmanager_unmanaged
    configure_firewalld_base_zone "$active_zone"
    configure_firewalld_trusted_zone "$pod_cidr"
    cleanup_legacy_firewalld_policies
    configure_firewalld_forwarding_policies
    reload_firewalld
    echo "✅ firewalld configured and reloaded successfully."
}

# Dynamic dispatch
dispatch_firewall_setup() {
    local distro_family="$1"
    local distro_id="$2"
    local pod_cidr="$3"
    local target_handler="setup_${distro_family}_firewall"

    if declare -f "$target_handler" >/dev/null 2>&1; then
        "$target_handler" "$pod_cidr"
        return 0
    fi

    print_unsupported_os "$distro_family" "$distro_id"
}

# Main entrypoint
main() {
    local distro_info
    local distro_family
    local distro_id
    local pod_cidr

    parse_args "$@"
    print_header
    distro_info=$(detect_distro)
    distro_family="${distro_info%% *}"
    distro_id="${distro_info#* }"
    pod_cidr=$(get_cluster_pod_cidr)
    print_detected_os "$distro_family" "$distro_id"
    acquire_sudo
    dispatch_firewall_setup "$distro_family" "$distro_id" "$pod_cidr"
    print_next_steps
}

main "$@"
