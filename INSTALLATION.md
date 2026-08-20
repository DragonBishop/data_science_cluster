# First-Time Setup Instructions

This setup workflow is designed to be completed sequentially. Deviating from this order may result in initialization failures.

## Prerequisites

**Host Tooling:** Ensure the following CLI tools are installed on the host:

- Flux CLI
- OpenTofu
- PostgreSQL client (`psql`)
- GitHub CLI (`gh`)

```bash
sudo apt install -y postgresql-client-common postgresql-client
curl -s https://fluxcd.io/install.sh | sudo bash
flux check --pre
gh auth status

curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh
sudo ./install-opentofu.sh --install-method standalone
rm install-opentofu.sh
tofu version
```

**Host Firewall (`ufw`):** If `ufw` is active, configure it to allow Cilium network interfaces and set the default forward policy to `ACCEPT`:

```bash
sudo ufw allow in on cilium_host
sudo ufw allow in on cilium_net
sudo ufw allow in on cilium_vxlan
sudo ufw allow in on lxc+
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw reload
```

**Verify Firewall Configuration:**

```bash
sudo ufw status verbose
# Ensure DEFAULT_FORWARD_POLICY is accept (routed)
# Ensure cilium_host, cilium_net, cilium_vxlan, and lxc+ are ALLOW IN
```

---

## 1. Clone Repo and Install k3s

- **Clone the repository:**

```bash
git clone https://github.com/DragonBishop/data_science_cluster.git
cd data_science_cluster
```

> [!NOTE]
> If reinstalling on a host with an existing k3s installation, run `/usr/local/bin/k3s-uninstall.sh` and verify Cilium BPF mounts are unmounted (`mount | grep bpf`; see `troubleshooting.md`). Reinstalling wipes in-cluster Vault and PVC data.

- **Configure Network Values:**

The cluster uses network values defined in a `cluster-config` Secret in the `flux-system` namespace. These values are substituted into manifests during Flux reconciliation (`postBuild.substituteFrom` in `clusters/local/*.yaml`). The Secret is managed via OpenTofu from `terraform/cluster-config/terraform.tfvars` (gitignored).

| Target File | Variable | Description |
| --- | --- | --- |
| `infrastructure/cilium/lan-lb-pool.yaml` | `${GATEWAY_IP}` | Load balancer IP pool start address |
| `infrastructure/gateway/gateway.yaml` | `${GATEWAY_IP}` | Shared Gateway IP address |
| `apps/databases/postgis-tls.yaml` | `${GATEWAY_IP}` | Certificate SAN |
| `infrastructure/coredns-custom/coredns-lan-service.yaml` | `${COREDNS_LAN_IP}` | LAN-facing IP for CoreDNS |
| `infrastructure/coredns-custom/coredns-custom.yaml` | `${GATEWAY_IP}` | Gateway IP target for `*.internal` DNS resolution |
| `infrastructure/cilium/cilium-release.yaml` | `${CILIUM_VERSION}` | Cilium HelmRelease chart version |
| `infrastructure/vault/vault-networkpolicy.yaml` | `${HOST_IP}` | Node IP address for Vault egress to host Transit Vault |

To update any of these values, modify `terraform.tfvars` and re-apply with `tofu apply`.

In-cluster CoreDNS (`kube-system`) resolves `*.internal` for LAN clients via `infrastructure/coredns-custom/` alongside standard cluster DNS.

Verify that the reserved IP range (`192.0.2.240`–`192.0.2.250`) is excluded from your router's DHCP pool:

```bash
ping -c 2 -W 1 192.0.2.240
ping -c 2 -W 1 192.0.2.242
```

- **Install k3s:**

Cilium replaces kube-proxy, Traefik, servicelb, and the default CNI. Configure `/etc/rancher/k3s/config.yaml` with the necessary flags before running the installer:

