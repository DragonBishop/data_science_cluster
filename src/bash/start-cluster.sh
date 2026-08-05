#!/bin/bash
#
# start-cluster.sh — Starts k3s, unseals the host Transit Vault, and
# un-hibernates the CNPG cluster.
#
# Everything else (in-cluster Vault unseal, VSO secret sync, CNPG operator
# health, workload health) is reconciled continuously by Flux and visible
# live in Headlamp or `flux get kustomizations` / `kubectl cnpg status` —
# this script only does what nothing else can do: host-level actions and
# the hibernation flip, which is deliberately excluded from Flux's declared
# state (see WORKFLOW.md Phase 12's note on SSA field ownership).
#
# Failures after the k3s startup phase set had_warnings and the script
# continues. It exits 1 at the end if any were set.
#
set -eu
had_warnings=false

# --- Step 1: Prevent duplicate execution ----------------------------------
# Exits if systemd's k3s service is already active. Two k3s instances
# against the same data directory and ports corrupt cluster state.
if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "⚠️  systemd's k3s.service is already active. Refusing to start a second instance."
    echo "   To adopt a script-managed lifecycle, run: sudo systemctl disable --now k3s"
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# --- Step 2: Launch k3s Server ---------------------------------------------
# Starts k3s in the background under nohup and captures its PID. The flags
# match those used at install time.
echo "🚀 Starting k3s cluster..."
K3S_PID=$(sudo bash -c 'nohup k3s server \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb \
  --disable-kube-proxy \
  --disable-network-policy \
  --flannel-backend=none \
  > /var/log/k3s.log 2>&1 &
  echo $!')

# --- Step 3: Wait for API Server -------------------------------------------
# Polls `kubectl get nodes` every 5s for up to 60s. Each iteration also signals
# the k3s PID, so a process that exits early fails the step immediately rather
# than at the timeout.
echo "⏳ Waiting for Kubernetes API to become available (pid $K3S_PID)..."
retries=0
until kubectl get nodes &> /dev/null; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died during startup."
        echo "Check logs: sudo tail -n 50 /var/log/k3s.log"
        exit 1
    fi
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 12 ]; then
        echo "❌ ERROR: API server failed to respond after 60 seconds."
        exit 1
    fi
    echo "   ...still waiting for API... ($((retries * 5))s elapsed)"
done
echo "✅ Kubernetes API is up."

# --- Step 4: Wait for Node Readiness ---------------------------------------
# Polls node status every 5s for up to 5 minutes. The node reports NotReady
# until a CNI is running, so this step is what surfaces a missing or unhealthy
# Cilium. Continues signalling the k3s PID.
retries=0
until kubectl get nodes | grep -q " Ready"; do
    if ! sudo kill -0 "$K3S_PID" 2>/dev/null; then
        echo "❌ ERROR: k3s (pid $K3S_PID) died while waiting for node Ready."
        exit 1
    fi
    sleep 5
    retries=$((retries+1))
    if [ $retries -ge 60 ]; then
        echo "❌ ERROR: Node did not reach Ready within 5 minutes."
        echo "💡 TROUBLESHOOTING: A node with no CNI stays NotReady indefinitely."
        echo "   1. Is Cilium installed?  cilium status --wait"
        echo "   2. On a first-time build, install it now (README Step 2c):"
        echo "      helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \\"
        echo "        --version 1.20.0 --namespace kube-system -f manifests/cilium-values.yaml"
        exit 1
    fi
    echo "   ...still waiting for node... ($((retries * 5))s elapsed)"
done
echo "✅ Node is Ready."
echo ""

# --- Step 5: Unseal Host Transit Vault ------------------------------------
# Reads the host Transit Vault's seal state. If sealed, decrypts the Shamir
# keys from the GPG keyfile and submits them one per line.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"

# Maps `vault status` exit codes: 0 unsealed, 2 sealed, anything else a
# connection or certificate failure.
transit_seal_state() {
    local rc=0
    vault status -format=json > /dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo unsealed
    elif [ "$rc" -eq 2 ]; then
        echo sealed
    else
        echo unreachable
    fi
}

echo "⏳ Checking host Transit Vault seal status..."
seal_state=$(transit_seal_state)
if [ "$seal_state" = unsealed ]; then
    echo "✅ Host Transit Vault already unsealed."
elif [ "$seal_state" = unreachable ]; then
    echo "❌ ERROR: Cannot reach the host Transit Vault at $VAULT_ADDR. Continuing..."
    vault status 2>&1 | sed 's/^/   /'
    echo "💡 TROUBLESHOOTING: This is a connection or certificate failure, not a seal."
    echo "   1. Does the CA file exist?  ls -l $VAULT_CACERT"
    echo "   2. Does the cert cover this address? It needs an IP:127.0.0.1 SAN."
    echo "   3. Is the service up?  systemctl status vault"
    had_warnings=true
