# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a PostgreSQL server with the PostGIS extension enabled. It is intended to be scalable for data science projects, such as Extract, Transform, and Load (ETL) pipelines, Machine Learning (ML), and data analytics.

This cluster's architecture relies on a system-installed HashiCorp Vault to act as a transit to unseal a cluster-situated Vault. This cluster Vault is the primary store for all secrets in the cluster. Secure provisioning of environment variables from this vault allows users to combine ease of use and best practices for Secrets Management, intended for local use but scalable for enterprises if necessary.

This README provides detailed instructions on how to assemble and deploy your own cluster, providing all of the tools needed to easily scale into larger and more complex tasks. Cilium, HashiCorp Vault, CloudNative PostgreSQL (CNPG), and MinIO are all tools suitable for production purposes. What they provide, to any edge computing developers, are a powerful basis for Data Science and development with Kubernetes' trademark customizability (and complexity!).

## Core Architecture

* **k3s:** A lightweight, certified Kubernetes distribution. It acts as the core control plane and execution environment for the database and its supporting services.
* **CloudNativePG (CNPG):** A Kubernetes operator designed to manage the full lifecycle of a PostgreSQL/PostGIS database. It handles provisioning, replication, and automated disaster recovery pipelines directly via Pods and PVCs, enabling database-aware failovers.
* **Postgres-Proxy Bridge:** A lightweight `socat` TCP relay running on the host network. It reliably exposes the PostgreSQL database to the Windows host (`localhost:5432`) for applications like DBeaver and Power BI.
* **Cilium:** The cluster's Container Network Interface (CNI). It replaces k3s's default networking components to provide highly efficient, eBPF-based network routing and Gateway API support. *(Note: Incompatible with WSL2 Mirrored Networking).*
* **HashiCorp Vault (Transit Auto-Unseal):** The system utilizes two Vault instances to solve the "secret zero" problem. A lightweight **Transit Vault** runs natively on the WSL host. The **Main Vault** runs inside the Kubernetes cluster. When the cluster boots, the Main Vault automatically authenticates against the Transit Vault to unseal itself, requiring no manual intervention. The Transit Vault itself still re-seals on every host reboot and requires one human-entered passphrase to unseal — `start-cluster.sh` automates this via a GPG-encrypted keyfile (see Step 5 below) rather than pasting 3 raw unseal keys by hand.
* **Vault Secrets Operator (VSO):** A Kubernetes operator that acts as a secure bridge. It continuously reads credentials from the Main Vault and natively synchronizes them into standard Kubernetes `Secret` objects.
* **MinIO:** An in-cluster, S3-compatible object storage service. It acts as the local backup target. CloudNativePG continuously streams database Write-Ahead Logs (WAL) and scheduled base backups to this storage bucket.

## Repository Structure

* `README_cluster.md`: This document — architecture, setup, and operations reference.
* `ROADMAP.md`: Planned future services and technical debt remediation.
* `scripts/`
  * `start-cluster.sh`: Sequential boot script enforcing API, Transit Vault unseal, Secret, and Database readiness state checks.
  * `stop-cluster.sh`: Graceful shutdown script utilizing CNPG declarative hibernation.
  * `sync-kubeconfig.sh`: Exports the cluster config to the Windows environment.
* `manifests/`
  * `vault-values.yaml`: Helm chart overrides, mapping the in-cluster Vault to the host Transit Vault.
  * `vso-setup.yaml`: Provisions namespaces, service accounts, and Vault connection CRDs.
  * `minio-backups.yaml`: Provisions the S3-compatible storage pod, PVCs, and automated bucket initialization jobs.
  * `postgis-cluster.yaml`: Deploys the Postgres cluster, the VaultStaticSecret sync definitions, and the `postgres-proxy` bridge deployment.

## Official Documentation

