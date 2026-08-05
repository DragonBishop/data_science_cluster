# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a PostgreSQL server with the PostGIS extension enabled. It is intended to be scalable for data science projects, such as Extract, Transform, and Load (ETL) pipelines, Machine Learning (ML), and data analytics.

This cluster's architecture relies on a system-installed HashiCorp Vault to act as a transit to unseal a cluster-situated Vault. This cluster Vault is the primary store for all secrets in the cluster. Secure provisioning of environment variables from this vault allows users to combine ease of use and best practices for Secrets Management, intended for local use but scalable for enterprises if necessary.

**This branch targets native Linux (developed and tested on Ubuntu)**. If you're running under WSL2 on Windows, see the WSL2 branch of this project instead — the two diverge around Cilium's networking mode, Headlamp access, and a few host-level setup steps.

## Core Architecture

* **k3s:** A lightweight, certified Kubernetes distribution. It acts as the core control plane and execution environment for the database and its supporting services.
* **CloudNativePG (CNPG):** A Kubernetes operator that manages the PostgreSQL/PostGIS lifecycle — provisioning, reconciliation, hibernation, and backup orchestration — through Pods and PVCs.
* **Cilium:** The cluster's Container Network Interface (CNI). It replaces k3s's default networking components, provides eBPF-based routing and service load-balancing in place of kube-proxy, and serves the Gateway API.
* **HashiCorp Vault:** Two Vault instances. A **Transit Vault** runs natively on the Linux host. The **Main Vault** runs inside the cluster and unseals itself against the Transit Vault's transit seal at pod start, with no manual unseal step. The Transit Vault re-seals on every host reboot and requires one human-entered passphrase to unseal; `start-cluster.sh` supplies the three unseal keys from a GPG-encrypted keyfile (Step 3).
* **Vault Database Secrets Engine:** Vault connects to Postgres and issues login roles on demand. Each role is created with the lease and dropped when the lease ends. This deployment issues them with a 3h default TTL and a 24h maximum (Step 8).
* **Vault Secrets Operator (VSO):** A Kubernetes operator that reads values from the Main Vault and writes them into Kubernetes `Secret` objects, refreshing static secrets on an interval and renewing dynamic leases.
* **Barman Cloud Plugin:** The plugin CNPG uses for WAL archiving and base backups. This project configures backups through the plugin and the `ObjectStore` resource rather than the in-tree `spec.backup.barmanObjectStore` field.
* **cert-manager:** Issues the local CA and the Postgres server certificate, and reissues it before expiry. The certificate's SANs cover `localhost` and `127.0.0.1`, which is what allows `sslmode=verify-full` through the proxy. Also a required dependency of the Barman Cloud Plugin.
* **SeaweedFS:** An in-cluster, S3-compatible object store. CNPG streams WAL segments to it continuously and writes scheduled base backups to it.
* **Headlamp:** Lightweight GUI to monitor cluster status and implement changes. See the *WSL2* branch for workarounds to deploy Headlamp in a WSL2 stack.

## Repository Structure

Cluster state is managed by Flux (GitOps) rather than applied by hand, except
for the one-time imperative bootstrap Cilium requires before Flux's own
controllers have pod networking to run at all — see `README.md`'s setup
instructions and `infrastructure/cilium/` below.

* `README.md`: architecture, setup, and operations reference.
* `ROADMAP.md`: Planned future services and technical debt remediation.
* `pyproject.toml`, `.python-version`, `uv.lock`: uv-managed Python project
  scaffold for the ETL/ML tooling planned in `ROADMAP.md` — no dependencies
  yet.
* `.github/ISSUE_TEMPLATE/`: Issue templates for bug reports, documentation
  updates, feature proposals, and technical-debt resolution.
* `devcontainers/` - Provision a VSCode Dev Container to manage the cluster. Customize to suit your own needs!
  * `devcontainer.json`: Configuration file for a devcontainer designed to be platform and engine agnostic.
  * `Dockerfile` contains build instructions to provision a Data Science focused Dev Container.
* `scripts/`
  * `start-cluster.sh`: Sequential boot script enforcing API, Transit Vault unseal, Secret, and Database readiness state checks.
  * `stop-cluster.sh`: Graceful shutdown script utilizing CNPG declarative hibernation.
  * `sync-kubeconfig.sh`: Copies the live k3s kubeconfig into `~/.kube/config`.
