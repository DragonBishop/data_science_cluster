#!/usr/bin/env bash
#
# preflight.sh: Read-only host readiness checks.
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

get_project_name() {
    case "$1" in
        tofu) echo "OpenTofu" ;;
        helm) echo "Helm" ;;
        flux) echo "the Flux CLI" ;;
        gh) echo "the GitHub CLI (gh)" ;;
        gpg) echo "GnuPG" ;;
        git) echo "Git" ;;
        kubectl-cnpg) echo "the CloudNativePG kubectl plugin (kubectl-cnpg)" ;;
        tkn) echo "the Tekton CLI (tkn)" ;;
        *) echo "$1" ;;
    esac
}

# The install commands from docs/INSTALLATION.md Requirements, for the detected distro family
print_install_command() {
    local tool="$1"
    local distro_info distro_family distro_id
    distro_info=$(detect_distro)
    distro_family="${distro_info%% *}"
    distro_id="${distro_info#* }"

    if [ "$distro_family" = unknown ]; then
        echo "   Preflight has no install command for '$distro_id'. Install $(get_project_name "$tool") following its documentation for your distribution."
        return 0
    fi

    echo "   Install it with:"
    case "$tool:$distro_family" in
        tofu:*)
            cat <<'EOF'
   curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
   chmod +x install-opentofu.sh
   sudo ./install-opentofu.sh --install-method standalone --opentofu-version 1.13.1
   rm install-opentofu.sh
EOF
            ;;
        helm:*)
            cat <<'EOF'
   curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
   chmod +x get_helm.sh
   ./get_helm.sh
   rm get_helm.sh
EOF
            ;;
        flux:*)
            echo "   curl -s https://fluxcd.io/install.sh | sudo FLUX_VERSION=2.10.0 bash"
            ;;
        uv:*)
            echo "   curl -LsSf https://astral.sh/uv/install.sh | sh"
            ;;
        kubectl:*)
            cat <<'EOF'
   KUBECTL_VERSION=v1.37.1
   KUBECTL_ARCH=amd64
   if [ "$(uname -m)" = "aarch64" ]; then KUBECTL_ARCH=arm64; fi
   curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"
   sudo install -m 0755 kubectl /usr/local/bin/kubectl
   rm kubectl
EOF
            ;;
        gh:debian)
            cat <<'EOF'
   curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /usr/share/keyrings/githubcli-archive-keyring.gpg > /dev/null
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
   sudo apt update && sudo apt install -y gh
EOF
            ;;
        gh:fedora)
            cat <<'EOF'
   sudo dnf install -y 'dnf-command(config-manager)' 2>/dev/null || sudo dnf install -y dnf-plugins-core
   sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
   sudo dnf install -y gh
EOF
            ;;
        gpg:debian) echo "   sudo apt update && sudo apt install -y gnupg" ;;
        gpg:fedora) echo "   sudo dnf install -y gnupg2" ;;
        git:debian) echo "   sudo apt update && sudo apt install -y git" ;;
        git:fedora) echo "   sudo dnf install -y git" ;;
        just:debian) echo "   sudo apt update && sudo apt install -y just" ;;
        just:fedora) echo "   sudo dnf install -y just" ;;
        fzf:debian) echo "   sudo apt update && sudo apt install -y fzf" ;;
        fzf:fedora) echo "   sudo dnf install -y fzf" ;;
        tkn:debian)
            cat <<'EOF'
   sudo apt update && sudo apt install -y gnupg
   sudo mkdir -p /etc/apt/keyrings/
   sudo gpg --no-default-keyring --keyring /etc/apt/keyrings/tektoncd.gpg --keyserver keyserver.ubuntu.com --recv-keys 3EFE0E0A2F2F60AA
   echo "deb [signed-by=/etc/apt/keyrings/tektoncd.gpg] http://ppa.launchpad.net/tektoncd/cli/ubuntu eoan main" | sudo tee /etc/apt/sources.list.d/tektoncd-ubuntu-cli.list
   sudo apt update && sudo apt install -y tektoncd-cli
EOF
            ;;
        tkn:fedora)
            cat <<'EOF'
   sudo dnf copr enable -y krouma/kubernetes
   sudo dnf install -y tektoncd-cli
