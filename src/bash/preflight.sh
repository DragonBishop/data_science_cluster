#!/usr/bin/env bash
#
# preflight.sh: Read-only host readiness checks.
#
set -euo pipefail

get_repo_path() {
    local relative_path="$1"
    printf '%s/../../%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "$relative_path"
}

# Read the configuration Flux will use, before the cluster exists.
get_cluster_config_value() {
    local config_key="$1" config_value
    config_value=$(kubectl kustomize "$(get_repo_path infrastructure/cluster-config)" 2>/dev/null \
        | awk -v config_prefix="  $config_key: " 'index($0, config_prefix) == 1 { config_value = substr($0, length(config_prefix) + 1); gsub(/"/, "", config_value); print config_value; exit }') || return 1

    if [ -z "$config_value" ]; then
        echo "❌ $config_key not found in infrastructure/cluster-config (kubectl kustomize)" >&2
        return 1
    fi

    printf '%s\n' "$config_value"
}

get_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v apt-get >/dev/null 2>&1; then
        echo apt
    else
        echo unknown
    fi
}

# Reads versions.yaml directly; kubectl kustomize is unavailable when kubectl itself is missing
get_kubectl_minor_version() {
    awk -F'"' '/^  KUBECTL_VERSION:/ {split($2, part, "."); print substr(part[1], 2) "." part[2]}' \
        "$(get_repo_path infrastructure/cluster-config/versions.yaml)"
}

print_third_party_note() {
    echo "   (Third-party repository. docs/INSTALLATION.md also lists the project's own install.)"
}

print_krouma_copr_setup() {
    print_third_party_note
    cat <<'EOF'
   sudo dnf copr enable -y krouma/kubernetes
   sudo dnf config-manager setopt 'copr:copr.fedorainfracloud.org:krouma:kubernetes.includepkgs=flux2-cli,tektoncd-cli'
EOF
}

print_wakemeops_setup() {
    print_third_party_note
    cat <<'EOF'
   curl -sSL https://raw.githubusercontent.com/upciti/wakemeops/main/assets/install_repository | sudo bash -s -- devops
   printf 'Package: flux krew\nPin: origin deb.wakemeops.com\nPin-Priority: 500\n\nPackage: *\nPin: origin deb.wakemeops.com\nPin-Priority: -1\n' | sudo tee /etc/apt/preferences.d/wakemeops > /dev/null
EOF
}

print_kubernetes_apt_setup() {
    local kubectl_minor="$1"
    cat <<EOF
   curl -fsSL https://pkgs.k8s.io/core:/stable:/v${kubectl_minor}/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${kubectl_minor}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
   sudo apt update && sudo apt install -y kubectl
EOF
}

# The shortest install for each tool, matching docs/INSTALLATION.md Host Tooling
print_install_commands() {
    local tool="$1" package_manager
    package_manager=$(get_package_manager)
    if [ "$package_manager" = unknown ]; then
        echo "   Install $tool following docs/INSTALLATION.md (Host Tooling)."
        return 0
    fi

    echo "   Install it with:"
    case "$tool:$package_manager" in
        tofu:dnf)
            cat <<'EOF'
   curl -fsSL https://get.opentofu.org/install-opentofu.sh | sudo sh -s -- --install-method rpm
   sudo sed -i '/^sslcacert=/d' /etc/yum.repos.d/opentofu.repo
   sudo dnf swap -y opentofu tofu
EOF
            ;;
        tofu:apt) echo "   curl -fsSL https://get.opentofu.org/install-opentofu.sh | sudo sh -s -- --install-method deb" ;;
        helm:apt)
            cat <<'EOF'
   curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
   echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
   sudo apt update && sudo apt install -y helm
EOF
            ;;
        flux:dnf) print_krouma_copr_setup; echo "   sudo dnf install -y flux2-cli" ;;
        flux:apt) print_wakemeops_setup; echo "   sudo apt install -y flux" ;;
        tkn:dnf) print_krouma_copr_setup; echo "   sudo dnf install -y tektoncd-cli" ;;
        tkn:apt)
            cat <<'EOF'
   TKN_DEB=$(curl -fsSL https://api.github.com/repos/tektoncd/cli/releases/latest | grep -o 'https://[^"]*_Linux-64bit\.deb')
   curl -fsSLo /tmp/tektoncd-cli.deb "$TKN_DEB" && sudo apt install -y /tmp/tektoncd-cli.deb
EOF
            ;;
        kubectl:dnf) echo "   sudo dnf install -y kubernetes$(get_kubectl_minor_version)-client" ;;
        kubectl:apt) print_kubernetes_apt_setup "$(get_kubectl_minor_version)" ;;
        kubectl-cnpg:dnf)
            print_third_party_note
            cat <<'EOF'
   sudo dnf copr enable -y shdwchn10/AllTheTools
   sudo dnf config-manager setopt 'copr:copr.fedorainfracloud.org:shdwchn10:AllTheTools.includepkgs=kubectl-cnpg'
   sudo dnf install -y kubectl-cnpg
EOF
            ;;
        kubectl-cnpg:apt) print_wakemeops_setup; echo "   sudo apt install -y krew && krew install cnpg" ;;
        gh:apt)
            cat <<'EOF'
   curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /usr/share/keyrings/githubcli-archive-keyring.gpg > /dev/null
   echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
   sudo apt update && sudo apt install -y gh
