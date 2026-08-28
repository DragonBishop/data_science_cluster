#!/bin/bash
#
# bootstrap-transit.sh: Deploys and initializes the host-level Transit Vault
# (see INSTALLATION.md Reference, section 1). Idempotent — safe to re-run;
# each phase checks existing state first.
#
set -eu
had_warnings=false

VAULT_ADDR="https://127.0.0.1:8200"
VAULT_CACERT="/opt/vault/tls/tls.crt"
export VAULT_ADDR VAULT_CACERT

# --- Step 1: Package, TLS, service -------------------------------------------
echo "🚀 Deploying host Transit Vault..."
if command -v vault >/dev/null 2>&1; then
    echo "✅ vault already installed, skipping."
elif command -v apt >/dev/null 2>&1; then
    echo "📦 Installing HashiCorp apt repo and vault package..."
    if [ ! -f /etc/apt/sources.list.d/hashicorp.list ]; then
        wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
        sudo apt update
    fi
    sudo apt install -y vault
elif command -v dnf >/dev/null 2>&1; then
    echo "📦 Installing HashiCorp dnf repo and vault package..."
    if [ ! -f /etc/yum.repos.d/hashicorp.repo ]; then
        sudo dnf install -y dnf5-plugins
        sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
    fi
    sudo dnf install -y vault
else
    echo "❌ ERROR: No supported package manager (apt or dnf) found. Install 'vault' manually: https://developer.hashicorp.com/vault/install"
    exit 1
fi

if [ -f "$VAULT_CACERT" ]; then
    echo "✅ Host Transit Vault TLS cert already present, skipping."
else
    echo "🔐 Generating host Transit Vault TLS cert..."
    sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout /opt/vault/tls/tls.key \
        -out /opt/vault/tls/tls.crt \
        -subj "/CN=vault.local" \
        -addext "subjectAltName=DNS:vault.local,DNS:localhost,IP:127.0.0.1"
    sudo chown vault:vault /opt/vault/tls/tls.key /opt/vault/tls/tls.crt
    sudo chmod 640 /opt/vault/tls/tls.key
    sudo chmod 644 /opt/vault/tls/tls.crt
    sudo chmod o+x /opt/vault/tls
fi

grep -q "vault.local" /etc/hosts || echo "127.0.0.1 vault.local" | sudo tee -a /etc/hosts > /dev/null

sudo mkdir -p /etc/vault.d
sudo mkdir -p /opt/vault/data
sudo chown vault:vault /opt/vault/data
printf 'api_addr = "https://vault.local:8200"\n\nstorage "file" {\n  path = "/opt/vault/data"\n}\n\nlistener "tcp" {\n  address       = "0.0.0.0:8200"\n  tls_cert_file = "/opt/vault/tls/tls.crt"\n  tls_key_file  = "/opt/vault/tls/tls.key"\n}\n' | sudo tee /etc/vault.d/vault.hcl > /dev/null
sudo systemctl enable --now vault
echo "✅ Host Transit Vault service ready."
echo ""

# --- Step 2: Init, unseal, login ----------------------------------------------
host_initialized() {
    vault status -format=json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('initialized', False))" 2>/dev/null || echo "unknown"
}

unseal_keys=()
root_token=""
fresh_init=false

state=$(host_initialized)
if [ "$state" = "True" ]; then
    echo "✅ Host Transit Vault already initialized."
elif [ "$state" = "False" ]; then
    echo "🔑 Initializing host Transit Vault (SAVE THESE — shown once)..."
    init_json=$(vault operator init -format=json)
    echo "$init_json" | python3 -m json.tool
    mapfile -t unseal_keys < <(echo "$init_json" | python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)['unseal_keys_b64'][:3]]")
    root_token=$(echo "$init_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])")
    fresh_init=true
    for k in "${unseal_keys[@]}"; do
        printf '%s\n' "$k" | vault write sys/unseal key=- > /dev/null
    done
    vault login -no-print "$root_token"
    echo ""
    echo "== 🔑 SAVE THESE NOW — nothing above is recoverable if lost =="
    echo "Host Transit Vault (${VAULT_ADDR}):"
    for k in "${unseal_keys[@]}"; do echo "  Unseal Key: $k"; done
    echo "  Root Token: $root_token"
    echo ""
    echo "✅ Host Transit Vault initialized and unsealed."
else
    echo "❌ ERROR: Cannot reach the host Transit Vault at $VAULT_ADDR."
    vault status
    exit 1
fi
echo ""

# --- Step 3: GPG-encrypted unseal keyfile ------------------------------------
KEYFILE="$HOME/.vault-keys.gpg"
if [ -f "$KEYFILE" ] && [ "$fresh_init" != true ]; then
    echo "✅ $KEYFILE already present, skipping."
elif [ "$fresh_init" = true ]; then
    echo "🔑 Enter a GPG passphrase to encrypt the unseal keyfile:"
    WORKDIR=/dev/shm/vault-setup
    mkdir -p "$WORKDIR"
    printf '%s\n' "${unseal_keys[@]}" > "$WORKDIR/keys.txt"
    gpg --batch --yes --cipher-algo AES256 --symmetric "$WORKDIR/keys.txt"
    mv "$WORKDIR/keys.txt.gpg" "$KEYFILE"
    chmod 600 "$KEYFILE"
    rm -rf "$WORKDIR"
    mkdir -p ~/.gnupg
    if ! grep -q "^default-cache-ttl 0$" ~/.gnupg/gpg-agent.conf 2>/dev/null; then
        printf 'default-cache-ttl 0\nmax-cache-ttl 0\n' >> ~/.gnupg/gpg-agent.conf
    fi
    gpgconf --reload gpg-agent
    echo "✅ Wrote $KEYFILE."
else
    echo "❌ ERROR: $KEYFILE missing and no keys captured this run (Vault was already initialized by someone else)."
    echo "💡 TROUBLESHOOTING: see INSTALLATION.md Reference, section 1, for manual keyfile creation."
    had_warnings=true
fi
echo ""

# --- Step 4: vault-agent-autounseal systemd service --------------------------
printf 'vault {\n  address = "%s"\n  ca_cert = "%s"\n}\nauto_auth {\n  method "token_file" {\n    config = { token_file_path = "%s/.vault-agent/autounseal-token" }\n  }\n}\n' "$VAULT_ADDR" "$VAULT_CACERT" "$HOME" | sudo tee /etc/vault-agent-autounseal.hcl > /dev/null
printf '[Unit]\nDescription=Vault Agent - transit auto-unseal token renewal\nAfter=vault.service\nRequires=vault.service\n\n[Service]\nExecStart=/usr/bin/vault agent -config=/etc/vault-agent-autounseal.hcl\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n' | sudo tee /etc/systemd/system/vault-agent-autounseal.service > /dev/null
sudo systemctl daemon-reload
sudo systemctl enable vault-agent-autounseal
if [ -f "$HOME/.vault-agent/autounseal-token" ]; then
    sudo systemctl start vault-agent-autounseal
    echo "✅ vault-agent-autounseal enabled and running."
else
    echo "✅ vault-agent-autounseal enabled — will be started by bootstrap-cluster.sh Step 7 once its token file exists."
fi
echo ""

if [ "$had_warnings" = true ]; then
    echo "⚠️  Host Transit Vault setup complete, review warnings above."
    exit 1
else
    echo "✅ Host Transit Vault setup complete."
fi