EOF
            ;;
        kubectl-cnpg:debian)
            cat <<'EOF'
   CNPG_PLUGIN_VERSION=1.30.1
   CNPG_ARCH=x86_64
   if [ "$(uname -m)" = "aarch64" ]; then CNPG_ARCH=arm64; fi
   curl -LO "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_PLUGIN_VERSION}/kubectl-cnpg_${CNPG_PLUGIN_VERSION}_linux_${CNPG_ARCH}.deb"
   sudo apt install -y "./kubectl-cnpg_${CNPG_PLUGIN_VERSION}_linux_${CNPG_ARCH}.deb"
   rm "kubectl-cnpg_${CNPG_PLUGIN_VERSION}_linux_${CNPG_ARCH}.deb"
EOF
            ;;
        kubectl-cnpg:fedora)
            cat <<'EOF'
   CNPG_PLUGIN_VERSION=1.30.1
   CNPG_ARCH=x86_64
   if [ "$(uname -m)" = "aarch64" ]; then CNPG_ARCH=arm64; fi
   sudo dnf install -y "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_PLUGIN_VERSION}/kubectl-cnpg_${CNPG_PLUGIN_VERSION}_linux_${CNPG_ARCH}.rpm"
EOF
            ;;
    esac
}

check_host_tooling() {
    echo "🔎 Running preflight checks..."
    echo ""
    echo "== Host tooling =="
    local has_errors=false
    local tool

    for tool in tofu helm flux gpg git uv just; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "✅ $tool"
        else
            echo "❌ $tool not found."
            print_install_command "$tool"
            has_errors=true
        fi
    done

    [ "$has_errors" = false ]
}

# Tools the bootstrap runs without; a recipe or workflow needs them later
check_optional_tooling() {
    echo "== Optional tooling =="
    local has_warnings=false
    local tool

    for tool in fzf tkn; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "✅ $tool"
        else
            echo "⚠️  $tool not found."
            print_install_command "$tool"
            has_warnings=true
        fi
    done

    [ "$has_warnings" = false ]
}

get_minor_version() {
    local version="${1#v}"
    version="${version#*.}"
    printf '%s\n' "${version%%.*}"
}

check_kubectl_tooling() {
    echo "== kubectl and plugins =="
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "❌ kubectl not found."
        print_install_command kubectl
        return 1
    fi
    echo "✅ kubectl"

    if ! kubectl cnpg version >/dev/null 2>&1; then
        echo "❌ kubectl cnpg plugin not found."
        print_install_command kubectl-cnpg
        return 1
    fi
    echo "✅ kubectl cnpg"
}

# kubectl supports one minor version of skew from the cluster
check_kubectl_skew() {
    local kubectl_version k3s_version minor_gap
    kubectl_version=$(kubectl version --client 2>/dev/null | awk '/Client Version/ {print $3}')
    k3s_version=$(get_cluster_config_value K3S_VERSION) || return 1
    minor_gap=$(( $(get_minor_version "$kubectl_version") - $(get_minor_version "$k3s_version") ))

    if [ "${minor_gap#-}" -gt 1 ]; then
        echo "⚠️  kubectl $kubectl_version is more than one minor version from k3s $k3s_version"
        print_install_command kubectl
        return 1
    fi
    echo "✅ kubectl $kubectl_version is within one minor version of k3s $k3s_version"
}

# The cnpg plugin must match the operator, whose version is the chart's appVersion
check_cnpg_plugin_version() {
    local chart_version operator_version plugin_version
    chart_version=$(get_cluster_config_value CNPG_VERSION) || return 1
    operator_version=$(helm show chart cloudnative-pg --repo https://cloudnative-pg.github.io/charts \
        --version "$chart_version" 2>/dev/null | awk '/^appVersion:/ {print $2}')
    plugin_version=$(kubectl cnpg version 2>/dev/null | sed -n 's/.*Version:\([0-9.]*\).*/\1/p')

    if [ -z "$operator_version" ]; then
        echo "⚠️  Could not read the CNPG operator version for chart $chart_version (helm show chart failed)"
        return 1
    fi
    if [ "$plugin_version" != "$operator_version" ]; then
        echo "⚠️  kubectl cnpg ${plugin_version:-unknown} differs from the CNPG operator $operator_version (chart $chart_version)"
        print_install_command kubectl-cnpg
        return 1
    fi
    echo "✅ kubectl cnpg $plugin_version matches the CNPG operator"
}

