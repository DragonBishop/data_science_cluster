# k3s + Vault + CloudNativePG + MinIO Local Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a postgreSQL server with the postGIS extension enabled. It is intended to be scalable for data science projects, such as Extract, Transform, and Load (ETL) pipelines, Machine Learning (ML), and data analytics.

This cluster's architecture relies on a system-installed Hashicorp Vault to act as a transit to unseal a cluster-situated Vault. This cluster Vault is the primary store for all secrets in the cluster. Secure provisioning of environment variables from this vault allows users to combine ease of use and best practices for Secrets Management, intended for local use but scalable for enterprises if necessary.

This README provides detailed instructions on how to assemble and deploy your own cluster, providing all of the tools needed to easily scale into larger and more complex tasks. Cilium in place of legacy Ingress, Hashicorp Vault, Falco, and minIO are all tools that may seem a bit excessive for simple hobbyist use. What they provide, to any edge computing developers, are a powerful basis for Data Science and development with Kubernetes' trademark customizability (and complexity!).

## Core Architecture

* **k3s:** A lightweight, certified Kubernetes distribution. It acts as the core control plane and execution environment for the database and its supporting services.
* **Cilium:** The cluster's Container Network Interface (CNI). It replaces k3s's default networking components (Flannel and Kube-proxy) to provide highly efficient, eBPF-based network routing and Gateway API support.
* **HashiCorp Vault (Transit Auto-Unseal):** The system utilizes two Vault instances to solve the "secret zero" problem. A lightweight **Transit Vault** runs natively on the WSL host. The **Main Vault** runs inside the Kubernetes cluster. When the cluster boots, the Main Vault automatically authenticates against the Transit Vault to unseal itself, requiring no manual intervention.
* **Vault Secrets Operator (VSO):** A Kubernetes operator that acts as a secure bridge. It continuously reads credentials from the Main Vault and natively synchronizes them into standard Kubernetes `Secret` objects, allowing applications to mount them as standard environment variables.
* **CloudNativePG (CNPG):** A Kubernetes operator designed to manage the full lifecycle of a PostgreSQL/PostGIS database. It handles provisioning, replication, and automated disaster recovery pipelines.
* **MinIO:** An in-cluster, S3-compatible object storage service. It acts as the local backup target. CloudNativePG continuously streams database Write-Ahead Logs (WAL) and scheduled base backups to this storage bucket.
* **Falco:** A cloud-native runtime security tool. It monitors system calls and Kubernetes audit logs to detect and alert on abnormal behavior.

## Official Documentation

| Component | Documentation Link |
| --- | --- |
| k3s | https://docs.k3s.io/ |
| Cilium | https://docs.cilium.io/ |
| Gateway API | https://gateway-api.sigs.k8s.io/ |
| HashiCorp Vault | https://developer.hashicorp.com/vault/docs |
| Vault Secrets Operator | https://developer.hashicorp.com/vault/docs/vault-secrets-operator |
| CloudNativePG | https://cloudnative-pg.io/docs |
| CNPG Hibernation | https://cloudnative-pg.io/documentation/current/declarative_hibernation/ |
| MinIO | https://docs.min.io/ |
| Falco | https://falco.org/docs/ |

---

## First-Time Setup Instructions

This stack is designed so that this setup is intended to be completed in chronological order, and no guarantee can made of success if this workflow is not followed.

### 1. Install k3s (and detach from systemd)

```bash
curl -sfL [https://get.k3s.io](https://get.k3s.io) | sh -
```

By default, this script installs k3s as an auto-starting systemd service. This is ideal for enterprises, because Kubernetes' "Stay alive at all costs" approach helps enterprises built resilient networks. However, in edge computing development, it's practical to want to be able to safely wind down processes rather than hope they close gracefully without user intention.

Utilize custom lifecycle scripts (`start-cluster.sh` and `stop-cluster.sh`) to manage specific database hibernation tasks. Systemd simultaneously attempting to manage k3s will result in severe port conflicts and state corruption. Disable the service:

```bash
sudo systemctl disable --now k3s
```

### 2. Initial Cluster Boot

```bash
./start-cluster.sh
```

This script initiates k3s with its default network components explicitly disabled. **If you check the node status, it will report `NotReady`.** This is the expected state until the CNI (Cilium) is applied in the next step.

### 3. Install the Cilium CNI

Cilium requires Kubernetes Gateway API CRDs to function. At time of writing, the **experimental** release channel of these CRDs is necessary for this cluster; the standard channel omits the `TLSRoute` definition, which can cause the Cilium operator to enter a fatal crash-loop upon startup.

```bash
kubectl apply -f [https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/experimental-install.yaml](https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/experimental-install.yaml)
```

Next, download and install the Cilium CLI:

```bash
CILIUM_CLI_VERSION=$(curl -s [https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt](https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt))
curl -L --fail --remote-name-all [https://github.com/cilium/cilium-cli/releases/download/$](https://github.com/cilium/cilium-cli/releases/download/$){CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz
```