| Component | Documentation Link |
| --- | --- |
| k3s | [https://docs.k3s.io/](https://docs.k3s.io/) |
| Cilium | [https://docs.cilium.io/](https://docs.cilium.io/) |
| Gateway API | [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/) |
| HashiCorp Vault | [https://developer.hashicorp.com/vault/docs)](https://developer.hashicorp.com/vault/docs) |
| Vault Secrets Operator | [https://developer.hashicorp.com/vault/docs/vault-secrets-operator](https://developer.hashicorp.com/vault/docs/vault-secrets-operator) |
| CloudNativePG | [https://cloudnative-pg.io/docs](https://cloudnative-pg.io/docs) |
| CNPG Hibernation | [https://cloudnative-pg.io/documentation/current/declarative_hibernation/](https://cloudnative-pg.io/documentation/current/declarative_hibernation/) |
| CNPG Role Management | [https://cloudnative-pg.io/documentation/current/declarative_role_management/](https://cloudnative-pg.io/documentation/current/declarative_role_management/) |
| MinIO | [https://docs.min.io/](https://docs.min.io/) |
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

* `--disable traefik` and `--disable servicelb`: Skips the deployment of k3s's bundled addon manifests (the Traefik ingress controller and the Klipper LoadBalancer).
* `--disable-kube-proxy`: Turns off the built-in kube-proxy supervisor component. Because kube-proxy is a core component rather than an addon, passing it to the generic `--disable` flag fails silently, leaving it running alongside Cilium's replacement. (Status can be verified using `sudo iptables-save | grep -c KUBE-SVC`, where a nonzero count indicates kube-proxy is still active).
* `--flannel-backend=none` and `--disable-network-policy`: Prevents the default CNI and network policies from loading, deferring routing and enforcement entirely to Cilium.
* `--write-kubeconfig-mode 644`: Sets read permissions for the kubeconfig file so standard, non-root users can execute `kubectl` and `helm` commands without triggering permission errors.

Systemd manages the cluster during the initial build phase, with custom lifecycle scripts (`scripts/start-cluster.sh` and `scripts/stop-cluster.sh`) provided to take over management once the build is complete.

### 2. Verify WSL Networking Configuration

Before installing Cilium, ensure your WSL configuration is compatible with eBPF networking. Open `%UserProfile%\.wslconfig` on Windows and confirm `networkingMode=mirrored` is **not** set under `[wsl2]`. If you must remove the mirrored setting, run `wsl --shutdown` — k3s (and everything deployed so far) comes back up automatically via systemd once WSL restarts.

*Architecture Note:* Mirrored networking works by having WSL2 register a BPF program that intercepts `bind()` calls to route traffic between Windows and the VM. Cilium's `kubeProxyReplacement` mode uses the same kind of host-level eBPF traffic interception. Attempting to run both simultaneously causes a multi-minute total network outage within the cluster. Standard NAT mode (the WSL2 default) avoids this collision while still supporting localhost port forwarding.

### 3. Install Cilium

**Prerequisites:** Step 3's WSL networking check must be complete (mirrored mode disabled). Furthermore, `k3s` must be installed with the `--disable-kube-proxy` boolean flag and `--flannel-backend=none` per Step 1. Cilium's `kubeProxyReplacement` only fully assumes L4 routing if the native `kube-proxy` is genuinely disabled.

#### 3a. Install the Gateway API CRDs

Gateway API Custom Resource Definitions (CRDs) must be installed prior to Cilium. The CRD version must strictly align with the requirements of the deployed Cilium release (e.g., Cilium 1.19.x requires Gateway API v1.4.1). A version mismatch results in silent failures, leaving the GatewayClass in an `ACCEPTED: Unknown` state. This deployment utilizes the standard (GA) release channel.

```bash
kubectl apply --server-side -f [https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml](https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml)
```

The `--server-side` flag is mandatory because these manifests exceed the annotation size limit utilized by client-side apply operations.\

#### 3b. Install the Cilium CLI

Retrieve the latest stable CLI release and install the executable to `/usr/local/bin` for system-wide access.

```bash
CILIUM_CLI_VERSION=$(curl -s [https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt](https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt))
curl -L --fail --remote-name-all [https://github.com/cilium/cilium-cli/releases/download/$](https://github.com/cilium/cilium-cli/releases/download/$){CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
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

### 4. Deploy the Host-Level Transit Vault

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

NOTE: The cert is issued for the `vault.local` hostname rather than the WSL host's dynamic IP. Add `127.0.0.1 vault.local` to `/etc/hosts` on the host. The in-cluster Main Vault dials Transit by IP (`vault-values.yaml`'s seal `address`, substituted from the Downward API at every pod start) but verifies TLS against the `vault.local` name via `tls_server_name`, so IP changes require no manual cert or config update.

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

### 5. Deploy the In-Cluster Main Vault

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

### 6. Configure Vault Kubernetes Authentication

Establish the trust boundary allowing the Vault Secrets Operator to fetch credentials.

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

### 7. Seed Application Credentials

Inject required credentials into the Vault KV store.

```bash
kubectl exec -it vault-0 -n vault -- sh -c '
export VAULT_TOKEN="<main Vault root token>"
vault kv put secret/postgis username="<your username>" password="<your password>"
vault kv put secret/minio \
  MINIO_ROOT_USER="<user>" MINIO_ROOT_PASSWORD="<password>" \
  ACCESS_KEY_ID="<same as user>" ACCESS_SECRET_KEY="<same as password>"
'
```

### 8. Install Software Operators

```bash
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system --create-namespace

helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace
```

### 9. Deploy the Database and Storage Infrastructure

Before applying these manifests, ensure the `database:` and `owner:` values in `manifests/postgis-cluster.yaml match those seeded into the vault.

Furthermore, verify both `enableSuperuserAccess:` true and `superuserSecret` are explicitly set in the Cluster spec:

```yaml
enableSuperuserAccess: true
superuserSecret:
  name: postgis-app-credentials
  ```

Without `enableSuperuserAccess: true`, CNPG actively blanks the role's password to NULL on every reconciliation cycle by design. If `enableSuperuserAccess: true` is set without a superuserSecret, CNPG auto-generates its own random `<cluster-name>-superuser password`, completely bypassing your Vault setup silently.

```bash
kubectl apply -f manifests/vso-setup.yaml
kubectl apply -f manifests/minio-backups.yaml
kubectl apply -f manifests/postgis-cluster.yaml
kubectl get pods -n databases -w
```

Monitor until both the `minio` and `postgis-cluster-1` pods report Running.

**Database Restoration**: When transferring an existing database into the CNPG cluster, use the following commands to restore the database:

For standard plaintext SQL dumps (.sql), stream the file via stdin:

```bash
kubectl exec -i postgis-cluster-1 -n databases -- psql -U <APP_DB_OWNER> -d <APP_DB_NAME> -f - < /path/to/backup.sql
```

For binary or custom-format dumps (`.dump`), utilize `pg_restore`. Append `--no-owner` and `--no-privileges` to bypass permission mapping constraints:

```bash
kubectl exec -it postgis-cluster-1 -n databases -- pg_restore -d "
```

### 10. Deploy Headlamp (Optional)

Add the official Helm repository — note this moved under Kubernetes SIGs; the older `headlamp-k8s.github.io` repo is dead and will 404:

```bash
helm repo add headlamp [https://kubernetes-sigs.github.io/headlamp/](https://kubernetes-sigs.github.io/headlamp/)
helm repo update
helm install headlamp headlamp/headlamp --namespace kube-system
```

Create a dedicated service account and bind it to `cluster-admin`:

```bash
kubectl create serviceaccount headlamp-admin -n kube-system
kubectl create clusterrolebinding headlamp-admin-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:headlamp-admin
```

**Important:** the Helm chart itself creates a `ClusterRoleBinding` also named `headlamp-admin`, but it binds a *different* service account (`headlamp`, the chart's own default) to `cluster-admin`. That name collision looks like your token's service account already has the grant it needs — it doesn't. Always bind your own `headlamp-admin` service account under its own binding name (as above), and verify with:

```bash
kubectl auth can-i list nodes.metrics.k8s.io --as=system:serviceaccount:kube-system:headlamp-admin
```

Generate a login token (short-lived by default — regenerate as needed, or add `--duration` for a longer-lived one):

```bash
kubectl create token headlamp-admin -n kube-system
```

#### Sync Kubeconfig (Optional)

To use Windows-side UI tools such as the Headlamp desktop app, use the provided `sync-kubeconfig.sh` script to create a config file accessible to them.

```bash
./scripts/sync-kubeconfig.sh
```

Note: this script overwrites both destination kubeconfig files with a fresh copy every run. Anything already holding an open connection using the *old* file's cert/CA (an existing port-forward, an already-authenticated desktop session) won't notice the swap — it'll just start failing. Restart whatever was using the old file rather than assuming the cluster itself broke.

---

## Accessing the Database

The `socat` deployment included in the postgis-cluster manifest exposes the database at `localhost:5432` without manual port forwarding for access. It shares the host's network namespace directly and passing connection streams directly to the database while sidestepping Cilium's Service/hostPort layers. This approach is necessary due to specific limitations of WSL and Cilium:

* WSL2's Windows-to-localhost forwarding (`wslrelay.exe`) expects genuine bound sockets. Cilium's `kubeProxyReplacement` handles Service traffic via eBPF interception rather than a conventional bound socket, which wslrelay.exe doesn't reliably see.
* Cilium's native `hostPort` implementation has a confirmed, long-standing bug (see cilium/cilium #12116 from 2020, and #34792 from 2024) where it cannot serve traffic on loopback (`127.0.0.1`) under any configuration. The pod runs fine, but nothing binds on the host.

## VS Code Integration

These files live in the shared devcontainer workspace root (`~/coding/.vscode/`), not in this repo, since one devcontainer is reused across all projects.

**`devcontainer.json`** — declare the port so it shows up without relying on auto-detection:

```jsonc
"forwardPorts": [8080],
"portsAttributes": {
  "8080": { "label": "Headlamp UI", "onAutoForward": "silent" }
}
```

**`tasks.json`** — warms the port-forward automatically on folder open, regenerates a token each run, and pushes that token straight to the clipboard via an OSC 52 escape sequence (works from a local devcontainer's integrated terminal, no `clip.exe`/filesystem bridge needed):

```jsonc
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "headlamp: start",
      "type": "shell",
      "command": "pkill -f 'kubectl.*port-forward.*svc/headlamp' >/dev/null 2>&1; TOKEN=$(kubectl create token headlamp-admin -n kube-system); echo \"$TOKEN\"; printf '\\033]52;c;%s\\a' \"$(printf '%s' \"$TOKEN\" | base64 -w0)\"; nohup kubectl port-forward svc/headlamp 8080:80 -n kube-system >/tmp/headlamp.log 2>&1 & sleep 1",
      "presentation": { "reveal": "always", "panel": "dedicated", "clear": true },
      "problemMatcher": [],
      "runOptions": { "runOn": "folderOpen" }
    }
  ]
}
```

**`launch.json`** — opens Headlamp using VS Code's `editor-browser` debug type (1.110+), a real Edge/Chrome instance via CDP rather than the built-in Simple Browser. Use this, not Simple Browser: Simple Browser is a restricted webview that renders Headlamp's WebSocket-driven live views unreliably (blank panels, slow loads) — `editor-browser` behaves like a normal browser tab.

```jsonc
{
  "version": "0.2.0",
  "configurations": [
    { "type": "editor-browser", "request": "launch", "name": "Headlamp", "url": "[http://127.0.0.1:8080](http://127.0.0.1:8080)" }
  ]
}
```

Workflow: open the folder (port-forward warms, token lands on clipboard) → Run and Debug → "Headlamp" → paste the token when prompted.

| Operation | Command | When |
| --- | --- | --- |
| Start the cluster | `./start-cluster.sh` | Each work session |
| Stop the cluster | `./stop-cluster.sh` | Each work session |
| Sync API Context | `./sync-kubeconfig.sh` | Only if Headlamp or another tool shows a stale kubeconfig (e.g. after a WSL IP change) directly |
| Trigger Manual DB Backup | `kubectl cnpg backup postgis-cluster -n databases` | Before a risky schema change, outside the nightly automated backup |
| Verify Vault State | `kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status"` | Troubleshooting only |
| Verify CNPG State | `kubectl cnpg status postgis-cluster -n databases` | Troubleshooting only |
| Port-Forward Vault API | `kubectl port-forward -n vault vault-0 8200:8200` | Ad hoc token/policy management |
| Open Headlamp | Run and Debug → "Headlamp" (see VS Code Integration) | Cluster inspection during dev work |

* **Database access:** `localhost:5432` is reachable via the proxy bridge any time the cluster is up — always-on, not something you run.
* **Scheduled Backups:** `postgis-cluster.yaml`'s `ScheduledBackup` resource pushes a base backup to MinIO nightly at midnight on its own — no action needed.
* **Lifecycle Management:** `start-cluster.sh` enforces a strict dependency order (API -> CNI -> Transit Vault Unseal -> Cluster Vault Auto-Unseal -> Secrets Sync -> DB Un-hibernation) and halts with specific errors on failure. `stop-cluster.sh` cleanly hibernates the database and validates state before issuing a SIGTERM to k3s.

## Troubleshooting Guide

* **Pod Initialization Failure:** Run `kubectl describe pod <pod_name> -n databases` and review the "Events" stream for exact scheduler or image pull errors.
* **Vault Permission Denied:** Verify the existence of the `postgis-role` policy generated in Step 7 via the Vault CLI.
* **Secrets Failing to Mount:** Run `kubectl describe vaultstaticsecret <name> -n databases`. Resource status conditions will report the specific API failure.
* **Transit Vault Prompts Every Run, or GPG Decryption Fails:** `start-cluster.sh` only prompts for the GPG passphrase if the Transit Vault is actually sealed — if it's prompting on every run despite no host reboot, check whether the `vault` systemd service is being restarted independently (`systemctl status vault`). If decryption itself fails, confirm `~/.vault-keys.gpg` exists and is readable (`ls -l ~/.vault-keys.gpg`, expect `600` permissions) and that the passphrase matches what was set during the one-time GPG setup in Step 5. `sudo chmod o+x /opt/vault/tls` allows both vaults access to the location of the tls certificate. `sudo stat -c "%a %U:%G %n" /opt/vault/tls will confirm the correct permissions.`
* **Password Authentication Fails on Valid Password:** Ensure `enableSuperuserAccess: true` and `superuserSecret` are both present in `postgis-cluster.yaml`. Without both, CNPG actively nullifies or rotates the passwords during reconciliation.
* **Credentials Unresponsive Post-Rotation:** Database credentials silently stop working after a Vault password rotation. The credentials Secret must carry the `cnpg.io/reload: "true"` label for CNPG to notice the change. VSO's `destination.labels` field for setting this via `VaultStaticSecret` has open reliability issues (hashicorp/vault-secrets-operator #472, #1045) where the label fails to apply reliably. Manually force the refresh by labeling the secret directly: `kubectl label secret postgis-app-credentials -n databases cnpg.io/reload=true`.
* **Headlamp Ghost Clusters (Windows):** Close the Headlamp UI, purge its local cache directory (`%APPDATA%\Headlamp` on Windows), and relaunch the application.
* **Headlamp `Forbidden` errors despite a `cluster-admin` token:** Check the actual binding, not just its name — `kubectl get clusterrolebinding headlamp-admin -o yaml` and confirm `subjects` points at the `headlamp-admin` service account, not the chart's own `headlamp` one (see Step 10). Confirm directly with `kubectl auth can-i <verb> <resource> --as=system:serviceaccount:kube-system:headlamp-admin` before assuming it's an RBAC gap elsewhere.
* **Headlamp console shows `Unable to parse error json` for `localhost:4466/config`:** Benign. The frontend bundle always checks for a desktop-app companion backend on port 4466; nothing's listening there in the in-cluster deployment, and the check fails harmlessly.
* **Headlamp blank panels or very slow loads in VS Code:** Almost always Simple Browser's restricted webview, not the cluster. Use the `editor-browser` launch config instead (see VS Code Integration).
* **k3s Port Conflicts:** If k3s logs show bind errors on port 6443, the systemd process is likely active. Run `systemctl is-enabled k3s` to verify it is disabled.* **k3s Port Conflicts:** If k3s logs show bind errors on port 6443, the systemd process is likely active. Run `systemctl is-enabled k3s` to verify it is disabled.
* **Stale Cilium Endpoints:** If network conditions change on the host machine, long-running pods may retain stale IP records. Delete the affected pods; the deployment controller will recreate them with fresh network identities.