EOF
            ;;
        uv:*) echo "   curl -LsSf https://astral.sh/uv/install.sh | sh" ;;
        *:dnf) echo "   sudo dnf install -y $tool" ;;
        *:apt) echo "   sudo apt update && sudo apt install -y $tool" ;;
    esac
}

# Moves kubectl to the minor version KUBECTL_VERSION pins
print_kubectl_switch_commands() {
    local installed_minor="$1" target_minor
    target_minor=$(get_kubectl_minor_version)
    echo "   Switch to kubectl $target_minor with:"
    case "$(get_package_manager)" in
        dnf) echo "   sudo dnf swap -y kubernetes${installed_minor}-client kubernetes${target_minor}-client" ;;
        apt) print_kubernetes_apt_setup "$target_minor" ;;
        *) echo "   Follow docs/INSTALLATION.md (Host Tooling, kubectl)." ;;
    esac
}

print_cnpg_plugin_upgrade_commands() {
    echo "   Upgrade the plugin with:"
    case "$(get_package_manager)" in
        dnf) echo "   sudo dnf upgrade -y --refresh kubectl-cnpg" ;;
        apt) echo "   krew upgrade cnpg" ;;
        *) echo "   Follow docs/INSTALLATION.md (Host Tooling, kubectl cnpg Plugin)." ;;
    esac
}

# Reports each missing command with its install commands, marking it with the given symbol
check_commands_present() {
    local missing_marker="$1" tool all_present=true
    shift
    for tool in "$@"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "✅ $tool"
        else
            echo "$missing_marker $tool not found."
            print_install_commands "$tool"
            all_present=false
        fi
    done
    [ "$all_present" = true ]
}

check_host_tooling() {
    echo "🔎 Running preflight checks..."
    echo ""
    echo "== Host tooling =="
    check_commands_present "❌" tofu helm flux git uv just
}

# Tools the bootstrap runs without; a recipe or workflow needs them later
check_optional_tooling() {
    echo "== Optional tooling =="
    check_commands_present "⚠️ " fzf tkn
}

get_minor_version() {
    local version="${1#v}"
    version="${version#*.}"
    printf '%s\n' "${version%%.*}"
}

get_major_minor_version() {
    local version="${1#v}"
    printf '%s\n' "${version%.*}"
}

version_is_older() {
    local version="$1" other_version="$2"
    [ "$version" != "$other_version" ] \
        && [ "$(printf '%s\n' "$version" "$other_version" | sort -V | head -n 1)" = "$version" ]
}

check_kubectl_tooling() {
    echo "== kubectl and plugins =="
    check_commands_present "❌" kubectl kubectl-cnpg
}

# kubectl supports one minor version of skew from the cluster
check_kubectl_skew() {
    local kubectl_version k3s_version minor_gap
    kubectl_version=$(kubectl version --client 2>/dev/null | awk '/Client Version/ {print $3}')
    k3s_version=$(get_cluster_config_value K3S_VERSION) || return 1
    minor_gap=$(( $(get_minor_version "$kubectl_version") - $(get_minor_version "$k3s_version") ))

    if [ "${minor_gap#-}" -gt 1 ]; then
        echo "⚠️  kubectl $kubectl_version is more than one minor version from k3s $k3s_version"
        print_kubectl_switch_commands "$(get_major_minor_version "$kubectl_version")"
        return 1
    fi
    echo "✅ kubectl $kubectl_version is within one minor version of k3s $k3s_version"
}

# The CNPG operator's version is the appVersion of the chart CNPG_VERSION pins
get_cnpg_operator_version() {
    local chart_version="$1"
    helm show chart cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version "$chart_version" 2>/dev/null \
        | awk '/^appVersion:/ {print $2}'
}

get_cnpg_plugin_version() {
    kubectl cnpg version 2>/dev/null | sed -n 's/.*Version:\([0-9.]*\).*/\1/p'
}

# The cnpg plugin must share the operator's minor version
check_cnpg_plugin_version() {
    local chart_version operator_version plugin_version plugin_minor operator_minor
    chart_version=$(get_cluster_config_value CNPG_VERSION) || return 1
    operator_version=$(get_cnpg_operator_version "$chart_version")
    plugin_version=$(get_cnpg_plugin_version)

    if [ -z "$operator_version" ]; then
        echo "⚠️  Could not read the CNPG operator version for chart $chart_version (helm show chart failed)"
        return 1
    fi
    plugin_minor=$(get_major_minor_version "$plugin_version")
    operator_minor=$(get_major_minor_version "$operator_version")
    if [ "$plugin_minor" = "$operator_minor" ]; then
        echo "✅ kubectl cnpg $plugin_version shares the CNPG operator's minor version ($operator_version)"
        return 0
    fi

    echo "⚠️  kubectl cnpg ${plugin_version:-unknown} is on a different minor version than the CNPG operator $operator_version (chart $chart_version)"
    if version_is_older "$plugin_minor" "$operator_minor"; then
        print_cnpg_plugin_upgrade_commands
    else
        echo "   The operator moves to $plugin_minor when Renovate bumps CNPG_VERSION to a chart with that appVersion."
    fi
    return 1
}

check_github_auth() {
    echo "== GitHub Authentication =="
    if [ -n "${GITHUB_APP_ID:-}" ]; then
        echo "✅ GitHub App (ID: $GITHUB_APP_ID) configured"
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "❌ No GitHub App provided and gh not found."
        print_install_commands gh
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

check_host_firewall() {
    echo "== Host firewall =="
    "$(get_repo_path src/bash/setup-firewall.sh)" --check
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
    command -v kubectl-cnpg >/dev/null 2>&1 || return 0
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