* `clusters/local/` — Flux's own root, pointed at by `flux bootstrap
  --path=clusters/local`. One Kustomization per directory under
  `infrastructure/`/`apps/` below, `dependsOn`-chained into the install
  order the cluster actually needs: `gateway-api-crds` + `namespaces` →
  `cilium` → `cert-manager` + `dns` → `gateway` → `hubble`; separately,
  `vault` → `vault-secrets-operator` → `cnpg-operator` → `barman-cloud`
  (which also needs `cert-manager`) → `databases` (which also needs
  `gateway`, for its `TCPRoute` to attach to).
  * `flux-system/` (`gotk-components.yaml`, `gotk-sync.yaml`,
    `kustomization.yaml`): Flux's own controllers and `GitRepository`
    source, written by `flux bootstrap` — not hand-authored, don't edit
    directly.
  * `gateway-api-crds.yaml`, `namespaces.yaml`, `cilium.yaml`,
    `cert-manager.yaml`, `dns.yaml`, `gateway.yaml`, `hubble.yaml`,
    `vault.yaml`, `vault-secrets-operator.yaml`, `cnpg-operator.yaml`,
    `barman-cloud.yaml`, `databases.yaml`: one Flux `Kustomization` per
    matching directory below, each declaring its own
    `dependsOn`/`healthChecks`.
* `infrastructure/` — cluster-wide platform components, in the order Flux
  installs them.
  * `gateway-api-crds/`
    * `standard-install.yaml`: Vendored Gateway API v1.6.1 CRDs
      (upstream release manifest, pinned rather than floated) — Cilium's
      Gateway API support depends on these existing first.
    * `kustomization.yaml`
  * `namespaces/`
    * `namespaces.yaml`: Creates every namespace Flux needs a home for up
      front (`vault`, `vault-secrets-operator-system`, `cnpg-system`,
      `databases`, `cert-manager`, `gateway`, `dns`) — a `HelmRelease`
      doesn't auto-create its own namespace the way `helm install
      --create-namespace` does.
    * `kustomization.yaml`
  * `cilium/`
    * `cilium-release.yaml`: `HelmRepository` (OCI, `quay.io/cilium/charts`)
      and `HelmRelease` for Cilium 1.20.0, with `releaseName`/namespace
      matching the imperative bootstrap install so Flux adopts the
      existing release instead of installing a second one. `valuesFrom`
      has two entries: `cilium-values` (required) and `cilium-values-hubble`
      (`optional: true`) — the second ConfigMap is generated by
      `hubble/kustomization.yaml`, not this one, so it doesn't exist until
      cert-manager and `hubble-ca-issuer` are up. `optional: true` lets the
      HelmRelease install cleanly without it; `helm-controller` watches the
      ConfigMap and re-reconciles the moment it appears, merging Hubble's
      values in automatically.
    * `cilium-values.yaml`: Helm values — kube-proxy replacement, the k3s
      API server override (`--disable-kube-proxy` means nothing resolves
      the in-cluster API otherwise), single-replica operator, pod CIDR,
      Gateway API support, and L2 announcements for the shared Gateway and
      DNS resolver `LoadBalancer`s below.
    * `gateway-lb-pool.yaml` / `gateway-l2-policy.yaml`:
      `CiliumLoadBalancerIPPool` / `CiliumL2AnnouncementPolicy` handing a
      single static LAN IP to the shared Gateway's generated Service
      (`gateway.networking.k8s.io/gateway-name: internal-gateway` — the
      label Cilium's Gateway controller stamps on it, confirmed live).
      Replaces this repo's earlier `postgis-lb-pool`/`postgis-l2-policy`,
      which gave Postgres its own dedicated `LoadBalancer` before it moved
      onto this shared Gateway via a `TCPRoute`.
    * `dns-lb-pool.yaml` / `dns-l2-policy.yaml`: Same pattern, a second
      static LAN IP for the CoreDNS resolver's Service (`dns/` below).
    * `kustomization.yaml`: Bundles the release and all four LB/L2 objects,
      plus a `configMapGenerator` turning `cilium-values.yaml` into the
      `ConfigMap` the `HelmRelease`'s `valuesFrom` reads.
  * `cert-manager/`
    * `cert-manager-release.yaml`: `HelmRepository`/`HelmRelease` for
      cert-manager 1.21.1; CRDs are managed by the chart itself
      (`crds.enabled: true`), not vendored separately.
    * `kustomization.yaml`
  * `dns/`
    * `dns-release.yaml`: `HelmRepository`/`HelmRelease` for CoreDNS
      (official chart, `1.47.0`) — a standalone LAN-facing resolver,
      separate from k3s's own in-cluster CoreDNS. Answers any `*.internal`
      query with the shared Gateway's IP (a `template` plugin rule, not a
      per-hostname record — a new tool never needs a DNS edit, only a new
      `HTTPRoute`/`TCPRoute`) and forwards everything else to the LAN
      router, so a device can use it as its only DNS server.
    * `kustomization.yaml`
  * `gateway/`
    * `gateway-tls.yaml`: A dedicated self-signed local CA and
      `ClusterIssuer` chain (`gateway-ca-issuer`) issuing a wildcard
      `*.internal` certificate for the Gateway's own edge TLS — the cert a
      browser or `psql` client actually sees, distinct from Hubble's
      internal mTLS chain below.
    * `gateway.yaml`: The one shared `Gateway` (`internal-gateway`) every
      HTTP(S) tool and Postgres itself attaches a `Route` to instead of
      minting its own `LoadBalancer` — an HTTPS listener (443, TLS from
      `gateway-tls.yaml`) for web UIs, and a raw TCP listener (5432) for
      Postgres via `TCPRoute`. `allowedRoutes.namespaces.from: All` on both
      lets any namespace attach a `Route` without a `ReferenceGrant`.
    * `kustomization.yaml`
  * `hubble/`
    * `hubble-tls.yaml`: A second, separate self-signed local CA and
      `ClusterIssuer` chain (`hubble-ca-issuer`) — Hubble's internal mTLS
      trust domain (cilium-agent ↔ hubble-relay ↔ hubble-ui), kept apart
      from anything a browser trusts.
    * `hubble-httproute.yaml`: Attaches Hubble UI to the shared Gateway at
      `hubble.internal`.
    * `cilium-values-hubble.yaml`: Cilium chart values enabling Hubble
      Relay/UI with cert-manager-issued mTLS, referencing `hubble-ca-issuer`
      above. Generated as the `cilium-values-hubble` ConfigMap by this
      `kustomization.yaml`, which `cilium-release.yaml` reads as an
      optional `valuesFrom` source — this directory's own `dependsOn`
      (`cert-manager`, `gateway`) is what makes the ConfigMap not exist
      until the issuer it references is real.
    * `kustomization.yaml`
  * `vault/`
    * `vault-release.yaml`: `HelmRepository`/`HelmRelease` for the
      in-cluster Vault (chart `0.34.0`).
    * `vault-values.yaml`: Helm values — transit auto-unseal against the
      host-level Vault, the Agent Injector disabled (VSO syncs secrets
      instead of sidecar injection), TLS disabled on the client listener
      (access is restricted by cluster networking instead).
    * `kustomization.yaml`: Same release-plus-values-ConfigMap pattern as
      Cilium's.
  * `vault-secrets-operator/`
    * `vso-release.yaml`: `HelmRepository`/`HelmRelease` for the Vault
      Secrets Operator (chart `1.5.0`).
    * `kustomization.yaml`
  * `cnpg-operator/`
    * `cnpg-release.yaml`: `HelmRepository`/`HelmRelease` for the
      CloudNativePG operator (chart `0.29.0`).
    * `kustomization.yaml`
  * `barman-cloud/`
    * `barman-cloud-release.yaml`: `HelmRelease` for the Barman Cloud
      Plugin (chart `0.7.1`) — reuses the `cnpg-operator/` directory's own
      `HelmRepository` rather than declaring a second one for the same
      chart index.
    * `kustomization.yaml`
* `apps/databases/` — the PostGIS cluster and everything it depends on,
  reconciled as one Flux `Kustomization` (`clusters/local/databases.yaml`).
  * `kustomization.yaml`: every resource this Kustomization builds, in one
    pass.
  * `vso-setup.yaml`: Creates the `databases` namespace and the
    `VaultConnection`/`VaultAuth`/`ServiceAccount` VSO uses to authenticate
    to Vault.
  * `postgres-tls.yaml`: cert-manager `Issuer`s and `Certificate` producing
    the Postgres server certificate — SANs cover `localhost`/`127.0.0.1`
    (the socat proxy), the shared Gateway's static LAN IP, and
    `postgres.internal` (resolves to that same IP via `infrastructure/dns/`).
  * `postgis-cluster.yaml`: The CNPG `Cluster`, its static and dynamic
    Vault secrets, the `ObjectStore` and `ScheduledBackup` used for
    backups, and the `postgres-proxy` Deployment.
  * `postgis-tcproute.yaml`: `TCPRoute` attaching the CNPG primary to the
    shared Gateway's raw-TCP listener (`infrastructure/gateway/`) — no
    hostname/SNI matching, the listener maps 1:1 to this one backend.
    Replaces this repo's earlier dedicated `postgis-cluster-external`
    `LoadBalancer` Service.
  * `postgis-database.yaml`: CNPG `Database` CRD — declares `data_science`,
    its owner, schemas, and PostGIS extensions (reconciles on every
    generation change, unlike `postInitSQL`, which runs once at initdb).
  * `seaweedfs-release.yaml`: `HelmRepository`/`HelmRelease` for SeaweedFS
    (chart `4.40.0`) — master/filer data on the external HDD via
    `hostPath`, S3 gateway on port 9000 with the `cnpg-backups` bucket
    created at install.
  * `seaweedfs-credentials.yaml`: `VaultStaticSecret` syncing S3
    credentials from `secret/seaweedfs`.
  * `seaweedfs-networkpolicy.yaml`: Restricts SeaweedFS ingress to the
    `databases` namespace.
* `terraform/` — OpenTofu modules configuring Vault's internals (KV
  secrets, the Kubernetes auth backend, the database secrets engine).
  State is local, gitignored, and encrypted at rest via OpenTofu's own
  `encryption` block; these modules are applied by hand from the host, not
  reconciled by Flux.
  * `vault-bootstrap/`: KV mounts and secrets (`secret/postgis`,
    `secret/seaweedfs`), the Kubernetes auth backend, and the
    `postgis-policy`/`postgis-role` Vault uses to authorize the cluster's
    ServiceAccount.
  * `vault-database/`: The database secrets engine connection to
    `postgis-cluster` and the `postgis-app-role` issuing leased
    application credentials.

## Official Documentation

| Component | Documentation Link |
| --- | --- |
| k3s | [https://docs.k3s.io/](https://docs.k3s.io/) |
| Cilium | [https://docs.cilium.io/](https://docs.cilium.io/) |
| Gateway API | [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/) |
| HashiCorp Vault | [https://developer.hashicorp.com/vault/docs](https://developer.hashicorp.com/vault/docs) |
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

These detailed instructions are the product of repeated experimentation with cluster design, shell scripting, and best practices for cluster security. This process was produced with the assistance of artificial intelligence.

This setup workflow is designed to be completed sequentially. Deviating from this order may result in initialization failures.

### 1. Install k3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable traefik --disable servicelb --disable-kube-proxy --disable-network-policy --flannel-backend=none" sh -
```

