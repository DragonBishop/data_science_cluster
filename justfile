module_name := "clusterpgis"

# List available recipes
default:
  @just --list

# --- Bootstrap (first-time install, see INSTALLATION.md) -------------------

# Write /etc/rancher/k3s/config.yaml
k3s-config:
  #!/usr/bin/env bash
  set -eu
  mkdir -p ~/.kube
  sudo mkdir -p /etc/rancher/k3s
  printf 'write-kubeconfig-mode: "644"\nwrite-kubeconfig: %s/.kube/config\ndisable:\n  - traefik\n  - servicelb\ndisable-kube-proxy: true\ndisable-network-policy: true\nflannel-backend: none\nsecrets-encryption: true\n' "$HOME" | sudo tee /etc/rancher/k3s/config.yaml > /dev/null
  echo "✅ Wrote /etc/rancher/k3s/config.yaml"

# Write and apply terraform/cluster-config/terraform.tfvars
cluster-config:
  #!/usr/bin/env bash
  set -eu
  cd terraform/cluster-config
  if [ -f terraform.tfvars ]; then
    echo "terraform.tfvars already exists, opening it for review/edit."
  else
    DETECTED_HOST_IP=$(hostname -I | awk '{print $1}')
    printf 'gateway_ip     = "192.0.2.240"\ncoredns_lan_ip = "192.0.2.242"\nhost_ip        = "%s"\ncilium_version = "1.20.0"\n' "$DETECTED_HOST_IP" > terraform.tfvars
    echo "Wrote terraform.tfvars with detected host_ip=${DETECTED_HOST_IP} - opening for review."
  fi
  "${EDITOR:-nano}" terraform.tfvars
  tofu init
  tofu apply
  cd ../..
  echo "✅ cluster-config applied"

# Install/reinstall Cilium at the version pinned in infrastructure/cilium/cilium-release.yaml
cilium-install:
  #!/usr/bin/env bash
  set -eu
  CILIUM_VERSION=$(grep 'version:' infrastructure/cilium/cilium-release.yaml | tr -d ' "' | cut -d: -f2)
  echo "Installing Cilium ${CILIUM_VERSION}..."
  helm upgrade --install cilium oci://quay.io/cilium/charts/cilium --version "$CILIUM_VERSION" \
    --namespace kube-system --create-namespace \
    -f infrastructure/cilium/cilium-values.yaml \
    --atomic --timeout 5m
  echo "✅ Cilium ${CILIUM_VERSION} installed"

# Generate the host Transit Vault's TLS certificate
vault-host-tls:
  #!/usr/bin/env bash
  set -eu
  sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout /opt/vault/tls/tls.key \
    -out /opt/vault/tls/tls.crt \
    -subj "/CN=vault.local" \
    -addext "subjectAltName=DNS:vault.local,DNS:localhost,IP:127.0.0.1"
  sudo chown vault:vault /opt/vault/tls/tls.key /opt/vault/tls/tls.crt
  sudo chmod 640 /opt/vault/tls/tls.key
  sudo chmod 644 /opt/vault/tls/tls.crt
  sudo chmod o+x /opt/vault/tls
  echo "✅ Generated /opt/vault/tls/tls.{key,crt}"

# Enable the host Transit Vault service, initialize it, unseal it, and log in
vault-host-init:
  #!/usr/bin/env bash
  set -eu
  sudo systemctl enable --now vault
  export VAULT_ADDR="https://127.0.0.1:8200"
  export VAULT_CACERT="/opt/vault/tls/tls.crt"
  vault operator init
  echo ""
  echo "⚠️  Save the 5 unseal keys and root token above in a password manager now."
  echo ""
  for _ in 1 2 3; do
    vault operator unseal
  done
  vault login