Deploy Cilium into the cluster and wait for the daemonsets to report healthy:

```bash
cilium install --set gatewayAPI.enabled=true --set kubeProxyReplacement=true
cilium status --wait
```

Verify the node has transitioned to a healthy state:

```bash
kubectl get nodes   # Status should now reflect "Ready"
```

### 4. Deploy the Host-Level Transit Vault

This Vault instance runs directly the host and serves solely as the encryption engine to unlock the cluster's Main Vault.

```bash
wget -O- [https://apt.releases.hashicorp.com/gpg](https://apt.releases.hashicorp.com/gpg) | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] [https://apt.releases.hashicorp.com](https://apt.releases.hashicorp.com) $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y vault
```

Generate a valid local TLS certificate with the required Subject Alternative Names (SANs) to allow secure communication from within the cluster:

```bash
sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout /opt/vault/tls/tls.key \
  -out /opt/vault/tls/tls.crt \
  -subj "/CN=vault.local" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:<your host's LAN IP>"
sudo chown vault:vault /opt/vault/tls/tls.key /opt/vault/tls/tls.crt
```

Modify `/etc/vault.d/vault.hcl`. Ensure the listener is bound to `0.0.0.0:8200` to allow cross-interface traffic, and append the following:

```hcl
api_addr = "https://<your host's LAN IP>:8200"
```

Enable the service, initialize the Vault, and configure the transit secret engine:

```bash
sudo systemctl enable --now vault

export VAULT_ADDR="[https://127.0.0.1:8200](https://127.0.0.1:8200)"
export VAULT_CACERT="/opt/vault/tls/tls.crt"

vault operator init
```

**CRITICAL:** The initialization command will output 5 Unseal Keys and 1 Initial Root Token. Store these immediately in a secure password manager. If lost, the Vault data is irrecoverable.

Unseal the Transit Vault by running the following command three times, providing a different unseal key each time:

```bash
vault operator unseal
```

Configure the auto-unseal policy and generate the token required for the Main Vault to authenticate against this Transit Vault:

```bash
vault secrets enable transit
vault write -f transit/keys/autounseal

vault policy write autounseal-policy - <<EOF
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
EOF

vault token create -policy=autounseal-policy -period=768h -orphan
```

Securely store the generated token.

### 5. Deploy the In-Cluster Main Vault

Add the HashiCorp Helm repository:

```bash
helm repo add hashicorp [https://helm.releases.hashicorp.com](https://helm.releases.hashicorp.com)
helm repo update
```

Create the namespace and inject the connection credentials required to reach the host Transit Vault:

```bash
kubectl create namespace vault
kubectl create secret generic vault-transit-secret \
  --from-literal=token='<token from step 4>' -n vault
kubectl create configmap vault-transit-ca \
  --from-file=ca.crt=/opt/vault/tls/tls.crt -n vault
```

Deploy the Main Vault using the custom configuration file:

```bash
helm install vault hashicorp/vault -n vault -f vault-values.yaml
```

Initialize this Main Vault. Because it is a completely separate instance, it will generate a new set of master keys and a new root token. Store this root token securely.

```bash
kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=[http://127.0.0.1:8200](http://127.0.0.1:8200) vault operator init"
```

If successful, the output will immediately report `Sealed: false`, verifying that the Transit auto-unseal mechanism is functioning.

### 6. Configure Vault Kubernetes Authentication

Establish the trust boundary between Vault and the Kubernetes API, allowing the Vault Secrets Operator to fetch passwords on behalf of the database.

```bash
kubectl exec -it vault-0 -n vault -- sh -c '
export VAULT_TOKEN="<main Vault root token>"
export VAULT_ADDR=[http://127.0.0.1:8200](http://127.0.0.1:8200)

vault secrets enable -path=secret kv-v2
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="[https://kubernetes.default.svc](https://kubernetes.default.svc)"

vault policy write postgis-policy - <<EOF
path "secret/data/postgis" { capabilities = ["read"] }
path "secret/data/minio" { capabilities = ["read"] }
EOF

vault write auth/kubernetes/role/postgis-role \
  bound_service_account_names=postgis-vault-auth \
  bound_service_account_namespaces=databases \
  policies=postgis-policy \
  ttl=24h
'
```

### 7. Seed Application Credentials

Inject your required credentials into the Vault KV store. Replace the placeholder values with your desired secure passwords.

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

Deploy the controllers responsible for managing the secrets lifecycle, database state, and security logging.

```bash
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system --create-namespace

helm repo add cnpg [https://cloudnative-pg.github.io/charts](https://cloudnative-pg.github.io/charts)
helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace

helm repo add falcosecurity [https://falcosecurity.github.io/charts](https://falcosecurity.github.io/charts)
helm install falco falcosecurity/falco --create-namespace --namespace falco
```

