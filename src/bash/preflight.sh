#!/bin/bash
#
# preflight.sh: Read-only host readiness checks (see INSTALLATION.md
# Requirements). Makes no changes to the system — firewall rules and the
# reserved IP range are checked, never modified, here or anywhere else.
#
set -eu
had_warnings=false
had_errors=false

echo "🔎 Running preflight checks..."
echo ""

# --- Required host tooling ---------------------------------------------------
echo "== Host tooling =="
for bin in vault tofu helm flux gh gpg openssl python3 just; do
    if command -v "$bin" >/dev/null 2>&1; then
        echo "✅ $bin"
    else
        echo "❌ $bin not found. See INSTALLATION.md Requirements."
        had_errors=true
    fi
done
if command -v psql >/dev/null 2>&1; then
    echo "✅ psql"
else
    echo "⚠️  psql not found (only needed later for 'just db-connect'). See INSTALLATION.md Requirements."
    had_warnings=true
fi
echo ""

# --- GitHub CLI authentication ------------------------------------------------
echo "== GitHub CLI =="
if gh auth status >/dev/null 2>&1; then
    echo "✅ gh authenticated"
else
    echo "❌ gh not authenticated. Run: gh auth login"
    had_errors=true
fi
echo ""

# --- Host firewall (advisory only) -------------------------------------------
# Distro is classified explicitly so an unrecognized/unverified distro is
# never mistaken for "no firewall, you're fine" — every outcome outside the
# two verified families is a visible warning, never a silent pass.
echo "== Host firewall =="
distro_family="unknown"
distro_id="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    distro_id="${ID:-unknown}"
    case " ${ID:-} ${ID_LIKE:-} " in
        *" ubuntu "*|*" debian "*) distro_family="debian" ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) distro_family="fedora" ;;
    esac
fi

case "$distro_family" in
debian)
    if ! command -v ufw >/dev/null 2>&1; then
        echo "⚠️  ufw not found on a Debian/Ubuntu host — expected on this distro family. Verify firewall state manually (see INSTALLATION.md Requirements)."
        had_warnings=true
    elif ! sudo ufw status | grep -q "Status: active"; then
        echo "✅ ufw present and inactive — no rules to check"
    else
        fwd_policy=$(grep -E '^DEFAULT_FORWARD_POLICY' /etc/default/ufw 2>/dev/null | cut -d'"' -f2)
        ufw_rules=$(sudo ufw status verbose 2>/dev/null)
        missing=()
        for iface in cilium_host cilium_net cilium_vxlan "lxc+"; do
            echo "$ufw_rules" | grep -q "ALLOW IN.*on $iface" || missing+=("$iface")
        done
        if [ "$fwd_policy" != "ACCEPT" ] || [ ${#missing[@]} -gt 0 ]; then
            echo "⚠️  ufw is active but not configured for Cilium (see INSTALLATION.md Requirements)."
            [ "$fwd_policy" != "ACCEPT" ] && echo "   - DEFAULT_FORWARD_POLICY is '${fwd_policy:-unset}', expected ACCEPT"
            [ ${#missing[@]} -gt 0 ] && echo "   - missing ALLOW IN rules for: ${missing[*]}"
            had_warnings=true
        else
            echo "✅ ufw active and configured for Cilium"
        fi
    fi
    ;;
fedora)
    if ! command -v firewall-cmd >/dev/null 2>&1; then
        echo "⚠️  firewall-cmd not found on a Fedora/RHEL host — expected on this distro family. Verify firewall state manually (see INSTALLATION.md Requirements)."
        had_warnings=true
    elif ! sudo firewall-cmd --state >/dev/null 2>&1; then
        echo "✅ firewalld present and inactive — no rules to check"
    else
        zone=$(firewall-cmd --get-default-zone)
        zone_info=$(firewall-cmd --zone="$zone" --list-all)
        if ! echo "$zone_info" | grep -q "forward: yes" || ! echo "$zone_info" | grep -q "443/tcp"; then
            echo "⚠️  firewalld is active on zone '$zone' but may not be configured for Cilium (see INSTALLATION.md Requirements)."
            had_warnings=true
        else
            echo "✅ firewalld active and configured for Cilium (zone: $zone)"
        fi
    fi
    ;;
*)
    echo "⚠️  Unrecognized distro ('$distro_id') — firewall check is only verified for Ubuntu/Debian and Fedora/RHEL. Skipping automated check; verify manually per INSTALLATION.md Requirements."
    had_warnings=true
    ;;
esac
echo ""

# --- Reserved IP range --------------------------------------------------------
echo "== Reserved IP range (192.0.2.240-192.0.2.250) =="
for ip in 192.0.2.240 192.0.2.242; do
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        echo "⚠️  $ip already answers on the LAN — check for a DHCP conflict (see INSTALLATION.md Requirements)."
        had_warnings=true
    else
        echo "✅ $ip free"
    fi
done
echo ""

# --- Host Transit Vault state (informational) ---------------------------------
echo "== Host Transit Vault =="
if command -v vault >/dev/null 2>&1 && [ -f /opt/vault/tls/tls.crt ]; then
    transit_state=$(VAULT_ADDR="https://127.0.0.1:8200" VAULT_CACERT="/opt/vault/tls/tls.crt" vault status -format=json 2>/dev/null | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('initialized', False))
except Exception:
    print('unknown')" 2>/dev/null || echo unknown)
    case "$transit_state" in
        True) echo "✅ initialized" ;;
        False) echo "⚠️  installed but not yet initialized. Run: just bootstrap-transit" ;;
        *) echo "⚠️  installed but status unreachable/unknown" ;;
    esac
else
    echo "ℹ️  not yet deployed. Run: just bootstrap-transit"
fi
echo ""

if [ "$had_errors" = true ]; then
    echo "❌ Preflight failed — resolve the errors above before bootstrapping."
    exit 1
elif [ "$had_warnings" = true ]; then
    echo "⚠️  Preflight passed with warnings — review above."
else
    echo "✅ Preflight passed."
fi