check_github_auth() {
    echo "== GitHub Authentication =="
    if [ -n "${GITHUB_APP_ID:-}" ]; then
        echo "✅ GitHub App (ID: $GITHUB_APP_ID) configured"
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "❌ No GitHub App provided and gh not found."
        print_install_command gh
        echo "   Then authenticate gh with: gh auth login"
        return 1
    fi

    if ! gh auth status >/dev/null 2>&1; then
        echo "❌ No GitHub App provided and gh not authenticated. Authenticate gh with:"
        echo "   gh auth login"
        return 1
    fi

    echo "✅ gh authenticated (fallback)"
}

check_debian_firewall() {
    if ! command -v ufw >/dev/null 2>&1; then
        echo "⚠️  ufw not found on a Debian/Ubuntu host (expected on this distro family). Inspect the firewall's INPUT policy with:"
        echo "   sudo iptables -L INPUT -n -v"
        return 1
    fi

    if ! sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "✅ ufw present and inactive: no rules to check"
        return 0
    fi

    local forward_policy ufw_rules missing_interfaces=() interface
    forward_policy=$(grep -E '^DEFAULT_FORWARD_POLICY' /etc/default/ufw 2>/dev/null | cut -d'"' -f2)
    ufw_rules=$(sudo ufw status verbose 2>/dev/null)

    for interface in cilium_host cilium_net cilium_vxlan "lxc+"; do
        echo "$ufw_rules" | grep -q "ALLOW IN.*on $interface" || missing_interfaces+=("$interface")
    done

    if [ "$forward_policy" != "ACCEPT" ] || [ ${#missing_interfaces[@]} -gt 0 ]; then
        echo "⚠️  ufw is active but not configured for Cilium:"
        [ "$forward_policy" != "ACCEPT" ] && echo "   - DEFAULT_FORWARD_POLICY is '${forward_policy:-unset}', expected ACCEPT"
        [ ${#missing_interfaces[@]} -gt 0 ] && echo "   - missing ALLOW IN rules for: ${missing_interfaces[*]}"
        echo "   Apply the rules with:"
        echo "   just setup-firewall"
        return 1
    fi

    echo "✅ ufw active and configured for Cilium"
    return 0
}

firewalld_policy_matches() {
    local policy_name="$1" ingress_zone="$2" egress_zone="$3" policy_config
    policy_config=$(firewall-cmd --policy="$policy_name" --list-all 2>/dev/null) || return 1
    echo "$policy_config" | grep -qx "  ingress-zones: $ingress_zone" || return 1
    echo "$policy_config" | grep -qx "  egress-zones: $egress_zone" || return 1
    echo "$policy_config" | grep -qx "  target: ACCEPT" || return 1
    echo "$policy_config" | grep -qx "  priority: -1"
}

report_missing_firewalld_rules() {
    [ "$#" -gt 0 ] || return 0
    local missing_rule
    echo "⚠️  firewalld is missing required rules for Kubernetes/Cilium:"
    for missing_rule in "$@"; do
        echo "   - $missing_rule"
    done
    echo "   Apply them with: just setup-firewall"
    return 1
}

check_firewalld_lan_rules() {
    local lan_zone="$1" zone_config missing_rules=()
    zone_config=$(firewall-cmd --zone="$lan_zone" --list-all) || return 1

    if echo "$zone_config" | grep -qE '1025-65535/(tcp|udp)'; then
        echo "❌ LAN zone '$lan_zone' still allows unrestricted high ports; run just setup-firewall"
        return 1
    fi

    echo "$zone_config" | grep -q 'forward: yes' || missing_rules+=("forwarding in LAN zone '$lan_zone'")
    firewall-cmd --zone="$lan_zone" --query-port=443/tcp >/dev/null || missing_rules+=("443/tcp in LAN zone '$lan_zone'")
    firewall-cmd --zone="$lan_zone" --query-port=5432/tcp >/dev/null || missing_rules+=("5432/tcp in LAN zone '$lan_zone'")
    firewall-cmd --zone="$lan_zone" --query-service=dns >/dev/null || missing_rules+=("DNS in LAN zone '$lan_zone'")
    report_missing_firewalld_rules "${missing_rules[@]}"
}

check_firewalld_trusted_rules() {
    local pod_cidr="$1" interface missing_rules=()
    firewall-cmd --zone=trusted --query-source="$pod_cidr" >/dev/null || missing_rules+=("$pod_cidr source in trusted zone")
    firewall-cmd --zone=trusted --query-service=dns >/dev/null || missing_rules+=("DNS in trusted zone")
    for interface in cilium_host cilium_net cilium_vxlan; do
        firewall-cmd --zone=trusted --query-interface="$interface" >/dev/null || missing_rules+=("$interface in trusted zone")
    done
    report_missing_firewalld_rules "${missing_rules[@]}"
}

check_firewalld_policies() {
    local missing_rules=()
    firewalld_policy_matches k8s-forwarding-in ANY trusted || missing_rules+=("ANY -> trusted forwarding policy")
    firewalld_policy_matches k8s-forwarding-out trusted ANY || missing_rules+=("trusted -> ANY forwarding policy")
    firewalld_policy_matches k8s-forwarding-host HOST ANY || missing_rules+=("HOST -> ANY forwarding policy")
    firewalld_policy_matches k8s-containers-to-host trusted HOST || missing_rules+=("trusted -> HOST input policy")
    report_missing_firewalld_rules "${missing_rules[@]}"
}

check_fedora_firewall() {
    local lan_zone pod_cidr
    require_firewalld || return 1
    lan_zone=$(get_firewalld_lan_zone) || return 1
    pod_cidr=$(get_cluster_config_value POD_CIDR) || return 1

    check_firewalld_lan_rules "$lan_zone" || return 1
    check_firewalld_trusted_rules "$pod_cidr" || return 1
    check_firewalld_policies || return 1
    echo "✅ firewalld active and configured for Cilium (LAN zone: $lan_zone)"
}

check_host_firewall() {
    local distro_info distro_family distro_id check_function
    echo "== Host firewall =="
    distro_info=$(detect_distro)
    distro_family="${distro_info%% *}"
    distro_id="${distro_info#* }"
    check_function="check_${distro_family}_firewall"

    if ! declare -f "$check_function" >/dev/null 2>&1; then
        echo "⚠️  Unrecognized distro '$distro_id'; inspect the host firewall manually."
        return 1
    fi

    "$check_function"
}

check_reserved_ips() {
    local has_warnings=false
    local gateway_ip coredns_lan_ip loadbalancer_pool_stop reserved_ip
    gateway_ip=$(get_cluster_config_value GATEWAY_IP) || return 1
    coredns_lan_ip=$(get_cluster_config_value COREDNS_LAN_IP) || return 1
    loadbalancer_pool_stop=$(get_cluster_config_value LAN_LB_POOL_STOP) || return 1
    echo "== Reserved IP range ($gateway_ip-$loadbalancer_pool_stop) =="

    for reserved_ip in "$gateway_ip" "$coredns_lan_ip"; do
        if ping -c 1 -W 1 "$reserved_ip" >/dev/null 2>&1; then
            echo "⚠️  $reserved_ip already answers on the LAN. Find the device holding it with:"
            echo "   ip neigh show $reserved_ip"
            echo "   Then exclude the reserved range from your router's DHCP pool."
            has_warnings=true
        else
            echo "✅ $reserved_ip free"
        fi
    done
    echo ""

    [ "$has_warnings" = false ]
}

report_summary() {
    local had_errors="$1" had_warnings="$2"
    if [ "$had_errors" = true ]; then
        echo "❌ Preflight failed: resolve the errors above before bootstrapping."
        return 1
    fi
    if [ "$had_warnings" = true ]; then
        echo "⚠️  Preflight passed with warnings: review above."
        return 0
    fi
    echo "✅ Preflight passed."
}

check_kubectl_versions() {
    # Missing tools are reported as errors by check_kubectl_tooling.
    command -v kubectl >/dev/null 2>&1 || return 0
    kubectl cnpg version >/dev/null 2>&1 || return 0
    local had_warnings=false
    check_kubectl_skew || had_warnings=true
    check_cnpg_plugin_version || had_warnings=true
    [ "$had_warnings" = false ]
}

main() {
    local had_errors=false had_warnings=false

    check_host_tooling || had_errors=true
    echo ""
    check_optional_tooling || had_warnings=true
    echo ""
    check_kubectl_tooling || had_errors=true
    check_kubectl_versions || had_warnings=true
    echo ""
    check_github_auth || had_errors=true
    echo ""
    check_host_firewall || had_warnings=true
    echo ""
    check_reserved_ips || had_warnings=true
    report_summary "$had_errors" "$had_warnings"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
