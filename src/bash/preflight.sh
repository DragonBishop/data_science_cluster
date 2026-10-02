#!/bin/bash
#
# preflight.sh: Read-only host readiness checks.
#
set -euo pipefail

check_host_tooling() {
    echo "🔎 Running preflight checks..."
    echo ""
    echo "== Host tooling =="
    local has_errors=false
    local bin

    for bin in tofu helm flux gh gpg openssl python3 just; do
        if command -v "$bin" >/dev/null 2>&1; then
            echo "✅ $bin"
        else
            echo "❌ $bin not found. See INSTALLATION.md Requirements."
            has_errors=true
        fi
    done

    [ "$has_errors" = false ]
}

get_cluster_config_value() {
    local key="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    grep "^  $key:" "$script_dir/../../infrastructure/cluster-config/cluster-config.yaml" | head -n 1 | awk -F'"' '{print $2}'
}

get_minor_version() {
    local version="$1"
    version="${version#v}"
    version="${version#*.}"
    printf '%s\n' "${version%%.*}"
}

check_kubectl_tooling() {
    echo "== kubectl and plugins =="
    local has_errors=false

    if command -v kubectl >/dev/null 2>&1; then
        echo "✅ kubectl"
    else
        echo "❌ kubectl not found. See INSTALLATION.md Requirements."
        has_errors=true
    fi

    if command -v kubectl >/dev/null 2>&1 && kubectl cnpg version >/dev/null 2>&1; then
        echo "✅ kubectl cnpg"
    else
        echo "❌ kubectl cnpg plugin not found. See INSTALLATION.md Requirements."
        has_errors=true
    fi

    [ "$has_errors" = false ]
}

# Versions must match the cluster: kubectl within one minor of k3s, the cnpg plugin equal to the operator.
check_kubectl_versions() {
    local has_warnings=false
    local kubectl_version k3s_version kubectl_minor k3s_minor minor_gap
    local chart_version expected_plugin_version plugin_version

    kubectl_version=$(kubectl version --client 2>/dev/null | awk '/Client Version/ {print $3}')
    k3s_version=$(get_cluster_config_value K3S_VERSION)
    kubectl_minor=$(get_minor_version "$kubectl_version")
    k3s_minor=$(get_minor_version "$k3s_version")
    minor_gap=$(( kubectl_minor > k3s_minor ? kubectl_minor - k3s_minor : k3s_minor - kubectl_minor ))
    if [ "$minor_gap" -le 1 ]; then
        echo "✅ kubectl $kubectl_version is within one minor version of k3s $k3s_version"
    else
        echo "⚠️  kubectl $kubectl_version is more than one minor version from k3s $k3s_version"
        has_warnings=true
    fi

    chart_version=$(get_cluster_config_value CNPG_VERSION)
    expected_plugin_version=$(helm show chart cloudnative-pg --repo https://cloudnative-pg.github.io/charts \
        --version "$chart_version" 2>/dev/null | awk '/^appVersion:/ {print $2}')
    plugin_version=$(kubectl cnpg version 2>/dev/null | sed -n 's/.*Version:\([0-9.]*\).*/\1/p')
    if [ -z "$expected_plugin_version" ]; then
        echo "⚠️  Could not read the CNPG operator version for chart $chart_version (helm show chart failed)"
        has_warnings=true
    elif [ "$plugin_version" = "$expected_plugin_version" ]; then
        echo "✅ kubectl cnpg $plugin_version matches the CNPG operator"
    else
        echo "⚠️  kubectl cnpg ${plugin_version:-unknown} differs from the CNPG operator $expected_plugin_version (chart $chart_version)"
        has_warnings=true
    fi
    echo ""

    [ "$has_warnings" = false ]
}

check_database_client() {
    if command -v psql >/dev/null 2>&1; then
        echo "✅ psql"
    else
        echo "⚠️  psql not found (only needed later for 'just db-connect'). See INSTALLATION.md Requirements."
        echo ""
        return 1
    fi
    echo ""
}

check_github_auth() {
    echo "== GitHub Authentication =="
    if [ -n "${GITHUB_APP_ID:-}" ]; then
        echo "✅ GitHub App (ID: $GITHUB_APP_ID) configured"
        echo ""
        return 0
    elif gh auth status >/dev/null 2>&1; then
        echo "✅ gh authenticated (fallback)"
        echo ""
        return 0
    else
        echo "❌ No GitHub App provided and gh not authenticated. See INSTALLATION.md."
        echo ""
        return 1
    fi
}

detect_distro() {
    local distro_id="unknown"
    local distro_family="unknown"

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        distro_id="${ID:-unknown}"
        case " ${ID:-} ${ID_LIKE:-} " in
            *" ubuntu "*|*" debian "*) distro_family="debian" ;;
            *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) distro_family="fedora" ;;
        esac
    fi

    printf '%s %s\n' "$distro_family" "$distro_id"
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