```bash
mkdir -p ~/.kube

sudo mkdir -p /etc/rancher/k3s
printf 'write-kubeconfig-mode: "644"\nwrite-kubeconfig: %s/.kube/config\ndisable:\n  - traefik\n  - servicelb\ndisable-kube-proxy: true\ndisable-network-policy: true\nflannel-backend: none\nsecrets-encryption: true\n' "$HOME" | sudo tee /etc/rancher/k3s/config.yaml > /dev/null

curl -sfL https://get.k3s.io | sh -

kubectl get nodes
```

- **Check:** Verify the node appears with status `NotReady` (expected until Cilium CNI is installed).

- **Create the `cluster-config` Secret:**

```bash
cd terraform/cluster-config
cat > terraform.tfvars <<'EOF'
gateway_ip     = "192.0.2.240"
coredns_lan_ip = "192.0.2.242"
host_ip        = "<this node's own LAN IP, e.g. from `ip addr` or `hostname -I`>"
cilium_version = "1.20.0"
EOF
tofu init
tofu apply
cd ../..
```

- **Check:**

```bash
kubectl get secret cluster-config -n flux-system
```

---

## 2. Cilium

Install the Gateway API Custom Resource Definitions (CRDs) using server-side apply:

```bash
kubectl apply --server-side -f infrastructure/gateway-api-crds/standard-install.yaml
```

Install the Cilium Helm chart matching the version declared in `infrastructure/cilium/cilium-release.yaml`:

```bash
CILIUM_VERSION=$(grep 'version:' infrastructure/cilium/cilium-release.yaml | tr -d ' "' | cut -d: -f2)
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium --version "$CILIUM_VERSION" \
  --namespace kube-system --create-namespace \
  -f infrastructure/cilium/cilium-values.yaml \
  --atomic --timeout 5m
```

**Check:**

```bash
kubectl get nodes                          # Status: Ready
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
# KubeProxyReplacement: True

kubectl -n kube-system get cm cilium-config -o yaml | grep enable-l2-announcements
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -A2 l2-responder
# enable-l2-announcements: "true", l2-responder [OK] Running
```

---

## 3. Deploy the Host-Level Transit Vault

The host Transit Vault runs directly on the host system to provide auto-unseal capabilities for the in-cluster Vault.

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update && sudo apt install -y vault
```

Generate the TLS certificate for the host Transit Vault:

```bash
sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout /opt/vault/tls/tls.key \
  -out /opt/vault/tls/tls.crt \
  -subj "/CN=vault.local" \
  -addext "subjectAltName=DNS:vault.local,DNS:localhost,IP:127.0.0.1"
sudo chown vault:vault /opt/vault/tls/tls.key /opt/vault/tls/tls.crt
sudo chmod 640 /opt/vault/tls/tls.key
sudo chmod 644 /opt/vault/tls/tls.crt
sudo chmod o+x /opt/vault/tls
```

Add `127.0.0.1 vault.local` to `/etc/hosts`.

Configure `/etc/vault.d/vault.hcl`:

```hcl
api_addr = "https://vault.local:8200"

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/opt/vault/tls/tls.crt"
  tls_key_file  = "/opt/vault/tls/tls.key"
}
```

Enable the service and initialize Vault:

```bash
sudo systemctl enable --now vault

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"
vault operator init
```

> [!CRITICAL]
> Store the generated 5 unseal keys and initial root token in a secure password manager immediately. Data cannot be recovered if these keys are lost.

Unseal the Transit Vault by providing three unseal keys:

```bash
vault operator unseal
```

Log in using the root token:

```bash
vault login
```

**Automate Future Host Vault Unsealing:**

`src/bash/start-cluster.sh` can automatically decrypt keys from a GPG-encrypted keyfile.

Generate the encrypted keyfile using a temporary RAM disk:

```bash
mkdir -p /dev/shm/vault-setup && cd /dev/shm/vault-setup
nano keys.txt
# Paste the 3 unseal keys into keys.txt (one per line)