else
    echo "🔒 Host Transit Vault is sealed."
    KEYFILE="$HOME/.vault-keys.gpg"
    if [ ! -f "$KEYFILE" ]; then
        echo "❌ ERROR: $KEYFILE not found. Cannot unseal Transit Vault."
        echo "💡 TROUBLESHOOTING: Did you create the GPG keyfile (README Step 3)?. Continuing..."
        had_warnings=true
    else
        # Submits each key on stdin via `key=-`, keeping it out of
        # /proc/<pid>/cmdline. Returns the exit status of gpg, so a failed or
        # cancelled decryption is distinguishable from a rejected key.
        decrypt_and_unseal() {
            gpg --quiet --decrypt "$KEYFILE" | while IFS= read -r key; do
                [ -n "$key" ] || continue
                if ! err=$(printf '%s\n' "$key" | vault write -format=json sys/unseal key=- 2>&1 >/dev/null); then
                    echo "   ⚠️ Key rejected by Vault: $err"
                fi
            done
            return "${PIPESTATUS[0]}"
        }

        echo "🔑 Enter GPG passphrase to decrypt unseal keys:"
        if ! decrypt_and_unseal; then
            echo "❌ ERROR: GPG decryption failed or was cancelled. Transit Vault remains sealed. Continuing..."
            had_warnings=true
        fi

        seal_state=$(transit_seal_state)
        if [ "$seal_state" = unsealed ]; then
            echo "✅ Host Transit Vault unsealed successfully."
        elif [ "$seal_state" = sealed ]; then
            echo "❌ ERROR: Transit Vault still sealed after applying keys from $KEYFILE. Continuing..."
            had_warnings=true
        else
            echo "❌ ERROR: Transit Vault unreachable after applying keys from $KEYFILE. Continuing..."
            vault status 2>&1 | sed 's/^/   /'
            had_warnings=true
        fi
    fi
fi
echo ""

# --- Step 6: Renew Transit Auto-Unseal Token -------------------------------
# Reads the token from vault-transit-secret and renews it, restarting its 768h
# period. The token is passed in VAULT_TOKEN rather than as an argument.
echo "⏳ Rolling the Transit auto-unseal token forward..."
transit_token=$(kubectl get secret vault-transit-secret -n vault \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null) || transit_token=""
if [ -z "$transit_token" ]; then
    echo "⚠️  Could not read vault-transit-secret — skipping renewal."
    echo "💡 TROUBLESHOOTING: kubectl get secret vault-transit-secret -n vault"
    had_warnings=true
elif VAULT_TOKEN="$transit_token" vault token renew > /dev/null 2>&1; then
    ttl=$(VAULT_TOKEN="$transit_token" vault token lookup 2>/dev/null \
        | awk '$1=="ttl"{print $2}') || ttl=""
    echo "✅ Transit token renewed (ttl now ${ttl:-unknown})."
else
    echo "⚠️  Transit token renewal failed. Auto-unseal keeps working until the"
    echo "   token's window closes; after that the in-cluster Vault cannot unseal."
    echo "💡 TROUBLESHOOTING: Issue a replacement from the host Transit Vault and"
    echo "   replace the Secret (README Steps 3 and 4). Capture the token into a"
    echo "   variable rather than pasting it as a --from-literal argument:"
    echo "   kubectl delete secret vault-transit-secret -n vault"
    echo "   NEWTOK=\$(vault token create -policy=autounseal-policy -period=768h -orphan -field=token) && \\"
    echo "     printf '%s' \"\$NEWTOK\" | kubectl create secret generic vault-transit-secret --from-file=token=/dev/stdin -n vault"
    echo "   unset NEWTOK"
    echo "   kubectl delete pod -n vault vault-0"
    had_warnings=true
fi
echo ""

# --- Step 7: Un-hibernate PostGIS and resume backups ------------------------
# Flips cnpg.io/hibernation off when it currently reads "on". Retries the
# annotate call itself, not a separate readiness check first — CNPG's
# admission webhook can transiently reject requests while it's still
# initializing, but there's no need to poll operator health separately
# before finding that out; the retry loop surfaces the same failure with a
# clear message if the operator genuinely isn't there.
if kubectl get cluster postgis-cluster -n databases &> /dev/null; then
  hib=$(kubectl get cluster postgis-cluster -n databases \
    -o jsonpath='{.metadata.annotations.cnpg\.io/hibernation}' 2>/dev/null) || hib=""

  if [ "$hib" == "on" ]; then
    echo "⏳ Rehydrating postgis-cluster from hibernation..."

    retries=0
    success=false
    until [ $retries -ge 6 ]; do
        if kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off 2>/dev/null; then
            success=true
            break
        fi
        sleep 5
        retries=$((retries+1))
        echo "   ...still retrying re-hydration of database... ($((retries * 5))s elapsed)"
    done
    if [ "$success" = true ]; then
        echo "✅ postgis-cluster un-hibernated successfully."
    else
        echo "⚠️  Could not un-hibernate postgis-cluster (webhook timed out). Startup continues."
        echo "💡 TROUBLESHOOTING: Once the cluster settles, run manually:"
        echo "   kubectl annotate cluster postgis-cluster -n databases --overwrite cnpg.io/hibernation=off"
        had_warnings=true
    fi
  fi
fi

sbs=$(kubectl get scheduledbackup -n databases -o name 2>/dev/null) || sbs=""
if [ -n "$sbs" ]; then
    echo "▶️  Resuming scheduled backups..."
    for sb in $sbs; do
        kubectl patch "$sb" -n databases --type merge -p '{"spec":{"suspend":false}}' 2>/dev/null || true
    done
fi
echo ""

if [ "$had_warnings" = true ]; then
    echo "⚠️  Cluster startup sequence complete, review warnings above."
    echo "   Check Headlamp, 'flux get kustomizations', or 'kubectl cnpg status postgis-cluster -n databases' for full health."
    exit 1
else
    echo "✅ Cluster startup sequence complete."
    echo "   Check Headlamp or 'flux get kustomizations' as everything else settles."
fi
