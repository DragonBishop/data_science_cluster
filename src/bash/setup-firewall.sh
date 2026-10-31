#!/usr/bin/env bash
#
# setup-firewall.sh: Configures host firewall rules for Kubernetes & Cilium.
# Supports Fedora/RHEL (firewalld) and Ubuntu/Debian (ufw).
#
set -euo pipefail

detect_distro() {
    local distro_id=unknown distro_family=unknown

    if [ ! -f /etc/os-release ]; then
        echo "$distro_family $distro_id"
        return 0
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    distro_id="${ID:-unknown}"
    case " ${ID:-} ${ID_LIKE:-} " in
        *" ubuntu "*|*" debian "*) distro_family=debian ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) distro_family=fedora ;;
    esac

    echo "$distro_family $distro_id"
}

# Read the configuration Flux will use, before the cluster exists.
get_cluster_config_value() {
    local config_key="$1" script_directory config_value
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    config_value=$(kubectl kustomize "$script_directory/../../infrastructure/cluster-config" 2>/dev/null \
        | awk -v config_prefix="  $config_key: " 'index($0, config_prefix) == 1 { config_value = substr($0, length(config_prefix) + 1); gsub(/"/, "", config_value); print config_value; exit }') || return 1

    if [ -z "$config_value" ]; then
        echo "❌ $config_key not found in infrastructure/cluster-config (kubectl kustomize)" >&2
        return 1
    fi

    printf '%s\n' "$config_value"
}

require_firewalld() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "❌ firewall-cmd is not installed. Install and enable firewalld first." >&2
        return 1
    fi

    if ! firewall-cmd --state >/dev/null 2>&1; then
        echo "❌ firewalld is inactive. Enable it before configuring the firewall." >&2
        return 1
    fi
}

get_firewalld_lan_zone() {
    local lan_interface lan_zone zone_config
    lan_interface=$(get_cluster_config_value LAN_INTERFACE) || return 1
    ip link show dev "$lan_interface" >/dev/null || return 1
    lan_zone=$(firewall-cmd --get-zone-of-interface="$lan_interface" 2>/dev/null || true)

    if [ -z "$lan_zone" ] || [ "$lan_zone" = "no zone" ]; then
        lan_zone=$(firewall-cmd --get-default-zone) || return 1
    fi

    zone_config=$(firewall-cmd --zone="$lan_zone" --list-all) || return 1
    if echo "$zone_config" | grep -qx '  target: ACCEPT'; then
        echo "❌ LAN interface $lan_interface uses an ACCEPT zone ($lan_zone). Assign it a filtering zone first." >&2
        return 1
    fi

    printf '%s\n' "$lan_zone"
}

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
    echo "   Please refer to docs/INSTALLATION.md for manual firewall configuration."
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
configure_networkmanager_unmanaged() {
    local networkmanager_config=/etc/NetworkManager/conf.d/99-cilium.conf
    [ -d /etc/NetworkManager/conf.d ] || return 0

    echo "   -> Setting unmanaged-devices for cilium and lxc interfaces in NetworkManager..."
    sudo tee "$networkmanager_config" >/dev/null << 'CONF'
[keyfile]
unmanaged-devices=interface-name:cilium*;interface-name:lxc*
CONF
    sudo systemctl reload NetworkManager 2>/dev/null || true
}

configure_firewalld_base_zone() {
    local lan_zone="$1"
    echo "   -> Configuring LAN zone '$lan_zone' (DNS, Gateway HTTPS/PostgreSQL, forward)..."
    # Masquerade is Cilium's job, not firewalld's.
    sudo firewall-cmd --zone="$lan_zone" --add-service=dns --permanent >/dev/null
    sudo firewall-cmd --zone="$lan_zone" --add-port=443/tcp --permanent >/dev/null
    sudo firewall-cmd --zone="$lan_zone" --add-port=5432/tcp --permanent >/dev/null
    sudo firewall-cmd --zone="$lan_zone" --add-forward --permanent >/dev/null
}

remove_firewalld_high_ports() {
    local lan_zone="$1"
    echo "   -> Removing unrestricted high ports from LAN zone '$lan_zone'..."
    sudo firewall-cmd --zone="$lan_zone" --remove-port=1025-65535/tcp --permanent >/dev/null
    sudo firewall-cmd --zone="$lan_zone" --remove-port=1025-65535/udp --permanent >/dev/null
}

firewalld_policy_exists() {
    local policy_name="$1"
    firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -qx "$policy_name"
}

configure_firewalld_policy() {
    local policy_name="$1" ingress_zone="$2" egress_zone="$3"

    if ! firewalld_policy_exists "$policy_name"; then
        sudo firewall-cmd --permanent --new-policy="$policy_name" >/dev/null
    fi
    # ANY cannot be combined with a specific zone. Narrow the old host-input grant.
    if [ "$ingress_zone" != ANY ]; then
        sudo firewall-cmd --permanent --policy="$policy_name" --remove-ingress-zone=ANY >/dev/null
    fi

    sudo firewall-cmd --permanent --policy="$policy_name" --add-ingress-zone="$ingress_zone" >/dev/null
    sudo firewall-cmd --permanent --policy="$policy_name" --add-egress-zone="$egress_zone" >/dev/null
    sudo firewall-cmd --permanent --policy="$policy_name" --set-priority=-1 >/dev/null
    sudo firewall-cmd --permanent --policy="$policy_name" --set-target=ACCEPT >/dev/null
}

configure_firewalld_pod_to_host() {
    echo "   -> Restricting pod-to-host access to the trusted Cilium zone..."
    configure_firewalld_policy k8s-containers-to-host trusted HOST
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
    configure_firewalld_policy k8s-forwarding-in ANY trusted
    configure_firewalld_policy k8s-forwarding-out trusted ANY
    configure_firewalld_policy k8s-forwarding-host HOST ANY
}

reload_firewalld() {
    echo "   -> Reloading firewalld..."
    sudo firewall-cmd --reload >/dev/null
}

setup_fedora_firewall() {
    local pod_cidr="$1" lan_zone
    require_firewalld || return 1
    lan_zone=$(get_firewalld_lan_zone) || return 1

    echo "🔥 Configuring firewalld for Kubernetes & Cilium..."
    configure_networkmanager_unmanaged
    remove_firewalld_high_ports "$lan_zone"
    configure_firewalld_base_zone "$lan_zone"
    configure_firewalld_trusted_zone "$pod_cidr"
    configure_firewalld_pod_to_host
    cleanup_legacy_firewalld_policies
    configure_firewalld_forwarding_policies
    reload_firewalld
    echo "✅ firewalld configured and reloaded successfully."
}

# Dynamic dispatch
dispatch_firewall_setup() {
    local distro_family="$1" distro_id="$2" pod_cidr="$3"
    local setup_function="setup_${distro_family}_firewall"

    if ! declare -f "$setup_function" >/dev/null 2>&1; then
        print_unsupported_os "$distro_family" "$distro_id"
        return 0
    fi

    "$setup_function" "$pod_cidr"
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
    pod_cidr=$(get_cluster_config_value POD_CIDR)
    print_detected_os "$distro_family" "$distro_id"
    acquire_sudo
    dispatch_firewall_setup "$distro_family" "$distro_id" "$pod_cidr"
    print_next_steps
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