gpg --batch --yes --cipher-algo AES256 --symmetric keys.txt
mv keys.txt.gpg ~/.vault-keys.gpg
chmod 600 ~/.vault-keys.gpg
cd / && rm -rf /dev/shm/vault-setup
```

Configure `gpg-agent` to expire passphrase caching immediately:

```bash
cat >> ~/.gnupg/gpg-agent.conf <<'EOF'
default-cache-ttl 0
max-cache-ttl 0
EOF
gpgconf --reload gpg-agent
```

---

## 4. Bootstrap Flux

Bootstrap Flux into the repository:

```bash
flux bootstrap github \
  --owner=DragonBishop \
  --repository=data_science_cluster \
  --branch=main \
  --path=clusters/local \
  --personal
```

Flux synchronizes the repository and reconciles the Kustomization dependency graph:

```mermaid
flowchart TD
    %% Base Foundations
    crds["gateway-api-crds"] --> cilium["cilium"]
    ns["namespaces"] --> cilium

    %% Core Services & PKI
    cilium --> coredns["coredns-custom"]
    cilium --> fluxpolicies["flux-system-policies"]
    cilium --> certmgr["cert-manager"]
    certmgr --> vault["vault"]

    %% Platform Services
    vault --> vso["vault-secrets-operator"]
    vso --> cnpg["cnpg-operator"]
    cnpg --> barman["barman-cloud"]

    vault --> gw["gateway"]
    gw --> hubble["hubble"]

    %% Applications
    barman --> db["databases"]
    vault --> db
    gw --> db
```

- `cilium` requires `gateway-api-crds` and `namespaces`.
- `coredns-custom`, `flux-system-policies`, and `cert-manager` depend on `cilium`.
- `vault` depends on `cert-manager` (for `vault-server-cert` TLS bootstrap).
- `vault-secrets-operator` and `gateway` depend on `vault` (for PKI and secrets sync).
- `cnpg-operator` depends on `vault-secrets-operator`, and `barman-cloud` depends on `cnpg-operator`.
- `hubble` depends on `gateway` (attaching the `hubble.internal` HTTPRoute).
- `databases` depends on `barman-cloud`, `gateway`, and `vault`.

**Check:**

```bash
flux get kustomizations
kubectl get pods -n flux-system   # All Running
kubectl get ns
# Namespaces: vault, vso-system, cnpg-system, databases, cert-manager, gateway
```

---

## 5. Deploy In-Cluster HashiCorp Vault

Configure the host Transit Vault resources required for in-cluster auto-unsealing.

Set environment variables pointing to the host Transit Vault:

```bash
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"
vault status
```

If the host Transit Vault is sealed, unseal it using the GPG keyfile:

```bash
gpg --quiet --decrypt "$HOME/.vault-keys.gpg" | while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\n' "$key" | vault write sys/unseal key=-
done
vault status   # Sealed: false
```

Apply the `terraform/vault-transit-bootstrap` module to configure the transit mount, autounseal key, policy, periodic orphan token, and Kubernetes Secret objects in the `vault` namespace:

```bash
export VAULT_TOKEN=$(cat ~/.vault-token)
read -rs -p "State encryption passphrase: " TF_VAR_state_encryption_passphrase; echo
export TF_VAR_state_encryption_passphrase

cd terraform/vault-transit-bootstrap
tofu init
tofu apply

unset VAULT_TOKEN TF_VAR_state_encryption_passphrase
cd ../..
```

**Configure Continuous Token Renewal:**

Set up the `vault-agent-autounseal` systemd service to renew the transit auto-unseal token periodically:

```bash
printf 'vault {\n  address = "https://127.0.0.1:8200"\n  ca_cert = "/opt/vault/tls/tls.crt"\n}\nauto_auth {\n  method "token_file" {\n    config = { token_file_path = "%s/.vault-agent/autounseal-token" }\n  }\n}\n' "$HOME" | sudo tee /etc/vault-agent-autounseal.hcl > /dev/null

printf '[Unit]\nDescription=Vault Agent - transit auto-unseal token renewal\nAfter=vault.service\nRequires=vault.service\n\n[Service]\nExecStart=/usr/bin/vault agent -config=/etc/vault-agent-autounseal.hcl\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n' | sudo tee /etc/systemd/system/vault-agent-autounseal.service > /dev/null

