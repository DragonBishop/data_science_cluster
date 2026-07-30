# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a PostgreSQL server with the PostGIS extension enabled. It is intended to be scalable for data science projects, such as Extract, Transform, and Load (ETL) pipelines, Machine Learning (ML), and data analytics.

This cluster's architecture relies on a system-installed HashiCorp Vault to act as a transit to unseal a cluster-situated Vault. This cluster Vault is the primary store for all secrets in the cluster. Secure provisioning of environment variables from this vault allows users to combine ease of use and best practices for Secrets Management, intended for local use but scalable for enterprises if necessary.

**This branch targets native Linux (developed and tested on Ubuntu)**. If you're running under WSL2 on Windows, see the WSL2 branch of this project instead — the two diverge around Cilium's networking mode, Headlamp access, and a few host-level setup steps.

## Core Architecture

* **k3s:** A lightweight, certified Kubernetes distribution. It acts as the core control plane and execution environment for the database and its supporting services.
* **CloudNativePG (CNPG):** A Kubernetes operator designed to manage the full lifecycle of a PostgreSQL/PostGIS database. It handles provisioning, replication, and automated disaster recovery pipelines directly via Pods and PVCs, enabling database-aware failovers.
* **Cilium:** The cluster's Container Network Interface (CNI). It replaces k3s's default networking components to provide highly efficient, eBPF-based network routing and Gateway API support.
* **HashiCorp Vault:** The system utilizes two Vault instances to solve the "secret zero" problem. A lightweight **Transit Vault** runs natively on the Linux host. The **Main Vault** runs inside the Kubernetes cluster. When the cluster boots, the Main Vault automatically authenticates against the Transit Vault to unseal itself, requiring no manual intervention. The Transit Vault itself still re-seals on every host reboot and requires one human-entered passphrase to unseal — `start-cluster.sh` automates this via a GPG-encrypted keyfile (see Step 5 below) rather than pasting 3 raw unseal keys by hand.
* **Vault Database Secrets Engine**: Vault can connect to Postgres itself and issue short-lived, per-session PostgreSQL roles on demand. Application credentials expire on a lease (an hour by default), with vault revoking the underlying role automatically.
* **Vault Secrets Operator (VSO):** A Kubernetes operator that acts as a secure bridge. It continuously reads credentials from the Main Vault and natively synchronizes them into standard Kubernetes `Secret` objects.
* **Barman Cloud Plugin:** CloudNativePG's plugin-based backup architecture. The in-tree `spec.backup.barmanObjectStore` field this project used previously is deprecated as of CNPG 1.26 and is slated for removal in 1.30, so backups and WAL archiving are configured through this plugin instead.
* **cert-manager**: Issues and renews local CA N Provides proper Subject Alternative Names (SAN), including `localhost`. Makes `sslmode=verify-full` possible. Necessary dependency for the Barman Cloud plugin.
* **SeaweedFS:** An in-cluster, S3-compatible object storage service acting as the local backup. CloudNativePG continuously streams database Write-Ahead Logs (WAL) and scheduled base backups to its storage bucket.
* **Headlamp:** Lightweight GUI to monitor cluster status and implement changes. See *WSL2* branch for workarounds to deploy Headlamp in a WSL2 stack.

## Repository Structure

* `README.md`: architecture, setup, and operations reference.
* `ROADMAP.md`: Planned future services and technical debt remediation.
* `.archive/` - A collection of manifests and scripts that are no longer in use for the project, but kept as a reference.
* `devcontainers/` - Provision a VSCode Dev Container to manage the cluster. Customize to suit your own needs!
  * `devcontainer.json`: Configuration file for a devcontainer designed to be platform and engine agnostic.
  * `Dockerfile` contains build instructions to provision a Data Science focused Dev Container.
* `scripts/`
  * `start-cluster.sh`: Sequential boot script enforcing API, Transit Vault unseal, Secret, and Database readiness state checks.
  * `stop-cluster.sh`: Graceful shutdown script utilizing CNPG declarative hibernation.
  * `sync-kubeconfig.sh`: Exports the cluster config to the Windows environment.