# Create the GPG-encrypted unseal keyfile start-cluster.sh reads
vault-keyfile:
  #!/usr/bin/env bash
  set -eu
  WORKDIR=/dev/shm/vault-setup
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"
  echo "Paste the 3 unseal keys into keys.txt, one per line, then save and exit."
  "${EDITOR:-nano}" keys.txt
  gpg --batch --yes --cipher-algo AES256 --symmetric keys.txt
  mv keys.txt.gpg ~/.vault-keys.gpg
  chmod 600 ~/.vault-keys.gpg
  cd /
  rm -rf "$WORKDIR"
  echo "✅ Wrote ~/.vault-keys.gpg"
  mkdir -p ~/.gnupg
  if ! grep -q "^default-cache-ttl 0$" ~/.gnupg/gpg-agent.conf 2>/dev/null; then
    printf 'default-cache-ttl 0\nmax-cache-ttl 0\n' >> ~/.gnupg/gpg-agent.conf
  fi
  gpgconf --reload gpg-agent
  echo "✅ gpg-agent cache disabled"

# Unseal the host Transit Vault (via the GPG keyfile) and apply terraform/vault-transit-bootstrap
vault-transit-bootstrap:
  #!/usr/bin/env bash
  set -eu
  export VAULT_ADDR="https://127.0.0.1:8200"
  export VAULT_CACERT="/opt/vault/tls/tls.crt"
  rc=0
  vault status > /dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "🔒 Host Transit Vault is sealed, unsealing via ~/.vault-keys.gpg..."
    gpg --quiet --decrypt "$HOME/.vault-keys.gpg" | while IFS= read -r key; do
      [ -n "$key" ] || continue
      printf '%s\n' "$key" | vault write sys/unseal key=- > /dev/null
    done
  elif [ "$rc" -ne 0 ]; then
    echo "❌ ERROR: Cannot reach the host Transit Vault at $VAULT_ADDR."
    vault status
    exit 1
  fi
  export VAULT_TOKEN
  VAULT_TOKEN=$(cat ~/.vault-token)
  read -rs -p "State encryption passphrase: " TF_VAR_state_encryption_passphrase; echo
  export TF_VAR_state_encryption_passphrase
  cd terraform/vault-transit-bootstrap
  tofu init
  tofu apply
  cd ../..
  unset VAULT_TOKEN TF_VAR_state_encryption_passphrase
  echo "✅ terraform/vault-transit-bootstrap applied"

# Install and start the vault-agent-autounseal systemd service
vault-autounseal-agent:
  #!/usr/bin/env bash
  set -eu
  printf 'vault {\n  address = "https://127.0.0.1:8200"\n  ca_cert = "/opt/vault/tls/tls.crt"\n}\nauto_auth {\n  method "token_file" {\n    config = { token_file_path = "%s/.vault-agent/autounseal-token" }\n  }\n}\n' "$HOME" | sudo tee /etc/vault-agent-autounseal.hcl > /dev/null
  printf '[Unit]\nDescription=Vault Agent - transit auto-unseal token renewal\nAfter=vault.service\nRequires=vault.service\n\n[Service]\nExecStart=/usr/bin/vault agent -config=/etc/vault-agent-autounseal.hcl\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n' | sudo tee /etc/systemd/system/vault-agent-autounseal.service > /dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now vault-agent-autounseal
  systemctl status vault-agent-autounseal --no-pager

# Apply terraform/vault (KV, Kubernetes auth, PKI, database secrets engine) and verify it
vault-engines:
  #!/usr/bin/env bash
  set -eu
  just vault-pf
  read -rs -p "Vault root token (above): " VAULT_TOKEN; echo
  read -rs -p "State encryption passphrase: " TF_VAR_state_encryption_passphrase; echo
  export VAULT_TOKEN TF_VAR_state_encryption_passphrase
  export TF_VAR_postgres_superuser_password
  TF_VAR_postgres_superuser_password=$(openssl rand -base64 24)
  export TF_VAR_s3_access_key
  TF_VAR_s3_access_key=$(openssl rand -hex 10)
  export TF_VAR_s3_secret_key
  TF_VAR_s3_secret_key=$(openssl rand -hex 20)
  cd terraform/vault
  tofu init
  tofu apply
  cd ../..
  echo ""
  echo "== Verify Configuration =="
  vault kv get secret/postgis
  vault kv get secret/seaweedfs
  vault read pki_int/roles/internal-server
  vault read auth/kubernetes/role/cert-manager-pki-role
  echo -n "tfstate head (should be encrypted, non-plaintext): "
  head -c 200 terraform/vault/terraform.tfstate
  echo ""
  unset VAULT_TOKEN TF_VAR_state_encryption_passphrase TF_VAR_postgres_superuser_password TF_VAR_s3_access_key TF_VAR_s3_secret_key
  echo "✅ terraform/vault applied and verified"