The installer configures k3s as an auto-starting systemd service, so the cluster survives host reboots and setup can span multiple sessions.

The `INSTALL_K3S_EXEC` flags disable the k3s networking components Cilium replaces:

* `--disable traefik` and `--disable servicelb`: Skips k3s's bundled addon manifests (Traefik ingress controller, Klipper LoadBalancer).
* `--disable-kube-proxy`: Turns off the built-in kube-proxy supervisor component.
* `--flannel-backend=none` and `--disable-network-policy`: Prevents the default CNI and network policy controller from loading. Cilium performs routing and policy enforcement instead.
* `--write-kubeconfig-mode 644`: Sets the kubeconfig to world-readable, so non-root users can run `kubectl` and `helm`. Any local user can read cluster-admin credentials from that path.

Systemd manages the cluster during the initial build phase. The lifecycle scripts take over afterwards: the first run of `stop-cluster.sh` stops and disables `k3s.service`, after which k3s no longer starts at boot and `start-cluster.sh` owns startup. `start-cluster.sh` exits if the unit is still active, so the handover happens on the first clean shutdown rather than needing a separate step.

The installer also provides `kubectl`: k3s bundles its own copy and symlinks it to `/usr/local/bin/kubectl`, unless something already occupies that path. Verify it landed:

```bash
kubectl version --client
```

k3s writes its kubeconfig to `/etc/rancher/k3s/k3s.yaml`. `kubectl` reads `~/.kube/config`. Copy it across before continuing:

```bash
./scripts/sync-kubeconfig.sh
```

Helm is the package manager for Kubernetes. It automates deploying, upgrading, and managing complex Kubernetes applications using pre-configured template packages called "charts".

```bash
curl -fsSL -o /tmp/get-helm-3 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x /tmp/get-helm-3
/tmp/get-helm-3
rm /tmp/get-helm-3
```

### Headlamp Desktop (Optional)

While not mandatory, Headlamp is a lightweight GUI that can help you manage your cluster. Install the desktop application on Ubuntu via Flatpak:

```bash
flatpak install flathub dev.headlamp.Headlamp
```

