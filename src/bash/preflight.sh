#!/usr/bin/env bash
#
# preflight.sh: Read-only host readiness checks.
#
set -euo pipefail

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
    local bin="$1"
    local distro_info distro_family distro_id
    distro_info=$(detect_distro)
    distro_family="${distro_info%% *}"
    distro_id="${distro_info#* }"

    if [ "$distro_family" = unknown ]; then
        echo "   Preflight has no install command for '$distro_id'. Install $(get_project_name "$bin") following its documentation for your distribution."
        return 0
    fi

    echo "   Install it with:"
    case "$bin:$distro_family" in
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
    local bin

    for bin in tofu helm flux gpg git uv just; do
        if command -v "$bin" >/dev/null 2>&1; then
            echo "✅ $bin"
        else
            echo "❌ $bin not found."
            print_install_command "$bin"
            has_errors=true
        fi
    done

    [ "$has_errors" = false ]
}

# Tools the bootstrap runs without; a recipe or workflow needs them later
check_optional_tooling() {
    echo "== Optional tooling =="
    local has_warnings=false
    local bin

    for bin in fzf tkn; do
        if command -v "$bin" >/dev/null 2>&1; then
            echo "✅ $bin"
        else
            echo "⚠️  $bin not found."
            print_install_command "$bin"
            has_warnings=true
        fi
    done

    [ "$has_warnings" = false ]
}

# Reads the cluster-config ConfigMap Flux will build; preflight runs before the cluster exists
get_cluster_config_value() {
    local key="$1"
    local script_dir value
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    value=$(kubectl kustomize "$script_dir/../../infrastructure/cluster-config" 2>/dev/null \
        | awk -v prefix="  $key: " 'index($0, prefix) == 1 { value = substr($0, length(prefix) + 1); gsub(/"/, "", value); print value; exit }')
    if [ -z "$value" ]; then
        echo "❌ $key not found in infrastructure/cluster-config (kubectl kustomize)" >&2
        return 1
    fi
    printf '%s\n' "$value"
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
        echo ""
        return 0
    elif ! command -v gh >/dev/null 2>&1; then
        echo "❌ No GitHub App provided and gh not found."
        print_install_command gh
        echo "   Then authenticate gh with:"
        echo "   gh auth login"
        echo ""
        return 1
    elif gh auth status >/dev/null 2>&1; then
        echo "✅ gh authenticated (fallback)"
        echo ""
        return 0
    else
        echo "❌ No GitHub App provided and gh not authenticated. Authenticate gh with:"
        echo "   gh auth login"
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

    local fwd_policy ufw_rules missing=() iface
    fwd_policy=$(grep -E '^DEFAULT_FORWARD_POLICY' /etc/default/ufw 2>/dev/null | cut -d'"' -f2)
    ufw_rules=$(sudo ufw status verbose 2>/dev/null)

    for iface in cilium_host cilium_net cilium_vxlan "lxc+"; do
        echo "$ufw_rules" | grep -q "ALLOW IN.*on $iface" || missing+=("$iface")
    done

    if [ "$fwd_policy" != "ACCEPT" ] || [ ${#missing[@]} -gt 0 ]; then
        echo "⚠️  ufw is active but not configured for Cilium:"
        [ "$fwd_policy" != "ACCEPT" ] && echo "   - DEFAULT_FORWARD_POLICY is '${fwd_policy:-unset}', expected ACCEPT"
        [ ${#missing[@]} -gt 0 ] && echo "   - missing ALLOW IN rules for: ${missing[*]}"
        echo "   Apply the rules with:"
        echo "   just setup-firewall"
        return 1
    fi

    echo "✅ ufw active and configured for Cilium"
    return 0
}

check_fedora_firewall() {
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "⚠️  firewall-cmd not found on a Fedora/RHEL host (expected on this distro family). Inspect the firewall's INPUT policy with:"
        echo "   sudo iptables -L INPUT -n -v"
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
    pod_cidr=$(get_cluster_config_value POD_CIDR) || return 1

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
        echo "⚠️  firewalld is active but missing required rules/policies for Kubernetes/Cilium:"
        for item in "${missing[@]}"; do
            echo "   - missing $item"
        done
        echo "   Apply them with:"
        echo "   just setup-firewall"
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
            echo "⚠️  Unrecognized distro ('$distro_id'): firewall check is only verified for Ubuntu/Debian and Fedora/RHEL. Skipping automated check; inspect the firewall's INPUT policy with:"
            echo "   sudo iptables -L INPUT -n -v"
            rc=1
            ;;
    esac
    echo ""
    return "$rc"
}

check_reserved_ips() {
    local has_warnings=false
    local gateway_ip coredns_lan_ip pool_stop ip
    gateway_ip=$(get_cluster_config_value GATEWAY_IP) || return 1
    coredns_lan_ip=$(get_cluster_config_value COREDNS_LAN_IP) || return 1
    pool_stop=$(get_cluster_config_value LAN_LB_POOL_STOP) || return 1
    echo "== Reserved IP range ($gateway_ip-$pool_stop) =="

    for ip in "$gateway_ip" "$coredns_lan_ip"; do
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
            echo "⚠️  $ip already answers on the LAN. Find the device holding it with:"
            echo "   ip neigh show $ip"
            echo "   Then exclude the reserved range from your router's DHCP pool."
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
    echo ""
    check_optional_tooling || had_warnings=true
    echo ""
    if check_kubectl_tooling; then
        check_kubectl_skew || had_warnings=true
        check_cnpg_plugin_version || had_warnings=true
    else
        had_errors=true
    fi
    echo ""
    check_github_auth || had_errors=true

    check_host_firewall || had_warnings=true

    check_reserved_ips || had_warnings=true

    report_summary "$had_errors" "$had_warnings"
}

main "$@"