# --- Cluster lifecycle -------------------------------------------------

# Start the cluster
start:
  ./src/bash/start-cluster.sh

# Stop the cluster (pass --force to skip confirmation on a stuck stop)
stop *ARGS:
  ./src/bash/stop-cluster.sh {{ARGS}}

# Fuzzy-select a pod (all namespaces) and describe it
fuzzypods:
  kubectl get pods -A --no-headers | fzf | awk '{print $2, $1}' | xargs -n 2 sh -c 'kubectl describe pod $0 -n $1'

# Read-only cluster health check (Flux, Gateway/DNS, cert-manager, database, backups, Hubble)
status:
  #!/usr/bin/env bash
  set -uo pipefail
  echo "== Flux =="
  flux get kustomizations

  echo ""
  echo "== Gateway / DNS =="
  kubectl get ciliumloadbalancerippool
  kubectl get gateway -n gateway internal-gateway -o wide
  kubectl get svc -n kube-system coredns-external

  echo ""
  echo "== cert-manager =="
  kubectl get clusterissuer vault-pki-issuer

  echo ""
  echo "== Database =="
  kubectl cnpg status postgis-cluster -n databases
  kubectl get database -n databases
  echo -n "TCPRoute: "; kubectl get tcproute -n databases postgis-external -o jsonpath='{.status.parents[*].conditions[*].message}'; echo

  echo ""
  echo "== Backups =="
  kubectl get scheduledbackup -n databases
  kubectl rollout status deployment -n cnpg-system plugin-barman-cloud --timeout=10s

  echo ""
  echo "== SeaweedFS =="
  kubectl get svc,pods -n databases -l app.kubernetes.io/instance=seaweedfs

  echo ""
  echo "== Hubble =="
  kubectl get pods -n kube-system -l 'k8s-app in (hubble-relay,hubble-ui)'
  echo -n "HTTPRoute: "; kubectl get httproute -n kube-system hubble-ui -o jsonpath='{.status.parents[*].conditions[*].message}'; echo

# --- Database ------------------------------------------------------------

# Connect via psql to postgis-cluster (HOST defaults to the live Gateway IP; pass `localhost` for the node-local path)
db-connect HOST=`kubectl get gateway -n gateway internal-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null`:
  #!/usr/bin/env bash
  set -uo pipefail
  LEASE_USER=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
  LEASE_PASS=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
  mkdir -p ~/.postgresql
  [ -f ~/.postgresql/root.crt ] || kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt
  PGPASSWORD="$LEASE_PASS" psql "host={{HOST}} port=5432 dbname=data_science user=$LEASE_USER sslmode=verify-full"

# --- Observability (Hubble) -----------------------------------------------

# Port-forward to hubble-relay on localhost:4245
hubble-pf:
  kubectl port-forward -n kube-system svc/hubble-relay 4245:443