*(Alternatively, download the latest `.deb` or `AppImage` from the [Headlamp GitHub Releases page](https://github.com/headlamp-k8s/headlamp/releases)).*

Launch Headlamp from your application menu (or `flatpak run dev.headlamp.Headlamp` in the terminal) — it reads the synced `~/.kube/config` and connects.

### 2. Install Gateway API and Cilium

#### 2a. Install the Gateway API CRDs

The Gateway API CRDs must be installed before Cilium. The CRD version must match what the Cilium release requires: Cilium 1.20.x requires Gateway API v1.6.1. A mismatch leaves the GatewayClass in an `ACCEPTED: Unknown` state rather than reporting an error. This deployment uses the standard (GA) release channel.

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
```

`--server-side` records field ownership against a named manager, which lets Argo CD adopt these objects later without a conflict. (The size limit that makes server-side apply mandatory applies to the Experimental channel CRDs, not the standard channel used here.)

Both versions move together. Bumping Cilium means checking the Gateway API version its release notes require and reapplying the matching CRDs first.

#### 2b. Install the Cilium CLI

Retrieve the latest stable CLI release, verify its checksum, and install the executable to `/usr/local/bin`. The CLI is used for status and connectivity checks, not for the install itself.

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

The devcontainer image installs its own copy of the Cilium CLI. The two are independent and can drift.

#### 2c. Deploy Cilium

Chart values live in `manifests/cilium-values.yaml`.

```bash
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium --version 1.20.0 \
  --namespace kube-system -f manifests/cilium-values.yaml
```

`cilium` is the release name; `oci://quay.io/cilium/charts/cilium` is the chart, resolved straight from the registry. `upgrade --install` is used rather than `install` because a failed install still occupies the release name, and `helm list` does not show it without `-a` — a subsequent plain `install` then fails on a name conflict.

Verify the node leaves `NotReady` and that kube-proxy replacement is active:

```bash
kubectl get nodes
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
```

### 3. Deploy the Host-Level Transit Vault

This Vault instance runs directly on the host and unseals the cluster's Main Vault.

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update && sudo apt install -y vault
```

Generate the TLS certificate the in-cluster Vault verifies:

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

The certificate carries `vault.local` rather than the host's IP. Add `127.0.0.1 vault.local` to `/etc/hosts`. The in-cluster Main Vault connects to Transit by IP — `vault-values.yaml`'s seal `address`, substituted from the Downward API at every pod start — and verifies the certificate against the `vault.local` name through `tls_server_name`, so an IP change requires no cert or config update.

Modify `/etc/vault.d/vault.hcl`. Bind the listener to `0.0.0.0:8200` so the cluster can reach it, and define `api_addr`:

```hcl
api_addr = "https://vault.local:8200"

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/opt/vault/tls/tls.crt"
  tls_key_file  = "/opt/vault/tls/tls.key"
}
```

Enable the service, initialize Vault, and configure the transit secrets engine:

```bash
sudo systemctl enable --now vault

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"
vault operator init
```

CRITICAL: Store the generated 5 Unseal Keys and 1 Initial Root Token in a secure password manager immediately. If lost, data is irrecoverable.

Unseal the Transit Vault by providing three different unseal keys:

`vault operator unseal`

Then use the initial root token given to you by the vault to login:

`vault login`

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

Store this token. The in-cluster Vault's transit seal client renews it on use (`disable_renewal` defaults to `"false"`). The 768h period is 32 days, so it expires only if the cluster stays down longer than that; reissue with the same command and update `vault-transit-secret` if it does.

**Automating future unseals (one-time setup):**

The Transit Vault re-seals on every host reboot, which would otherwise mean re-running the three `vault operator unseal` calls by hand each time. `scripts/start-cluster.sh` decrypts the three keys from a GPG-encrypted keyfile behind a single passphrase.

Generate the keyfile once, from a RAM-backed tmpfs so the plaintext keys never touch disk:

```bash
mkdir -p /dev/shm/vault-setup && cd /dev/shm/vault-setup

# There's a few ways to paste the same 3 keys used above into keys.txt
# But Nano allows double checking your work:
sudo nano keys.txt

gpg --batch --yes --cipher-algo AES256 --symmetric keys.txt
mv keys.txt.gpg ~/.vault-keys.gpg
chmod 600 ~/.vault-keys.gpg
cd / && rm -rf /dev/shm/vault-setup
```

Set the GPG passphrase cache to expire immediately, so it does not persist past the unseal:

```bash
cat >> ~/.gnupg/gpg-agent.conf <<'EOF'
default-cache-ttl 0
max-cache-ttl 0
EOF
gpgconf --reload gpg-agent
```

From this point on, `scripts/start-cluster.sh` checks whether the Transit Vault is sealed and prompts for this passphrase when it is.

### 4. Deploy the In-Cluster Main Vault

Add the HashiCorp Helm repository:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

Create the namespace and the objects `vault-values.yaml` references:

```bash
kubectl create namespace vault

kubectl create secret generic vault-transit-secret \
  --from-literal=token='<token from step 3>' -n vault

kubectl create configmap vault-transit-ca \
  --from-file=ca.crt=/opt/vault/tls/tls.crt -n vault
```

`vault-transit-secret` supplies `VAULT_TOKEN` to the server container; the transit seal authenticates to the host Vault with it. `vault-transit-ca` is mounted at `/vault/userconfig/vault-transit-ca/` and is the CA the seal's `tls_ca_cert` points at. Both are created imperatively and are not reconciled from git.

The `seal "transit"` block addresses the host as `HOST_IP`. The Vault Helm chart's entrypoint substitutes that variable from the Downward API during pod initialization, so the address tracks the host across restarts. `tls_server_name = "vault.local"` is the name the certificate is verified against.

Deploy using `manifests/vault-values.yaml`:

```bash
helm upgrade --install vault hashicorp/vault -n vault -f manifests/vault-values.yaml
```

Initialize this instance. Because the seal is a transit seal, `operator init` returns **recovery** keys rather than unseal keys, alongside a new root token. Store both.

```bash
kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator init"
```

The output reports `Sealed: false`, which confirms the auto-unseal path works.

### 5. Configure Vault Kubernetes Authentication and Seed Application Credentials

Configure the auth method VSO uses, the policy it authenticates under, and the KV values the workloads consume.

Performing this inside a pod shell keeps passwords and tokens out of host process arguments (`/proc/<pid>/cmdline`):

```bash
kubectl exec -it vault-0 -n vault -- sh
```

Once inside, set the VAULT_ADDR environment variable, and use vault login and your root token to authenticate:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
unset VAULT_TOKEN
vault login
```

#### A. Enable Engines and Configure Kubernetes Auth

Enable the KV-v2 secrets engine and Kubernetes authentication backend, pointing Vault to the internal cluster API endpoint:

```bash
vault secrets enable -path=secret kv-v2

vault auth enable kubernetes

vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc"
```

#### B. Define ACL Policies and Auth Roles

The five paths below are the ones VSO reads: the two KV secrets in both their data and metadata forms, and the dynamic credential endpoint configured in Step 8.

```bash
vault policy write postgis-policy - <<EOF
path "secret/data/postgis" { capabilities = ["read"] }
path "secret/data/seaweedfs" { capabilities = ["read"] }
path "secret/metadata/postgis" { capabilities = ["read"] }
path "secret/metadata/seaweedfs" { capabilities = ["read"] }
path "database/creds/postgis-app-role" { capabilities = ["read"] }
EOF
```

Bind that policy to the service account VSO authenticates as. The name and namespace here must match the `ServiceAccount` in `vso-setup.yaml`:

```bash
vault write auth/kubernetes/role/postgis-role \
  bound_service_account_names=postgis-vault-auth \
  bound_service_account_namespaces=databases \
  policies=postgis-policy \
  ttl=24h
```

> **Note:** Vault warns that `postgis-role` has no bound audience. The role is created without one, so Vault accepts the token regardless of its audience claim. `vso-setup.yaml` sets `audiences: [vault]` on the `VaultAuth`, which is the audience the projected token carries.

#### C. Seed Application Credentials

Inject required credentials into the Vault KV store directly within your active shell session:

* **`secret/postgis`**: The superuser credential. CNPG reads it at initdb time and reconciles it thereafter; Vault's database secrets engine (Step 8) also authenticates as this user to create and drop the roles it issues. It is static because the credential that manages leases cannot itself be one.
* **`secret/seaweedfs`**: The same access/secret key pair stored twice — as flat fields (`ACCESS_KEY_ID`/`ACCESS_SECRET_KEY`, read by the `ObjectStore`'s `s3Credentials`) and rendered into the JSON identity file SeaweedFS's S3 gateway mounts (`config.json`). Nothing checks that the two representations agree; if they diverge, S3 authentication fails and the first symptom is a failed WAL archive.
* **Note:** Generate or retrieve these S3 credentials and store them securely before injecting them into Vault.

```bash
vault kv put secret/postgis username="postgres" password="<your password>"
```

To make the seaweed secret easier to enter, first create environment variables within the shell:

```bash
S3_ACCESS_KEY="<your access key>"
S3_SECRET_KEY="<your secret key>"
```

Add the secret using the envs:

```bash
vault kv put secret/seaweedfs \
  ACCESS_KEY_ID="$S3_ACCESS_KEY" \
  ACCESS_SECRET_KEY="$S3_SECRET_KEY" \
  config.json="{\"identities\":[{\"name\":\"cnpg\",\"credentials\":[{\"accessKey\":\"${S3_ACCESS_KEY}\",\"secretKey\":\"${S3_SECRET_KEY}\"}],\"actions\":[\"Read\",\"Write\",\"List\",\"Tagging\",\"Admin\"]}]}"
```

Verify it landed: `vault kv get secret/seaweedfs`

Remove your environment variables and exit the shell:

```bash
unset S3_ACCESS_KEY S3_SECRET_KEY
exit
```

### 6. Install Software Operators

cert-manager is a prerequisite for both the PostGIS server certificate (Step 7) and the Barman Cloud Plugin. Install it first and wait for it:

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
kubectl get deployment -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg \
  -o jsonpath="{.items[*].spec.template.spec.containers[*].image}"
```

Then install the plugin into the same namespace as the operator (check the [releases page](https://github.com/cloudnative-pg/plugin-barman-cloud/releases) for a version newer than v0.13.0 before running this):

```bash
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.13.0/manifest.yaml
kubectl rollout status deployment -n cnpg-system barman-cloud
```

The `barman-cloud` Deployment must be running before the Cluster can archive WAL. It is a separate readiness gate from the CNPG operator itself.

Finally, install the `cnpg` kubectl plugin. It supplies `kubectl cnpg status`, `kubectl cnpg backup`, and `kubectl cnpg psql`, which the Cluster Operations table and the troubleshooting steps below rely on, and which `stop-cluster.sh` names in its hibernation warning:

```bash
curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh \
  | sudo sh -s -- -b /usr/local/bin
kubectl cnpg version
```

### 7. Deploy the Database and Storage Infrastructure

The `database:` and `owner:` values in `manifests/postgis-cluster.yaml` are both `postgres`, and the username seeded into Vault must match. CNPG hardcodes `postgres` as the superuser name and compares it against the `username` field of the Secret, rejecting a mismatch with `wrong username '<x>' in secret, expected 'postgres'`. That comparison happens before the password is applied, so a mismatch presents as failed password authentication against a password that reads back correctly from Vault.

Both of these fields are required together:

```yaml
enableSuperuserAccess: true
superuserSecret:
  name: postgis-app-credentials
```

Without `enableSuperuserAccess: true`, CNPG sets the role's password to NULL on every reconciliation. With `enableSuperuserAccess: true` and no `superuserSecret`, CNPG generates its own random `<cluster-name>-superuser` password and the Vault-seeded credential is not used.

Apply in this order — `vso-setup.yaml` creates the namespace everything else lives in, and `postgres-tls.yaml` must exist before `postgis-cluster.yaml` references the Secret it produces:

```bash
kubectl apply -f manifests/vso-setup.yaml
kubectl apply -f manifests/postgres-tls.yaml
kubectl apply -f manifests/seaweedfs-backups.yaml
kubectl apply -f manifests/postgis-cluster.yaml
kubectl get pods -n databases -w
```

Monitor until both the `seaweedfs` and `postgis-cluster-1` pods report `Running`.

`seaweedfs-backups.yaml` includes a Job that creates the `cnpg-backups` bucket. It deletes itself 600 seconds after succeeding, so it runs again on each re-apply of that manifest. It does not run on a normal cluster start. If SeaweedFS is ever rebuilt on an empty volume, re-apply the manifest to recreate the bucket; otherwise the missing bucket first appears as a failed WAL archive.

**Connecting with verified TLS:** the certificate covers `localhost` and `127.0.0.1`, so a client connecting through the `postgres-proxy` bridge can use `sslmode=verify-full`. Trust the cluster's local CA:

```bash
mkdir -p ~/.postgresql
kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt
```

`libpq` reads `~/.postgresql/root.crt` automatically, so `psql "host=localhost port=5432 dbname=postgres user=postgres sslmode=verify-full"` verifies the certificate rather than only encrypting the connection.

`postgres-tls.yaml` generates a new self-signed CA each time it is applied to an empty namespace. Rebuilding the cluster therefore produces a different CA, and every client still holding the old `root.crt` fails verification until this command is re-run.

The certificate's SANs cover `postgis-cluster-rw` in all four DNS forms, `postgis-cluster-ro` and `postgis-cluster-r` in their short and fully-qualified forms only, plus `localhost` and `127.0.0.1`. Connecting to a name not on that list fails hostname verification.

**Enabling PostGIS and the application privilege set:** `bootstrap.initdb.postInitSQL` in `manifests/postgis-cluster.yaml` installs the PostGIS extension and creates the `app_readwrite` group that every role Vault issues in Step 8 inherits from. Those statements run against the `postgres` database once, at initdb — not on re-apply, not on a running cluster, and not on a cluster bootstrapped from a backup. The manifest is the only copy; what each statement covers is documented there.

On a cluster that already exists, apply them directly:

```bash
yq 'select(.kind == "Cluster") | .spec.bootstrap.initdb.postInitSQL[] + ";"' \
  manifests/postgis-cluster.yaml \
  | kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d postgres
```

Verify the extension is installed:

```bash
kubectl cnpg psql postgis-cluster -n databases -- postgres -c 'SELECT postgis_full_version()'
```

### 8. Configure Dynamic Application Credentials

With the cluster online and `app_readwrite` created, configure Vault's database secrets engine. This registers the connection Vault opens to `postgis-cluster-rw` and the role it issues leases from.

As in Step 5, create an interactive shell in the vault:

```bash
kubectl exec -it vault-0 -n vault -- sh
```

Once inside, set the address, clear the inherited token, and authenticate:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
unset VAULT_TOKEN
vault login
```

The pod's shell inherits `VAULT_TOKEN` from `extraSecretEnvironmentVars`, holding the transit seal token. That environment variable takes precedence over the token `vault login` writes, so it has to be cleared first.

Enable the database secrets engine and register the connection Vault uses to create and drop roles:

```bash
vault secrets enable database

vault write database/config/postgis-cluster \
  plugin_name=postgresql-database-plugin \
  allowed_roles="postgis-app-role" \
  connection_url="postgresql://{{username}}:{{password}}@postgis-cluster-rw.databases.svc.cluster.local:5432/postgres?sslmode=require" \
  username="postgres" \
  password="<the same password you seeded into secret/postgis in Step 5>"
```

This password is now stored in two places that are not linked: here, and at `secret/postgis` in Vault's KV store. CNPG reconciles the Postgres password from the KV value. Changing the KV value alone leaves this connection config stale and Vault stops being able to issue credentials; running `vault write -f database/rotate-root/postgis-cluster` changes the password here and CNPG's next reconciliation sets it back from KV. Rotating the superuser password means updating both, in one operation.

Define the role leases are issued from. Each lease creates a login role that expires with it and takes its privileges from the `app_readwrite` group created in Step 7. `SET role` makes `app_readwrite` the current role on every connection the lease opens, so objects it creates are owned by the group and outlive the lease:

```bash
vault write database/roles/postgis-app-role \
  db_name=postgis-cluster \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_readwrite; ALTER ROLE \"{{name}}\" SET role = app_readwrite;" \
  default_ttl="3h" \
  max_ttl="24h"
```

`exit` the pod shell once these complete.

Confirm it worked:

```bash
kubectl get vaultdynamicsecret postgis-app-dynamic-secret -n databases
kubectl get secret postgis-app-dynamic-credentials -n databases -o jsonpath='{.data.username}' | base64 -d
```

Confirm the issued role carries the privileges — `app_readwrite` appears in its "Member of" column:

```bash
kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d postgres -c '\du'
```

An issued role reads and writes every schema in the database and creates objects in any of them. Adjusting the privilege set means altering `app_readwrite`; the change applies to the next lease issued, not to leases already outstanding. Replacing this role definition also requires `vault lease revoke -prefix database/creds/postgis-app-role` — outstanding leases keep the statements they were created with.

## **Restoring the Database from SeaweedFS**

Recovery with the Barman Cloud Plugin is not in-place. It bootstraps a *new* cluster from the object store and replays WAL to a chosen point, leaving the original untouched. Define the backup as an external cluster and name it as the bootstrap source:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgis-restore
  namespace: databases
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgis:18.3-3.6.2-system-trixie
  storage:
    size: 100Gi
    storageClass: local-path
  enableSuperuserAccess: true
  superuserSecret:
    name: postgis-app-credentials
  bootstrap:
    recovery:
      source: postgis-backup-store
      # Omit recoveryTarget to replay every archived WAL segment. To recover to
      # a moment before a mistake, name it here instead:
      # recoveryTarget:
      #   targetTime: "2026-07-30 21:15:00.00000+00"
  externalClusters:
    - name: postgis-backup-store
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: postgis-backups
          serverName: postgis-cluster
```

`serverName` selects which server's backups to read from the object store. It defaults to the name of the cluster being created, so restoring into a differently-named cluster requires it to be set explicitly to `postgis-cluster`. Without it, the restore finds no backups.

The restore cluster carries no `plugins` stanza, so it archives nothing and does not write into the path the live cluster owns. Two archiving clusters sharing one object store path overwrite each other's history.

The restore cluster's `storage.size` must be at least the source cluster's, and it is a third `local-path` claim on the same disk as the live database and the backup store. `local-path` creates a directory and does not enforce the requested size, so confirm the space exists before starting:

```bash
df -h /var/lib/rancher/k3s/storage
kubectl apply -f /tmp/postgis-restore.yaml
kubectl get cluster postgis-restore -n databases -w
kubectl cnpg psql postgis-restore -n databases -- postgres -c '\dt'
kubectl delete cluster postgis-restore -n databases
```

Note that a restored cluster does not run `postInitSQL`. Roles and installed extensions come from the base backup.

Deleting the Cluster leaves its PersistentVolumeClaim behind; remove that too once the rehearsal is done:

```bash
kubectl delete pvc -n databases -l cnpg.io/cluster=postgis-restore
```

Rehearse this once while the setup is fresh. A restore path that has never been executed is not known to work.

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

* **Scheduled Backups:** the `ScheduledBackup` in `postgis-cluster.yaml` runs at midnight daily. It carries no `immediate` flag, so the first base backup after a rebuild is taken at the next midnight; until one exists, archived WAL has no base to be applied to. The `ObjectStore` prunes backups and their WAL older than 30 days. SeaweedFS is configured for up to 100 volumes of 1024MB. That store and the database share one physical disk and one `local-path` provisioner, which enforces no size limit on either claim, so neither the 100Gi figures nor the volume cap bound growth before the disk itself does. These backups cover operator error and corruption, not loss of the drive.
* **Lifecycle Management:** `start-cluster.sh` proceeds in order: refuse if `k3s.service` is active → launch k3s → API responding → node Ready → host Transit Vault unsealed → transit token renewed → in-cluster Vault unsealed → VSO secrets synced → CNPG operator Ready → un-hibernate → final health checks. Only the first four steps exit on failure; from the Transit Vault onward a failure records a warning and the script continues, exiting 1 at the end. The final checks cover the SeaweedFS pod and the CNPG cluster phase, and run after un-hibernation rather than gating it. cert-manager and the `barman-cloud` Deployment are not checked at all, so the run can report success while WAL archiving is not functional.
* `stop-cluster.sh` confirms the CNPG operator is Available, sets the hibernation annotation, and waits up to 300s for the operator to confirm or for the instance pods to disappear. k3s is not stopped until one of those holds, unless `--force` is passed. A systemd-owned k3s is stopped with `systemctl disable --now`; a script-launched one gets SIGTERM at the PID bound to 6443.

## Troubleshooting Guide

### Startup and Shutdown

* **`start-cluster.sh` refuses to start**
  * **What's happening:** The system's background k3s service (`k3s.service`) is already active. Running two k3s instances against the same data directory will corrupt your cluster.
  * **How to fix it:** Hand lifecycle management over to the scripts. Run `sudo systemctl disable --now k3s`. `systemctl is-enabled k3s` confirms which supervisor owns it. *(Note: `stop-cluster.sh` disables this automatically the first time it finds it).*

* **Scripts finish with an "exit 1" error, but everything looks healthy**
  * **What's happening:** Both scripts flag non-fatal warnings without swallowing the errors.
  * **How to fix it:** If the summary says "review warnings," the process finished but encountered problems along the way — it did not abort. Scroll up and look for the ❌ or ⚠️ icons to see what triggered the warning.

* **`stop-cluster.sh` halts before k3s actually stops**
  * **What's happening:** The script requires the database to hibernate before shutting down the cluster. If k3s stops while PostgreSQL is running, the database is killed ungracefully.
  * **How to fix it:** Read the halt message to see what is holding up the process. To shut down immediately and accept a crash recovery on the next boot, use the `--force` flag.

* **Hibernation shows as "not confirmed" when stopping**
  * **What's happening:** The script could not verify that the database shut down cleanly.
  * **How to check if it actually failed:** On the next start, run `kubectl logs -n databases postgis-cluster-1 -c postgres | grep -i "cluster state"`. `Database cluster state: shut down` with a timestamp means the shutdown was clean and the script did not wait long enough to observe it.
  * **If it genuinely failed, it's usually one of three things:**
    1. **Idle database connections:** `spec.smartShutdownTimeout` in `postgis-cluster.yaml` is set to 15 (the CNPG default is 180). Postgres waits that long for existing connections to close before escalating to a fast shutdown, which disconnects them. An idle DBeaver session extends the smart-shutdown phase up to that limit. Check for active connections before stopping: `kubectl exec -n databases postgis-cluster-1 -c postgres -- psql -U postgres -c "select pid, usename, application_name, state from pg_stat_activity where backend_type='client backend';"`
    2. **CloudNativePG (CNPG) operator isn't available:** The shutdown command was sent, but the operator was not running to process it. The stop script usually catches this first and halts with a specific warning.
    3. **The cluster isn't healthy:** A cluster will not hibernate from a broken state, such as a pod in CrashLoop or mid-boot. Check with `kubectl cnpg status postgis-cluster -n databases`.

* **Port 6443 is still bound/in-use after running `stop-cluster.sh`**
  * **What's happening:** The API server stopped, but containerd shims are still running.
  * **How to fix it:** Once hibernation is confirmed, run `sudo k3s-killall.sh`. It cleans up leftover processes and unmounts directories. Run it before restarting if the previous stop was forced.

---

### Vault

* **Vault reports as "sealed" when it isn't (or prompts for a GPG password on every run)**
  * **What's happening:** `vault status` returns `0` for unsealed, `2` for sealed, and another code if the command itself failed — a bad certificate or a dead service. A check that greps the output for "false" treats a failed connection as sealed and goes looking for unseal keys.
  * **How to fix it:** Diagnose using the exit code rather than the text output:

    ```bash
    VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/tls/tls.crt vault status; echo "exit=$?"
    ```

    Confirm the certificate path (`/opt/vault/tls/tls.crt`) is correct and readable (`sudo stat -c "%a %U:%G %n" /opt/vault/tls`). The certificate must include an `IP:127.0.0.1` SAN. If Vault is re-sealing without a reboot, check `systemctl status vault` for a crashing service.

* **GPG decryption fails**
  * **What's happening:** The script cannot read or decrypt the unseal keys.
  * **How to fix it:**
    1. Confirm `~/.vault-keys.gpg` exists and is mode `600` (`ls -l ~/.vault-keys.gpg`).
    2. Confirm the passphrase matches the one set in Step 3.
    3. *Technical note:* `vault operator unseal` does not accept piped input, so the script passes the key via `vault write sys/unseal key=-` instead. To exercise that mechanism without changing the seal state, run `printf 'SENTINEL\n' | vault write -output-curl-string sys/unseal key=-` — the output contains `SENTINEL`.

* **Vault throws a "permission denied" error**
  * **How to fix it:** Check the policy and role from Step 5. `vault policy read postgis-policy` shows the five paths it should grant; `vault read auth/kubernetes/role/postgis-role` shows the service account and namespace it is bound to.

* **Secrets are failing to mount into Kubernetes**
  * **How to fix it:** Run `kubectl describe vaultstaticsecret <name> -n databases` (or `vaultdynamicsecret` for dynamic credentials). The status conditions at the bottom report why VSO could not pull the secret.

* **Dynamic credentials never reach a "Ready" state**
  * **How to fix it:** Confirm Step 8 was run against a live `postgis-cluster-rw` service, which requires Step 7 to have been applied first. Confirm the Step 5 policy includes `database/creds/postgis-app-role` and not only the KV paths. `kubectl describe vaultdynamicsecret postgis-app-dynamic-secret -n databases` reports Vault's error.

---

### Database

* **Database pod fails to initialize**
  * **How to fix it:** Run `kubectl describe pod <pod_name> -n databases` and read the Events stream at the bottom. It reports scheduling failures, insufficient resources, and image pull failures.

* **Password authentication fails even though the password is correct**
  * **How to fix it:** Confirm both `enableSuperuserAccess: true` and `superuserSecret` are set in `postgis-cluster.yaml`. With the first missing, CNPG nulls the password on every reconciliation. Confirm the `username` field in `secret/postgis` is exactly `postgres`; CNPG rejects any other value before applying the password.

* **A role issued by Vault cannot create tables in a schema**
  * **What's happening:** the schema predates the `app_readwrite_new_schema` event trigger, so no `CREATE` grant was issued on it. `pg_read_all_data` and `pg_write_all_data` cover data access, not DDL.
  * **How to fix it:** `GRANT USAGE, CREATE ON SCHEMA <name> TO app_readwrite;`. Confirm the event trigger exists with `\dy`; without it, schemas created from now on have the same problem.

* **Tables created by a lease are unreadable by the next one**
  * **What's happening:** the lease was issued before `ALTER ROLE ... SET role = app_readwrite` was added to `creation_statements`, so it owns its objects. `DROP ROLE` at lease expiry also fails with `cannot be dropped because some objects depend on it`.
  * **How to fix it:** update the role definition in Step 8, then `vault lease revoke -prefix database/creds/postgis-app-role`. Reassign what already exists as `postgres`: `REASSIGN OWNED BY "<lease-role>" TO app_readwrite;`, then drop the stale role.
* **Application credentials stop working after a password rotation**
  * **What's happening:** VSO updated the Secret, but CNPG did not reload it.
  * **How to fix it:** Re-apply the reload label to trigger a reconciliation: `kubectl label secret postgis-app-credentials -n databases cnpg.io/reload=true --overwrite` (use `postgis-app-dynamic-credentials` for the dynamic credential). If the rotation was of the superuser password, also update `database/config/postgis-cluster` in Vault — see Step 8.

* **Database connections fail with a hostname mismatch when using `sslmode=verify-full`**
  * **What's happening:** The name used to connect is not in the certificate.
  * **How to fix it:** Check `dnsNames` and `ipAddresses` in `manifests/postgres-tls.yaml`. `localhost` and `127.0.0.1` are covered; `postgis-cluster-ro` and `postgis-cluster-r` are covered in their short and fully-qualified forms only. Adding a name there causes cert-manager to reissue the certificate. If the cluster was rebuilt, the CA also changed — re-run the `root.crt` command in Step 7.

* **Barman Cloud Plugin backups start failing**
  * **What's happening:** The database cannot reach or authenticate to the object store.
  * **How to fix it:** Run `kubectl cnpg status postgis-cluster -n databases` and read the plugin's status block. Confirm the `barman-cloud` Deployment in `cnpg-system` is running. Confirm the `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY` fields in `seaweedfs-credentials` match the credentials inside that Secret's `config.json`; a mismatch between the two produces no error until an archive is attempted. Confirm the bucket exists (`kubectl exec deploy/seaweedfs -n databases -- weed shell -master=localhost:9333 -c "fs.ls /buckets"`) and re-apply `seaweedfs-backups.yaml` to recreate it if it does not.

---

### Tooling

* **Pods are stuck in `ContainerCreating` indefinitely**
  * **What's happening:** Cilium is still initializing. Without the CNI, the container sandbox cannot be created.
  * **How to fix it:** Run `cilium status --wait`. If it persists after Cilium is running, check that the BPF filesystem is mounted (`mount | grep bpf`); a hard shutdown can leave it unmounted. *(Note: `/var/run/cilium/cgroupv2` is an active mount and must be unmounted before running `rm -rf /var/run/cilium`)*.

* **Pods are running but completely unreachable (Stale Cilium Endpoints)**
  * **What's happening:** After a forced stop or an agent restart, pods can retain endpoints that no longer route.
  * **How to fix it:** Run `kubectl exec -n kube-system ds/cilium -- cilium endpoint list` to view active endpoints. Delete the affected pods (`kubectl delete pod <pod_name>`); the controller recreates them with new network identities.

* **Headlamp shows a stale or failed connection**
  * **What's happening:** Headlamp reads `~/.kube/config` as written by `sync-kubeconfig.sh`. Running that script while the cluster was down produces a profile that does not connect.
  * **How to fix it:** Start the cluster, run `sync-kubeconfig.sh` again, and reconnect Headlamp.