sudo systemctl daemon-reload
sudo systemctl enable --now vault-agent-autounseal
systemctl status vault-agent-autounseal   # active (running)
```

**Reconcile and Initialize the In-Cluster Vault:**

```bash
flux reconcile kustomization vault
kubectl get pods -n vault -w
```

Initialize the in-cluster Vault instance. This returns recovery keys and a root token:

```bash
kubectl exec -n vault vault-0 -- vault operator init
```

> [!IMPORTANT]
> Save the recovery keys and root token in your password manager immediately.

**Configure Vault Engines and Policies:**

Configure KV secrets, Kubernetes authentication, policies, the 2-tier PKI engine, and database secrets engine via `terraform/vault/`:

```bash
just vault-pf

read -rs -p "Vault root token (above): " VAULT_TOKEN; echo
read -rs -p "State encryption passphrase: " TF_VAR_state_encryption_passphrase; echo
export VAULT_TOKEN TF_VAR_state_encryption_passphrase

export TF_VAR_postgres_superuser_password=$(openssl rand -base64 24)
export TF_VAR_s3_access_key=$(openssl rand -hex 10)
export TF_VAR_s3_secret_key=$(openssl rand -hex 20)

cd terraform/vault
tofu init
tofu apply
cd ../..
```

**Verify Configuration:**

```bash
vault kv get secret/postgis
vault kv get secret/seaweedfs
vault read pki_int/roles/internal-server
vault read auth/kubernetes/role/cert-manager-pki-role
head -c 200 terraform/vault/terraform.tfstate
```

Ensure the tfstate file is encrypted (non-plaintext output).

Clean up environment variables:

```bash
unset VAULT_TOKEN TF_VAR_state_encryption_passphrase TF_VAR_postgres_superuser_password TF_VAR_s3_access_key TF_VAR_s3_secret_key
```

---

## 6. Flux Kustomization Rollout

Trigger reconciliation of the remaining cluster resources:

```bash
flux reconcile kustomization flux-system --with-source
```

**Check:**

```bash
flux get kustomizations
```

```bash
helm list -n kube-system  
# Verify cilium release is updated (REVISION 2)

kubectl get ciliumloadbalancerippool
# Verify lan-ip-pool shows allocated IPs (internal-gateway, coredns-external)

kubectl get gateway -n gateway internal-gateway -o wide
# Status: PROGRAMMED True, IP: 192.0.2.240

kubectl get svc -n kube-system coredns-external
# EXTERNAL-IP: 192.0.2.242

# Restart CoreDNS once to mount custom ConfigMap:
kubectl rollout restart deployment coredns -n kube-system

kubectl wait --for=condition=Available --timeout=120s -n cert-manager deployment --all

kubectl get clusterissuer vault-pki-issuer   # Ready

kubectl rollout status deployment -n cnpg-system plugin-barman-cloud

kubectl get svc,pods -n databases -l app.kubernetes.io/instance=seaweedfs --show-labels
```

```bash
kubectl cnpg status postgis-cluster -n databases
# Status: Healthy, 1/1 Ready, WAL archiving OK
```

```bash
helm get values cilium -n kube-system   # Verify hubble configuration is present
kubectl get pods -n kube-system -l 'k8s-app in (hubble-relay,hubble-ui)'
# Status: Running (1/1 and 2/2)

kubectl get httproute -n kube-system hubble-ui -o jsonpath='{.status.parents[*].conditions[*].message}'
# "Accepted" and "Service reference is valid"
```

If the Hubble configuration is not yet reflected in `helm get values`, trigger a reconciliation:

```bash
flux reconcile helmrelease cilium -n kube-system --timeout 5m
```

**Hubble Access:**

- `just hubble-ui` port-forwards to `localhost:12000` and opens the UI in a browser.
- `just hubble status` and `just hubble observe --follow` connect to Hubble Relay over mTLS (port 4245).

---

## 7. Deploy CloudNativePostgreSQL Database Server with PostGIS

### Verify Database Deployment

```bash
kubectl cnpg status postgis-cluster -n databases
# Status: Healthy, 1/1 ready, WAL archiving OK