# Run Hubble CLI command against hubble-relay
hubble *ARGS='status':
  #!/usr/bin/env bash
  set -uo pipefail
  mkdir -p ~/.hubble/tls
  [ -f ~/.hubble/tls/ca.crt ]  || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.ca\.crt}'  | base64 -d > ~/.hubble/tls/ca.crt
  [ -f ~/.hubble/tls/tls.crt ] || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.hubble/tls/tls.crt
  [ -f ~/.hubble/tls/tls.key ] || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.tls\.key}' | base64 -d > ~/.hubble/tls/tls.key

  if ! (exec 3<>/dev/tcp/127.0.0.1/4245) 2>/dev/null; then
    logf=$(mktemp)
    kubectl port-forward -n kube-system svc/hubble-relay 4245:443 >"$logf" 2>&1 &
    pf_pid=$!
    trap 'ec=$?; kill "$pf_pid" 2>/dev/null; rm -f "$logf"; exit $ec' EXIT
    for _ in $(seq 1 50); do grep -q "Forwarding from" "$logf" && break; sleep 0.1; done
  else
    exec 3<&- 3>&-
  fi

  hubble --server localhost:4245 --tls \
    --tls-server-name relay.hubble-relay.cilium.io \
    --tls-ca-cert-files ~/.hubble/tls/ca.crt \
    --tls-client-cert-file ~/.hubble/tls/tls.crt \
    --tls-client-key-file ~/.hubble/tls/tls.key \
    {{ARGS}} 2> >(grep -v --line-buffered "Hubble CLI version is lower than Hubble Relay" >&2)

# Open Hubble web UI
hubble-ui:
  #!/usr/bin/env bash
  set -uo pipefail
  mkdir -p ~/.hubble
  if ! (exec 3<>/dev/tcp/127.0.0.1/12000) 2>/dev/null; then
    nohup kubectl port-forward -n kube-system svc/hubble-ui 12000:80 >~/.hubble/ui-portforward.log 2>&1 &
    disown
    for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/12000) 2>/dev/null && break; sleep 0.1; done
  else
    exec 3<&- 3>&-
  fi
  echo "Hubble UI: http://localhost:12000"
  command -v xdg-open >/dev/null 2>&1 && xdg-open http://localhost:12000 >/dev/null 2>&1 &
  disown

# --- Vault -----------------------------------------------------------------

vault_env := "unset VAULT_TOKEN"

# Port-forward in-cluster Vault to localhost:8210 and fetch its CA
vault-pf:
  #!/usr/bin/env bash
  set -uo pipefail
  mkdir -p ~/.vault-certs
  [ -f ~/.vault-certs/vault-internal-ca.crt ] || kubectl get secret vault-server-cert -n vault -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.vault-certs/vault-internal-ca.crt
  if ! (exec 3<>/dev/tcp/127.0.0.1/8210) 2>/dev/null; then
    nohup kubectl port-forward -n vault vault-0 8210:8200 >~/.vault-certs/pf.log 2>&1 &
    disown
    for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/8210) 2>/dev/null && break; sleep 0.1; done
  else
    exec 3<&- 3>&-
  fi
  echo "Vault (in-cluster): https://127.0.0.1:8210  (CA: ~/.vault-certs/vault-internal-ca.crt)"

# Open interactive shell in vault-0 pod
vault-shell:
  kubectl exec -it vault-0 -n vault -- sh -c '{{vault_env}}; exec sh'

# Open authenticated shell in vault-0 pod
vault-login:
  kubectl exec -it vault-0 -n vault -- sh -c '{{vault_env}}; vault login && exec sh'

# --- Development -------------------------------------------------------

# Install dependencies
install:
  {{ if path_exists("uv.lock") == "true" { "uv sync --all-groups --all-extras --locked --inexact" } else { "uv sync --all-groups --all-extras --inexact" } }}

# Setup development environment
setup: install git-setup

# Run tests and generate coverage reports
test-cov:
  uv run pytest --cov=src/clusterpgis --cov-report=lcov:lcov.info --cov-report=term-missing --cov-report html --cov-report xml

# Update packages and lockfile
update:
  uv sync -U --all-groups --all-extras --inexact

# Configure nbwipers git filter
git-setup:
  @[ -d .git ] || git init
  uv run nbwipers install local