### 9. Deploy the Database and Storage Infrastructure

Before applying these manifests, ensure the `database:` and `owner:` values in `cnpg-cluster.yaml` perfectly match the username seeded into Vault during Step 7.

```bash
kubectl apply -f vso-setup.yaml
kubectl apply -f minio-backups.yaml
kubectl apply -f cnpg-cluster.yaml
kubectl get pods -n databases -w
```

Monitor the deployment until both the `minio` and `postgis-cluster-1` pods report a `Running` state.

### 10. Database Restoration

To restore an existing database into the newly provisioned CNPG cluster, target the primary read-write pod.

For standard plaintext SQL dumps (`.sql`), stream the file via `stdin`:

```bash
kubectl exec -i postgis-cluster-1 -n databases -- psql -U <APP_DB_OWNER> -d <APP_DB_NAME> -f - < /path/to/your/backup.sql
```

For binary or custom-format dumps (`.dump`), utilize `pg_restore`. Append the `--no-owner` and `--no-privileges` flags to circumvent permission mapping errors:

```bash
kubectl exec -it postgis-cluster-1 -n databases -- pg_restore -d "postgres://<APP_DB_OWNER>:<APP_DB_PASSWORD>@localhost:5432/<APP_DB_NAME>" -c --no-owner --no-privileges /path/to/your/backup.dump
```

### 11. Sync Kubeconfig

Execute the synchronization script to format and export the cluster's context to your local `.kube/config`, allowing tools like Headlamp and k9s to authenticate.

```bash
./sync-kubeconfig.sh
```

---

## Daily Operations

| Operation | Command |
| --- | --- |
| Initialize Cluster | `./start-cluster.sh` |
| Shutdown Cluster | `./stop-cluster.sh` |
| Sync API Context | `./sync-kubeconfig.sh` |
| Trigger Manual DB Backup | `kubectl cnpg backup postgis-cluster -n databases` |
| Verify Vault State | `kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status"` |
| Verify CNPG State | `kubectl cnpg status postgis-cluster -n databases` |
| Port-Forward Database | `kubectl port-forward -n databases svc/postgis-cluster-rw 5432:5432` |
| Port-Forward Vault API | `kubectl port-forward -n vault vault-0 8200:8200` |

**Note on Lifecycle Management:** The `./stop-cluster.sh` script utilizes CNPG's declarative hibernation feature to cleanly spin down the PostgreSQL instances, ensuring no data corruption or WAL desync occurs prior to the k3s process terminating. `./start-cluster.sh` reverses this process on boot.

**Note on Backups:** The database manifest (`cnpg-cluster.yaml`) contains a `ScheduledBackup` resource that performs an automated base backup to MinIO daily at midnight. To trigger an immediate out-of-band snapshot, use the CNPG plugin command detailed in the table above.

---

## Repository Structure

* `start-cluster.sh`: Initiates the k3s process, waits for the API server, and runs readiness health checks.
* `stop-cluster.sh`: Issues CNPG hibernation commands and gracefully terminates k3s.
* `sync-kubeconfig.sh`: Extracts and maps the k3s admin context to the local user directory.
* `vault-values.yaml`: Helm chart overrides for the in-cluster Vault StatefulSet.
* `vso-setup.yaml`: Provisions namespaces, service accounts, and Vault operator connection CRDs.
* `minio-backups.yaml`: Provisions the S3-compatible storage pod, PVCs, and automated bucket initialization jobs.
* `cnpg-cluster.yaml`: Deploys the PostgreSQL cluster, assigns backup endpoints, and defines the automated backup schedule.

---

## Troubleshooting Guide

* **Pod Initialization Failure:** Run `kubectl describe pod <pod_name> -n databases` and review the "Events" stream for exact scheduler or image pull errors.
* **Vault Permission Denied:** Verify the existence of the `postgis-role` policy generated in Step 6 via the Vault CLI.
* **Secrets Failing to Mount:** Run `kubectl describe vaultstaticsecret <name> -n databases`. The resource status conditions will report the specific API failure preventing VSO from fetching the credential.
* **Headlamp Visual Bugs (Ghost Clusters):** Close the Headlamp UI, purge its local cache directory (`%APPDATA%\Headlamp` on Windows), and relaunch the application.
* **k3s Port Conflicts:** If k3s logs show bind errors on port 6443, the systemd process is likely active. Run `systemctl is-enabled k3s` to verify it is disabled.

---

## Technical Debt

The following configurations require future remediation to meet standard production-hardening guidelines:

* **Permissive Ingress Network Policies:** The main Vault listener (port 8200) currently accepts internal cluster traffic globally. A Default Deny `NetworkPolicy` should be implemented to strictly restrict ingress traffic solely to the Vault Secrets Operator namespace.
* **Lack of High Availability (HA):** Both the PostgreSQL database and HashiCorp Vault are deployed as single replicas. While adequate for local development, this architecture lacks automatic failover redundancy.