kubectl get database -n databases
# Status: postgis-cluster/data-science, status.applied: true

kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d data_science -c '\dx'
# Verify extensions: postgis, postgis_topology, postgis_tiger_geocoder, fuzzystrmatch

kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d postgres -c \
  "SELECT datname, pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='data_science';"
# Owner should be app_readwrite

kubectl get tcproute -n databases postgis-external -o jsonpath='{.status.parents[*].conditions[*].message}'
# "Service reference is valid"
```

### Test LAN Database Connectivity

```bash
just db-connect
```

Or shell command:

```bash
LEASE_USER=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
LEASE_PASS=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
mkdir -p ~/.postgresql
[ -f ~/.postgresql/root.crt ] || kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt
PGPASSWORD="$LEASE_PASS" psql "host=192.0.2.240 port=5432 dbname=data_science user=$LEASE_USER sslmode=verify-full"
```

### Test Localhost Database Connectivity

On the k3s node itself, `CiliumLocalRedirectPolicy` redirects `127.0.0.1:5432` to the CNPG primary pod:

```bash
just db-connect localhost
```

Or shell command (same as above, with `host=localhost`):

```bash
LEASE_USER=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
LEASE_PASS=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
mkdir -p ~/.postgresql
[ -f ~/.postgresql/root.crt ] || kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt
PGPASSWORD="$LEASE_PASS" psql "host=localhost port=5432 dbname=data_science user=$LEASE_USER sslmode=verify-full"
```

Reachable only from the node itself, not other LAN machines.

### Migrate Existing PostgreSQL Data

If migrating data from an existing database dump, restore it into the new cluster:

```bash
kubectl exec -i postgis-cluster-1 -n databases -- pg_restore -U postgres -d data_science --no-owner --no-privileges \
  < /mnt/your/mount/path/data_science_backup_*.dump
```

The `--no-owner --no-privileges` flags ensure restored objects inherit ownership under `app_readwrite`.

Verify restored schemas:

```bash
kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d data_science -c '\dn'
# Verify expected schemas are listed
```

---

## 8. Dynamic Database Role and Access Verification

Once the CNPG cluster is healthy and VSO reconciles `apps/databases/vso-setup.yaml`, VSO requests credentials from Vault and writes them to the `postgis-app-dynamic-credentials` Secret.

### Verify Dynamic Credentials

```bash
kubectl get vaultdynamicsecret postgis-app-dynamic-secret -n databases
kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d postgres -c '\du'
# Issued role should show: Member of: app_readwrite

just db-connect
```

Or shell command:

```bash
LEASE_USER=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
LEASE_PASS=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
mkdir -p ~/.postgresql
[ -f ~/.postgresql/root.crt ] || kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt
PGPASSWORD="$LEASE_PASS" psql "host=192.0.2.240 port=5432 dbname=data_science user=$LEASE_USER sslmode=verify-full"
```

> [!NOTE]
> Run this verification command from the host, as `~/.postgresql/root.crt` is located in the host's home directory.

---

## 9. Full End-to-End Verification

Verify cluster health, backups, and Flux status:

```bash
kubectl cnpg status postgis-cluster -n databases        # Healthy, WAL archiving OK
kubectl get scheduledbackup -n databases                 # suspend: false
kubectl cnpg backup postgis-cluster -n databases          # Manual backup test to SeaweedFS S3
kubectl cnpg status postgis-cluster -n databases          # Verify Last Successful Backup timestamp updates
flux get kustomizations                                   # All Kustomizations Ready
```

Verify Gateway routing and TLS termination:

```bash
curl -v --resolve hubble.internal:443:192.0.2.240 \
  --cacert <(kubectl get secret -n gateway internal-edge-cert -o jsonpath='{.data.ca\.crt}' | base64 -d) \
  https://hubble.internal/
```

Verify that the page responds and the certificate chains to `vault-pki-issuer`'s CA. `internal-edge-cert` is issued by `vault-pki-issuer` (Vault's PKI secrets engine); `vault-server-cert` is a separate, self-signed CA used only for Vault's own API TLS, and won't verify this connection.