* `manifests/`
  * `vault-values.yaml`: Helm chart overrides, mapping the in-cluster Vault to the host Transit Vault.
  * `vault-networkpolicy.yaml`: CiliumNetworkPolicy restricting ingress to the in-cluster Vault API.
  * `vso-setup.yaml`: Provisions namespaces, service accounts, and Vault connection CRDs.
  * `postgres-tls.yaml`: cert-manager Issuers and Certificates giving CloudNativePG a server certificate with hostname-verifiable SANs (including `localhost`).
  * `seaweedfs-backups.yaml`: Provisions the S3-compatible storage pod, PVC, and automated bucket-initialization Job.
  * `postgis-cluster.yaml`: Deploys the Postgres cluster, the VaultStaticSecret sync definitions, and the `postgres-proxy` bridge deployment.

## Official Documentation

| Component | Documentation Link |
| --- | --- |
| k3s | [https://docs.k3s.io/](https://docs.k3s.io/) |
| Cilium | [https://docs.cilium.io/](https://docs.cilium.io/) |
| Gateway API | [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/) |
| HashiCorp Vault | [https://developer.hashicorp.com/vault/docs)](https://developer.hashicorp.com/vault/docs) |
| Vault Secrets Operator | [https://developer.hashicorp.com/vault/docs/vault-secrets-operator](https://developer.hashicorp.com/vault/docs/vault-secrets-operator) |
| cert-manager | [https://cert-manager.io/docs/](https://cert-manager.io/docs/) |
| CloudNativePG | [https://cloudnative-pg.io/docs](https://cloudnative-pg.io/docs) |
| CNPG Certificates | [https://cloudnative-pg.io/documentation/current/certificates/](https://cloudnative-pg.io/documentation/current/certificates/) |
| CNPG Hibernation | [https://cloudnative-pg.io/documentation/current/declarative_hibernation/](https://cloudnative-pg.io/documentation/current/declarative_hibernation/) |
| Barman Cloud Plugin | [https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/) |
| SeaweedFS | [https://github.com/seaweedfs/seaweedfs/wiki](https://github.com/seaweedfs/seaweedfs/wiki) |
| Headlamp | [https://headlamp.dev/docs/latest/](https://headlamp.dev/docs/latest/) |

---

## First-Time Setup Instructions

This setup workflow is designed to be completed sequentially. Deviating from this order may result in initialization failures.

### 1. Install k3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable traefik --disable servicelb --disable-kube-proxy --disable-network-policy --flannel-backend=none" sh -
```

The default installation configures k3s as an auto-starting systemd service. This ensures the cluster survives WSL restarts independently, allowing setup to span multiple sessions without custom lifecycle scripting.

The `INSTALL_K3S_EXEC` flags configure the startup environment, specifically disabling default k3s networking components to allow Cilium to manage the network:

* `--disable traefik` and `--disable servicelb`: Skips k3s's bundled addon manifests (Traefik ingress controller, Klipper LoadBalancer).
* `--disable-kube-proxy`: Turns off the built-in kube-proxy supervisor component. 
* `--flannel-backend=none` and `--disable-network-policy`: Prevents the default CNI and network policies from loading, deferring routing and enforcement entirely to Cilium.
* `--write-kubeconfig-mode 644`: Sets read permissions for the kubeconfig file so standard, non-root users can execute `kubectl` and `helm` commands without triggering permission errors.

Systemd manages the cluster during the initial build phase, with custom lifecycle scripts (`scripts/start-cluster.sh` and `scripts/stop-cluster.sh`) provided to take over management once the build is complete.

### 2. Install Cilium

**Prerequisites:** `k3s` must be installed with the `--disable-kube-proxy` boolean flag and `--flannel-backend=none` per Step 2. Cilium's `kubeProxyReplacement` only fully assumes L4 routing if the native `kube-proxy` is genuinely disabled.

#### 2a. Install the Gateway API CRDs

Gateway API Custom Resource Definitions (CRDs) must be installed prior to Cilium. The CRD version must strictly align with the requirements of the deployed Cilium release (e.g., Cilium 1.19.x requires Gateway API v1.4.1). A version mismatch results in silent failures, leaving the GatewayClass in an `ACCEPTED: Unknown` state. This deployment utilizes the standard (GA) release channel.

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
```

The `--server-side` flag is mandatory because these manifests exceed the annotation size limit utilized by client-side apply operations.

#### 2b. Install the Cilium CLI

Retrieve the latest stable CLI release and install the executable to `/usr/local/bin` for system-wide access.

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz
```

Deploy Cilium and wait for daemonsets to report healthy:

```bash
cilium install --set gatewayAPI.enabled=true --set kubeProxyReplacement=true
cilium status --wait
```

Verify the node is ready:

```bash
kubectl get nodes
```

### 3. Deploy the Host-Level Transit Vault

This Vault instance runs directly on the host and serves to unlock the cluster's Main Vault.

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y vault
```

Generate a local TLS certificate allowing secure communication from within the cluster:

```bash
sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout /opt/vault/tls/transit.key \
  -out /opt/vault/tls/transit.crt \
  -subj "/CN=vault.local" \
  -addext "subjectAltName=DNS:vault.local,DNS:localhost,IP:127.0.0.1"
sudo chown vault:vault /opt/vault/tls/transit.key /opt/vault/tls/transit.crt
sudo chmod o+x /opt/vault/tls
```

NOTE: The cert is issued for the `vault.local` hostname rather than the host's dynamic IP. Add `127.0.0.1 vault.local` to `/etc/hosts` on the host. The in-cluster Main Vault dials Transit by IP (`vault-values.yaml`'s seal `address`, substituted from the Downward API at every pod start) but verifies TLS against the `vault.local` name via `tls_server_name`, so IP changes require no manual cert or config update.

Modify /etc/vault.d/vault.hcl. Ensure the listener is bound to 0.0.0.0:8200 to allow cross-interface traffic, and define the api_addr:

```hcl
api_addr = "https://vault.local:8200"

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/opt/vault/tls/transit.crt"
  tls_key_file  = "/opt/vault/tls/transit.key"
}
```

Enable the service, initialize Vault, and configure the transit secret engine:

```bash
sudo systemctl enable --now vault
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/transit.crt"
vault operator init
```

CRITICAL: Store the generated 5 Unseal Keys and 1 Initial Root Token in a secure password manager immediately. If lost, data is irrecoverable.

Unseal the Transit Vault by providing three different unseal keys:

`vault operator unseal`

Configure the auto-unseal policy and generate the authentication token:

```bash
vault secrets enable transit
vault write -f transit/keys/autounseal

vault policy write autounseal-policy - <<EOF
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
EOF

vault token create -policy=autounseal-policy -period=768h -orphan
```

Securely store this token. (Note: This token requires periodic renewal prior to its 768h/32-day expiration to maintain auto-unseal capabilities).

**Automating future unseals (one-time setup):**

The Transit Vault re-seals every time the host reboots (WSL restart), which would otherwise mean re-running the three `vault operator unseal` calls above by hand every time. `scripts/start-cluster.sh` automates this by decrypting the 3 keys from a GPG-encrypted keyfile with a single passphrase.

Generate the keyfile once, from a RAM-backed tmpfs so the plaintext keys never touch disk:

```bash
mkdir -p /dev/shm/vault-setup && cd /dev/shm/vault-setup

# paste the same 3 keys used above into keys.txt, one per line

gpg --batch --yes --cipher-algo AES256 --symmetric keys.txt
mv keys.txt.gpg ~/.vault-keys.gpg
chmod 600 ~/.vault-keys.gpg
cd / && rm -rf /dev/shm/vault-setup
```

Set the GPG passphrase cache to expire immediately after use, so it never lingers past the moment of unseal:

```bash
cat >> ~/.gnupg/gpg-agent.conf <<'EOF'
default-cache-ttl 0
max-cache-ttl 0
EOF
gpgconf --reload gpg-agent
```

From this point on, scripts/start-cluster.sh detects whether the Transit Vault is sealed and, if so, prompts for this passphrase automatically, allowing the transit vault to be unsealed as part of the startup process for the vault.

### 4. Deploy the In-Cluster Main Vault

Add the HashiCorp Helm repository:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Create the namespace and inject connection credentials:

```bash
kubectl create namespace vault
kubectl create secret generic vault-transit-secret \
  --from-literal=token='<token from step 4>' -n vault
kubectl create configmap vault-transit-ca \
  --from-file=ca.crt=/opt/vault/tls/transit.crt -n vault
```

Deploy the Main Vault using manifests/vault-values.yaml.

The `seal "transit"` block defines the host address using `HOST_IP`. The Vault Helm chart's entrypoint dynamically substitutes this variable via the Kubernetes Downward API during pod initialization. This ensures the IP address remains accurate across host subsystem (e.g., WSL) restarts without requiring manual reconfiguration.

TLS verification is enforced using the `tls_server_name = "vault.local"` directive. This matches the Subject Alternative Name (SAN) of the transit certificate, ensuring the connection is securely verified by hostname despite routing via an IP address. The `tls_ca_cert` parameter within the same block must point to the mounted Certificate Authority ConfigMap.

```bash
helm install vault hashicorp/vault -n vault -f manifests/vault-values.yaml
```

Initialize this distinct instance and securely store its new root token and recovery key shares.

```bash
kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator init"
```

If successful, the output will report Sealed: false, verifying the auto-unseal mechanism.

### 5. Configure Vault Kubernetes Authentication

Establish the trust boundary allowing the Vault Secrets Operator to fetch credentials. This includes policies for applications that will be deployed later in setup.

```bash
kubectl exec -it vault-0 -n vault -- sh -c '
export VAULT_TOKEN="<main Vault root token>"
export VAULT_ADDR=http://127.0.0.1:8200

vault secrets enable -path=secret kv-v2
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"

vault policy write postgis-policy - <<EOF
path "secret/data/postgis" { capabilities = ["read"] }
path "secret/data/minio" { capabilities = ["read"] }
path "secret/data/postgis-app-user" { capabilities = ["read"] }
path "secret/metadata/postgis" { capabilities = ["read"] }
path "secret/metadata/minio" { capabilities = ["read"] }
path "secret/metadata/postgis-app-user" { capabilities = ["read"] }
EOF

vault write auth/kubernetes/role/postgis-role \
  bound_service_account_names=postgis-vault-auth \
  bound_service_account_namespaces=databases \
  policies=postgis-policy \
  ttl=24h
'
```

### 6. Seed Application Credentials

Inject required credentials into the Vault KV store. The `postgis` path is the bootstrap/superuser credential CNPG uses at initdb time — it stays static and KV-backed deliberately, since Vault's database secrets engine (Step 9) needs a standing privileged user to create and drop the dynamic application roles it hands out, and that credential can't itself be one of the leases it manages.

The `seaweedfs` path stores the same access/secret key pair twice: once as flat fields (`ACCESS_KEY_ID`/`ACCESS_SECRET_KEY`, consumed by the Barman Cloud Plugin's `s3Credentials` references), and once pre-rendered into the JSON shape SeaweedFS's own S3 gateway expects for its identity file (`config.json`, mounted directly into the SeaweedFS pod).

```bash
kubectl exec -it vault-0 -n vault -- sh -c '
export VAULT_TOKEN="<main Vault root token>"

vault kv put secret/postgis username="<your username>" password="<your password>"

vault kv put secret/seaweedfs \
  ACCESS_KEY_ID="<your access key>" ACCESS_SECRET_KEY="<your secret key>" \
  config.json="{\"identities\":[{\"name\":\"cnpg\",\"credentials\":[{\"accessKey\":\"<your access key>\",\"secretKey\":\"<your secret key>\"}],\"actions\":[\"Read\",\"Write\",\"List\",\"Tagging\",\"Admin\"]}]}"
'
```

### 8. Install Software Operators

cert-manager is a hard prerequisite for both the PostGIS server certificate (Step 8) and the Barman Cloud Plugin — install and confirm it's healthy first.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=120s -n cert-manager deployment --all
```

```bash
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system --create-namespace

helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace
```

The Barman Cloud Plugin requires CloudNativePG 1.26 or newer. Confirm the operator version before installing the plugin:

```bash
kubectl get deployment -n cnpg-system cnpg-controller-manager \
  -o jsonpath="{.spec.template.spec.containers[*].image}"
```

Then install the plugin into the same namespace as the operator (check the [releases page](https://github.com/cloudnative-pg/plugin-barman-cloud/releases) for a version newer than v0.13.0 before running this):

```bash
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.13.0/manifest.yaml
kubectl rollout status deployment -n cnpg-system barman-cloud
```

### 8. Deploy the Database and Storage Infrastructure

Before applying these manifests, ensure the `database:` and `owner:` values in `manifests/postgis-cluster.yaml match those seeded into the vault.

Furthermore, verify both `enableSuperuserAccess:` true and `superuserSecret` are explicitly set in the Cluster spec:

```yaml
enableSuperuserAccess: true
superuserSecret:
  name: postgis-app-credentials
  ```

Without `enableSuperuserAccess: true`, CNPG actively blanks the role's password to NULL on every reconciliation cycle by design. If `enableSuperuserAccess: true` is set without a superuserSecret, CNPG auto-generates its own random `<cluster-name>-superuser` password, completely bypassing your Vault setup silently.

Apply in this order — `vso-setup.yaml` creates the namespace everything else lives in, and `postgres-tls.yaml` must exist before `postgis-cluster.yaml` references the Secret it produces:

```bash
kubectl apply -f manifests/vso-setup.yaml
kubectl apply -f manifests/postgres-tls.yaml
kubectl apply -f manifests/seaweedfs-backups.yaml
kubectl apply -f manifests/postgis-cluster.yaml
kubectl get pods -n databases -w
```

Monitor until both the `seaweedfs` and `postgis-cluster-1` pods report Running.

**Connecting with verified TLS:** now that Postgres has a certificate covering `localhost`, any client connecting through the `postgres-proxy` bridge can use `sslmode=verify-full`. Trust the cluster's local CA once:

```bash
mkdir -p ~/.postgresql
kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt
```

libpq checks `~/.postgresql/root.crt` automatically, so `psql "host=localhost port=5432 dbname=postgres user=postgres sslmode=verify-full"` will now verify the certificate rather than just encrypting the connection.

**Database Restoration**: When transferring an existing database into the CNPG cluster, use the following commands to restore the database:

For standard plaintext SQL dumps (.sql), stream the file via stdin:

```bash
kubectl exec -i postgis-cluster-1 -n databases -- psql -U <APP_DB_OWNER> -d <APP_DB_NAME> -f - < /path/to/backup.sql
```

For binary or custom-format dumps (`.dump`), utilize `pg_restore` via stdin the same way. Append `--no-owner` and `--no-privileges` to bypass permission mapping constraints:

```bash
kubectl exec -i postgis-cluster-1 -n databases -- pg_restore -U <APP_DB_OWNER> -d <APP_DB_NAME> --no-owner --no-privileges < /path/to/backup.dump
```

### 9. Configure Dynamic Application Credentials

This block is piped in via a quoted heredoc (`sh <<'EOF'`) rather than `sh -c '...'`, specifically because the SQL in `creation_statements` needs literal single quotes — those would otherwise prematurely close a single-quoted `-c '...'` wrapper before ever reaching the pod.

```bash
kubectl exec -i -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="<main Vault root token>" sh <<'EOF'
vault secrets enable database

vault write database/config/postgis-cluster \
  plugin_name=postgresql-database-plugin \
  allowed_roles="postgis-app-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgis-cluster-rw.databases.svc.cluster.local:5432/postgres?sslmode=require" \
  username="<the same username you seeded into secret/postgis in Step 6>" \
  password="<the same password you seeded into secret/postgis in Step 6>"

vault write database/roles/postgis-app-role \
  db_name=postgis-cluster \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT ALL PRIVILEGES ON DATABASE postgres TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
EOF
```

Confirm it worked:

```bash
kubectl get vaultdynamicsecret postgis-app-dynamic-secret -n databases
kubectl get secret postgis-app-dynamic-credentials -n databases -o jsonpath='{.data.username}' | base64 -d
```

The `creation_statements` above grant broad privileges on the single `postgres` database, matching what the previous static credential effectively had. Once real ETL/ML workloads exist, narrow this to whatever each workload actually needs rather than reusing one broad role for everything.

### 10. Install Headlamp Desktop (Optional)

Install the desktop application on Ubuntu via Flatpak:

```bash
flatpak install flathub dev.headlamp.Headlamp
```

*(Alternatively, download the latest `.deb` or `AppImage` from the [Headlamp GitHub Releases page](https://github.com/headlamp-k8s/headlamp/releases)).*

Launch Headlamp from your application menu (or `flatpak run dev.headlamp.Headlamp` in the terminal) — it detects your synced `~/.kube/config` and connects immediately. No token to generate, no port-forward, no browser step: that whole flow only exists on the WSL2 branch, where Headlamp runs as an in-cluster web service accessed from a separate Windows browser.

```bash
flatpak install flathub dev.headlamp.Headlamp
```

*(Alternatively, you can download the latest `.deb` or `AppImage` from the [Headlamp GitHub Releases page](https://github.com/headlamp-k8s/headlamp/releases)).*

#### **Headlamp for Windows/Windows Subsystem for Linux 2 (WSL2)**

Please see the WSL2 branch for documentation of workflows to deploy Headlamp when managing k3s deployed in WSL2.

**Note: Mirrored networking is needed to use Headlamp as a Windows App. Use Traefik or another Ingress controller instead of Cilium**.

## Cluster Operations

| Operation | Command | When |
| --- | --- | --- |
| Start the cluster | `./scripts/start-cluster.sh` | Each work session |
| Stop the cluster | `./scripts/stop-cluster.sh` | Each work session |
| Sync API Context | `./scripts/sync-kubeconfig.sh` | Only if a tool shows a stale kubeconfig directly |
| Trigger Manual DB Backup | `kubectl cnpg backup postgis-cluster -n databases -m plugin --plugin-name barman-cloud.cloudnative-pg.io` | Before a risky schema change, outside the nightly automated backup |
| Verify Vault State | `kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status"` | Troubleshooting only |
| Verify CNPG State | `kubectl cnpg status postgis-cluster -n databases` | Troubleshooting only |
| Port-Forward Vault API | `kubectl port-forward -n vault vault-0 8200:8200` | Ad hoc token/policy management |

* **Scheduled Backups:** `postgis-cluster.yaml`'s `ScheduledBackup` resource pushes a base backup to SeaweedFS nightly at midnight on its own — no action needed.
* **Lifecycle Management:** `start-cluster.sh` enforces a strict dependency order (API → CNI → Transit Vault Unseal → Cluster Vault Auto-Unseal → Secrets Sync → DB Un-hibernation) and halts with specific errors on failure. `stop-cluster.sh` cleanly hibernates the database and validates state before issuing a SIGTERM to k3s.

## Troubleshooting Guide

* **Pod Initialization Failure:** Run `kubectl describe pod <pod_name> -n databases` and review the "Events" stream for exact scheduler or image pull errors.
* **Vault Permission Denied:** Verify the existence of the `postgis-role` policy generated in Step 5 via the Vault CLI.
* **Secrets Failing to Mount:** Run `kubectl describe vaultstaticsecret <name> -n databases` (or `vaultdynamicsecret` for the dynamic application credential). Resource status conditions will report the specific API failure.
* **Transit Vault Prompts Every Run, or GPG Decryption Fails:** `start-cluster.sh` only prompts for the GPG passphrase if the Transit Vault is actually sealed — if it's prompting on every run despite no host reboot, check whether the `vault` systemd service is being restarted independently (`systemctl status vault`). If decryption itself fails, confirm `~/.vault-keys.gpg` exists and is readable (`ls -l ~/.vault-keys.gpg`, expect `600` permissions) and that the passphrase matches what was set during the one-time GPG setup in Step 3. `sudo chmod o+x /opt/vault/tls` allows both vaults access to the location of the tls certificate. `sudo stat -c "%a %U:%G %n" /opt/vault/tls` will confirm the correct permissions.
* **Password Authentication Fails on Valid Password:** Ensure `enableSuperuserAccess: true` and `superuserSecret` are both present in `postgis-cluster.yaml`. Without both, CNPG actively nullifies or rotates the passwords during reconciliation.
* **Credentials Unresponsive Post-Rotation:** Database credentials silently stop working after a Vault password rotation. The credentials Secret must carry the `cnpg.io/reload: "true"` label for CNPG to notice the change. VSO's `destination.labels` field for setting this via `VaultStaticSecret`/`VaultDynamicSecret` has open reliability issues (hashicorp/vault-secrets-operator #472, #1045) where the label fails to apply reliably. Manually force the refresh by labeling the secret directly: `kubectl label secret postgis-app-credentials -n databases cnpg.io/reload=true` (or `postgis-app-dynamic-credentials` for the dynamic one).
* **Dynamic credential never goes Ready:** Confirm Step 9 was actually run against a live `postgis-cluster-rw` service (Step 8 must already be applied), and that the policy from Step 5 actually includes `database/creds/postgis-app-role`, not just the KV paths. `kubectl describe vaultdynamicsecret postgis-app-dynamic-secret -n databases` will show Vault's own error text if the role or connection config is missing.
* **`sslmode=verify-full` fails with a hostname mismatch:** Confirm you're connecting to a name actually present in `manifests/postgres-tls.yaml`'s `dnsNames`/`ipAddresses` — `localhost` and `127.0.0.1` are covered, but a raw LAN IP or a different hostname isn't unless you add it and let cert-manager reissue.
* **Barman Cloud Plugin backups failing right after migration:** Check `kubectl cnpg status postgis-cluster -n databases` for the plugin's own status block, and confirm the `ObjectStore` resource's `s3Credentials` secret refs match what's actually in `seaweedfs-credentials` — a typo here fails silently until the first WAL archive attempt.
* **k3s Port Conflicts:** If k3s logs show bind errors on port 6443, the systemd process is likely active. Run `systemctl is-enabled k3s` to verify it is disabled.
* **Stale Cilium Endpoints:** If network conditions change on the host machine, long-running pods may retain stale IP records. Delete the affected pods; the deployment controller will recreate them with fresh network identities.