check_debian_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo "⚠️  ufw not found on a Debian/Ubuntu host (expected on this distro family). Verify firewall state manually (see INSTALLATION.md Requirements)."
        return 1
    fi

    if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "✅ ufw present and inactive: no rules to check"
        return 0
    fi

    local fwd_policy ufw_rules missing=() iface
    fwd_policy=$(grep -E '^DEFAULT_FORWARD_POLICY' /etc/default/ufw 2>/dev/null | cut -d'"' -f2)
    ufw_rules=$(sudo ufw status verbose 2>/dev/null)

    for iface in cilium_host cilium_net cilium_vxlan "lxc+"; do
        echo "$ufw_rules" | grep -q "ALLOW IN.*on $iface" || missing+=("$iface")
    done

    if [ "$fwd_policy" != "ACCEPT" ] || [ ${#missing[@]} -gt 0 ]; then
        echo "⚠️  ufw is active but not configured for Cilium (see INSTALLATION.md Requirements)."
        [ "$fwd_policy" != "ACCEPT" ] && echo "   - DEFAULT_FORWARD_POLICY is '${fwd_policy:-unset}', expected ACCEPT"
        [ ${#missing[@]} -gt 0 ] && echo "   - missing ALLOW IN rules for: ${missing[*]}"
        return 1
    fi

    echo "✅ ufw active and configured for Cilium"
    return 0
}

check_fedora_firewall() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "⚠️  firewall-cmd not found on a Fedora/RHEL host (expected on this distro family). Verify firewall state manually (see INSTALLATION.md Requirements)."
        return 1
    fi

    if ! firewall-cmd --state >/dev/null 2>&1; then
        echo "✅ firewalld present and inactive: no rules to check"
        return 0
    fi

    local zone zone_info trusted_info pod_cidr missing=()
    zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "FedoraWorkstation")
    zone_info=$(firewall-cmd --zone="$zone" --list-all 2>/dev/null)
    trusted_info=$(firewall-cmd --zone=trusted --list-all 2>/dev/null)
    pod_cidr=$(get_cluster_pod_cidr)

    echo "$zone_info" | grep -q "forward: yes" || missing+=("forward: yes in zone '$zone'")
    echo "$zone_info" | grep -q "443/tcp" || missing+=("443/tcp port in zone '$zone'")

    if ! echo "$zone_info" | grep -qE "(services:.*\bdns\b|53/(tcp|udp))" && ! echo "$trusted_info" | grep -qE "(services:.*\bdns\b|53/(tcp|udp))"; then
        missing+=("dns service in zone '$zone' or 'trusted'")
    fi

    if ! echo "$trusted_info" | grep -q "$pod_cidr"; then
        missing+=("$pod_cidr source in 'trusted' zone")
    fi

    local policies
    policies=$(firewall-cmd --get-policies 2>/dev/null || true)
    echo "$policies" | grep -q "k8s-forwarding-in" || missing+=("policy 'k8s-forwarding-in'")
    echo "$policies" | grep -q "k8s-forwarding-out" || missing+=("policy 'k8s-forwarding-out'")
    echo "$policies" | grep -q "k8s-forwarding-host" || missing+=("policy 'k8s-forwarding-host'")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "⚠️  firewalld is active but missing required rules/policies for Kubernetes/Cilium (see INSTALLATION.md Requirements):"
        for item in "${missing[@]}"; do
            echo "   - missing $item"
        done
        echo "   Run the commands in INSTALLATION.md under 'Host Firewall Configuration' to apply them."
        return 1
    fi

    echo "✅ firewalld active and configured for Cilium (zone: $zone, trusted zone and k8s policies configured)"
    return 0
}

check_host_firewall() {
    echo "== Host firewall =="
    local distro_info distro_family distro_id rc=0
    distro_info=$(detect_distro)
    distro_family="${distro_info%% *}"
    distro_id="${distro_info#* }"

    case "$distro_family" in
        debian)
            check_debian_firewall || rc=$?
            ;;
        fedora)
            check_fedora_firewall || rc=$?
            ;;
        *)
            echo "⚠️  Unrecognized distro ('$distro_id'): firewall check is only verified for Ubuntu/Debian and Fedora/RHEL. Skipping automated check; verify manually per INSTALLATION.md Requirements."
            rc=1
            ;;
    esac
    echo ""
    return "$rc"
}

check_reserved_ips() {
    echo "== Reserved IP range (192.0.2.240-192.0.2.250) =="
    local has_warnings=false
    local ip

    for ip in 192.0.2.240 192.0.2.242; do
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            echo "⚠️  $ip already answers on the LAN: check for a DHCP conflict (see INSTALLATION.md Requirements)."
            has_warnings=true
        else
            echo "✅ $ip free"
        fi
    done
    echo ""

    [ "$has_warnings" = false ]
}

report_summary() {
    local had_errors="$1"
    local had_warnings="$2"

    if [ "$had_errors" = true ]; then
        echo "❌ Preflight failed: resolve the errors above before bootstrapping."
        exit 1
    elif [ "$had_warnings" = true ]; then
        echo "⚠️  Preflight passed with warnings: review above."
        exit 0
    else
        echo "✅ Preflight passed."
        exit 0
    fi
}

main() {
    local had_errors=false
    local had_warnings=false

    check_host_tooling || had_errors=true
    check_database_client || had_warnings=true
    if check_kubectl_tooling; then
        check_kubectl_versions || had_warnings=true
    else
        had_errors=true
        echo ""
    fi
    check_github_auth || had_errors=true

    check_host_firewall || had_warnings=true

    check_reserved_ips || had_warnings=true

    report_summary "$had_errors" "$had_warnings"
}

main "$@"
