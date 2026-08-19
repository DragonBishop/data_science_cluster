# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a PostgreSQL server with the PostGIS extension enabled. It is intended to be scalable for data science projects, such as Extract, Transform, and Load (ETL) pipelines, Machine Learning (ML), and data analytics.

This cluster's architecture relies on a system-installed HashiCorp Vault to act as a transit to unseal a cluster-situated Vault. This cluster Vault is the primary store for all secrets in the cluster. Secure provisioning of environment variables from this vault allows users to combine ease of use and best practices for Secrets Management, intended for local use but scalable for enterprises if necessary.

**This branch targets native Linux (developed and tested on Ubuntu)**. If you're running under WSL2 on Windows, the WSL2 branch is still in development.

## Table of Contents

* [Core Database Architecture](#core-database-architecture)
* [Foundational Cluster Service](#foundational-cluster-services)
* [ETL Pipeline Services](#etl-pipeline-services)
* [Machine Learning Services](#machine-learning-services)
* [Official Documentation](#official-documentation)
* [Cluster Operations](#cluster-operations)
* [Restoring the Database from SeaweedFS](#restoring-the-database-from-seaweedfs)
* [Repository Structure](#repository-structure)
* [File Descriptions](#file-descriptions)

## Core Database Architecture

Version is what's actually running right now — checked against the live cluster, host, or devcontainer — not the Helm chart version floated in each release manifest. Where the two diverge, the chart's own pin is called out in the Description. Nowhere else in this README restates these versions.

Rows below are ordered to match this repo's directory listing (`apps/` → `clusters/` → `infrastructure/`, alphabetically within each), the same order GitHub's file browser renders them in; items with no repo path (`k3s`, `Headlamp`) bookend the table.

| Component | Version | Description |
| --- | --- | --- |
| k3s | `v1.36.2+k3s1` | Core control plane and execution environment. Host-installed, unpinned by this repo. |
| PostgreSQL / PostGIS image | `18.3-3.6.2-system-trixie` | Image the CNPG `Cluster` runs, pinned in `apps/databases/postgis-cluster.yaml`. |
| SeaweedFS | `4.40` | In-cluster S3-compatible object store. CNPG streams WAL and writes scheduled base backups to it. Helm chart pinned to `4.40.0` in `apps/databases/seaweedfs-release.yaml`. |
| Flux | `v2.9.3` | GitOps controller; reconciles every `Kustomization` under `clusters/local/`, `dependsOn`-chained starting Gateway API CRDs → Cilium. CLI-installed, unpinned by this repo. |
| Barman Cloud Plugin | `v0.14.0` | WAL archiving and base backups for CNPG, via the `ObjectStore` resource rather than in-tree `spec.backup.barmanObjectStore`. Helm chart pinned to `0.7.1` in `infrastructure/barman-cloud/barman-cloud-release.yaml`. |
| cert-manager | `v1.21.1` | Issues the local CA and Postgres server certificate, reissues before expiry. Required by the Barman Cloud Plugin. Helm chart pinned in `infrastructure/cert-manager/cert-manager-release.yaml`. |
| Cilium | `1.20.0` | CNI; replaces k3s's default networking, eBPF routing/load-balancing in place of kube-proxy, serves the Gateway API. Helm chart pinned in `infrastructure/cilium/cilium-release.yaml`. |
| CloudNativePG (CNPG) | `1.30.0` | Operator managing the PostgreSQL/PostGIS lifecycle: provisioning, reconciliation, hibernation, backup orchestration. Helm chart pinned to `0.29.0` in `infrastructure/cnpg-operator/cnpg-release.yaml`. |
| DNS (CoreDNS) | `1.14.6` | Standalone resolver, separate from k3s's in-cluster CoreDNS. Answers `*.internal` with the shared Gateway's IP, forwards everything else to the LAN router. Helm chart pinned to `1.47.0` in `infrastructure/dns/dns-release.yaml`. |
| Gateway | `v1.6.1` (CRDs) | One shared `Gateway` (`internal-gateway`) every workload attaches a `Route` to. HTTPS listener (443) + raw TCP listener (5432) for Postgres via `TCPRoute`. Defined in `infrastructure/gateway/gateway.yaml`. |
| Gateway API | `v1.6.1` (CRDs) | Vendored, pinned rather than floated, in `infrastructure/gateway-api-crds/standard-install.yaml`. Cilium's Gateway API support depends on these existing first. |
| Hubble | `v1.20.0` (Relay), `v0.13.5` (UI) | Cilium's network observability layer. Relay/UI run their own cert-manager mTLS trust domain; UI exposed at `hubble.internal`. Configured in `infrastructure/hubble/`, bundled with the Cilium chart. |
| HashiCorp Vault (in-cluster) | `2.0.3` | Main Vault; auto-unseals against the host's native Transit Vault at pod start. Helm chart pinned to `0.34.0` in `infrastructure/vault/vault-release.yaml`. |
| Vault Secrets Operator (VSO) | `1.5.0` | Reads Main Vault values into Kubernetes `Secret`s; refreshes static secrets, renews dynamic leases. Helm chart pinned in `infrastructure/vault-secrets-operator/vso-release.yaml`. |
| Vault Database Secrets Engine | Same as Vault | Issues login roles on demand, 3h default TTL / 24h max; role dropped when the lease ends. Configured by the OpenTofu module in `terraform/vault-database/`. |
| Headlamp | `0.44.0` | Cluster GUI; installed as a flatpak on the host, not deployed to this cluster on this branch. See the *WSL2* branch for in-cluster deployment workarounds. |

### Foundational Cluster Services

Both ETL and ML workloads rely on a shared operational baseline, beyond what's already running above. Not yet in the repo directory; ordered alphabetically by component name.

| Component | Version | Description |
| --- | --- | --- |
| Falco | `0.44.1` (latest release; not yet deployed) | Real-time, eBPF-based detection of anomalous behavior at the syscall level. Detects unexpected shell spawns inside a container, unauthorized reads of sensitive files, privilege escalation attempts. Gives the cluster a runtime/process-level security signal to complement Cilium's network-layer visibility. *Alternative:* Tetragon is worth reconsidering later, since it's built by the same team as Cilium and shares its eBPF datapath rather than running a second, independent probe alongside it. Falco is the more battle-tested choice for now, with a larger existing rule/policy ecosystem. |
| kube-prometheus-stack | `88.1.5` (chart, latest; not yet deployed) | Deploys the industry-standard Prometheus, Grafana, and Alertmanager bundle for comprehensive metric aggregation and dashboarding, to debug resource spikes and workload bottlenecks. |
| Loki | `v3.7.5` (latest; not yet deployed) | Log aggregation and processing, paired with kube-prometheus-stack to round out metrics + logs observability. |

### ETL Pipeline Services

The ETL pipeline rollout focuses on data ingestion, declarative orchestration, and in-database transformation. Python classes, organized into libraries and published to allow impact, offer an open-source, lightweight way to punch well above weight here.

Not yet in the repo directory; ordered alphabetically by component name.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| dbt (dbt-core) | `1.12.0` | Executes complex SQL-based transformations natively within the CloudNativePG database, ensuring compute remains close to the data. | Apache Spark is the industry standard for massive-scale, distributed data transformation, but dbt is far lighter and more appropriate for pushing compute down into a local database rather than spinning up dedicated compute clusters. |
| dlt | `1.29.1` | Open-source Python library (data load tool) for building declarative data pipelines that load data from REST APIs, databases, and other sources. | Airbyte is a fallback option if a UI-driven ecosystem of pre-built connectors is eventually needed. |
| Prefect | `3.8.1` | Replaces heavy legacy schedulers with a Python-native, highly observable orchestration engine for triggering data pipelines. | Apache Airflow is the industry-standard alternative for data orchestration, but its heavy infrastructure footprint — requiring multiple dedicated scheduler, webserver, and worker pods — makes it overly complex for a lightweight local cluster. |

### Machine Learning Services

The ML expansion focuses on managing experiment tracking, environment provisioning, and model serving, utilizing strictly open-source (Apache 2.0) tooling. Not yet in the repo directory; ordered alphabetically by component name.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| BentoML | `v1.4.39` (latest; not yet installed) | Packages models into self-contained, production-ready services using a Python-first framework. | KServe is a potential alternative if Kubernetes-native inference features like scale-to-zero or advanced GPU scheduling are later required. |
| MLflow | `3.15.1` (latest; not yet installed) | Tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in the cluster's SeaweedFS object store. | Kubeflow is the standard for teams heavily invested in Kubernetes orchestration, and prepared to deal with its complexity. |

## Official Documentation

Same order as Core Database Architecture above, then the three sections below it in their alphabetical order.

| Component | Documentation Link |
| --- | --- |
| k3s | [https://docs.k3s.io/](https://docs.k3s.io/) |
| SeaweedFS | [https://github.com/seaweedfs/seaweedfs/wiki](https://github.com/seaweedfs/seaweedfs/wiki) |
| Flux | [https://fluxcd.io/flux/](https://fluxcd.io/flux/) |
| Barman Cloud Plugin | [https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/) |
| cert-manager | [https://cert-manager.io/docs/](https://cert-manager.io/docs/) |
| Cilium | [https://docs.cilium.io/](https://docs.cilium.io/) |
| CloudNativePG | [https://cloudnative-pg.io/docs](https://cloudnative-pg.io/docs) |
| CNPG Certificates | [https://cloudnative-pg.io/documentation/current/certificates/](https://cloudnative-pg.io/documentation/current/certificates/) |
| CNPG Hibernation | [https://cloudnative-pg.io/documentation/current/declarative_hibernation/](https://cloudnative-pg.io/documentation/current/declarative_hibernation/) |
| Gateway API | [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/) |
| Hubble | [https://docs.cilium.io/en/stable/observability/hubble/](https://docs.cilium.io/en/stable/observability/hubble/) |
| HashiCorp Vault | [https://developer.hashicorp.com/vault/docs](https://developer.hashicorp.com/vault/docs) |
| Vault Secrets Operator | [https://developer.hashicorp.com/vault/docs/vault-secrets-operator](https://developer.hashicorp.com/vault/docs/vault-secrets-operator) |
| Vault Database Secrets Engine | [https://developer.hashicorp.com/vault/docs/secrets/databases](https://developer.hashicorp.com/vault/docs/secrets/databases) |
| Headlamp | [https://headlamp.dev/docs/latest/](https://headlamp.dev/docs/latest/) |
| Falco | [https://falco.org/docs/](https://falco.org/docs/) |
| kube-prometheus-stack | [https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) |
| Loki | [https://grafana.com/docs/loki/latest/](https://grafana.com/docs/loki/latest/) |
| dbt | [https://docs.getdbt.com/](https://docs.getdbt.com/) |
| dlt | [https://dlthub.com/docs](https://dlthub.com/docs) |
| Prefect | [https://docs.prefect.io/](https://docs.prefect.io/) |
| BentoML | [https://docs.bentoml.com/](https://docs.bentoml.com/) |
| MLflow | [https://mlflow.org/docs/latest/index.html](https://mlflow.org/docs/latest/index.html) |

## Cluster Operations

| Operation | Command | When |
| --- | --- | --- |
| Start the cluster | `./src/bash/start-cluster.sh` | Each work session |
| Stop the cluster | `./src/bash/stop-cluster.sh` | Each work session |
| Sync API Context | `./src/bash/sync-kubeconfig.sh` | Only if a tool shows a stale kubeconfig directly |
| Trigger Manual DB Backup | `kubectl cnpg backup postgis-cluster -n databases -m plugin --plugin-name barman-cloud.cloudnative-pg.io` | Before a risky schema change, outside the nightly automated backup |
| Check Scheduled Backups Aren't Suspended | `kubectl get scheduledbackup -n databases -o yaml \| grep -i suspend` | Confirming nightly backups are actually running |
| Connect via psql | `kubectl cnpg psql postgis-cluster -n databases` | Ad hoc query access as the superuser |
| Verify Vault State | `kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault status"` | Troubleshooting only |
| Open a Vault Shell | `just vault-shell` | Interactive Vault work; `VAULT_ADDR` set and the inherited transit-unseal `VAULT_TOKEN` unset, ready for `vault login` or any other command |
| Log Into Vault | `just vault-login` | Same as `just vault-shell`, then runs `vault login`; drops into the shell already authenticated |
| Verify CNPG State | `kubectl cnpg status postgis-cluster -n databases` | Troubleshooting only |
| Check Flux Sync State | `flux get kustomizations -A` | Confirming the GitOps install graph is Ready end to end |
| Port-Forward Vault API | `kubectl port-forward -n vault vault-0 8200:8200` | Ad hoc token/policy management |
| View Hubble Flows (CLI) | `just hubble observe --follow` | Ad hoc network observability, independent of `hubble.internal` DNS |
| Open Hubble UI | `just hubble-ui` | Quick local access; starts its own port-forward and opens the browser |

* **Scheduled Backups:** the `ScheduledBackup` in `postgis-cluster.yaml` runs at midnight daily. It carries no `immediate` flag, so the first base backup after a rebuild is taken at the next midnight; until one exists, archived WAL has no base to be applied to. The `ObjectStore` prunes backups and their WAL older than 30 days. SeaweedFS is configured for up to 100 volumes of 1024MB. That store and the database share one physical disk and one `local-path` provisioner, which enforces no size limit on either claim, so neither the 100Gi figures nor the volume cap bound growth before the disk itself does. These backups cover operator error and corruption, not loss of the drive.
* **Lifecycle Management:** `start-cluster.sh` proceeds in order: refuse if `k3s.service` is active → launch k3s → API responding → node Ready → host Transit Vault unsealed → transit token renewed → in-cluster Vault unsealed → VSO secrets synced → CNPG operator Ready → un-hibernate → final health checks. Only the first four steps exit on failure; from the Transit Vault onward a failure records a warning and the script continues, exiting 1 at the end. The final checks cover the SeaweedFS pod and the CNPG cluster phase, and run after un-hibernation rather than gating it. cert-manager and the `barman-cloud` Deployment are not checked at all, so the run can report success while WAL archiving is not functional.
* `stop-cluster.sh` confirms the CNPG operator is Available, sets the hibernation annotation, and waits up to 300s for the operator to confirm or for the instance pods to disappear. k3s is not stopped until one of those holds, unless `--force` is passed. A systemd-owned k3s is stopped with `systemctl disable --now`; a script-launched one gets SIGTERM at the PID bound to 6443.

---

## **Restoring the Database from SeaweedFS**

Recovery with the Barman Cloud Plugin requires the user to roll out this workflow. It bootstraps a *new* cluster from the object store and replays WAL to a chosen point, leaving the original untouched. Define the backup as an external cluster and name it as the bootstrap source:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgis-restore
  namespace: databases
spec:
  instances: 1
  # imageName: match apps/databases/postgis-cluster.yaml
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

The restore cluster's `storage.size` must be at least the source cluster's, so confirm the space exists before starting:

```bash
df -h /var/lib/rancher/k3s/storage
kubectl apply -f /tmp/postgis-restore.yaml
kubectl get cluster postgis-restore -n databases -w
kubectl cnpg psql postgis-restore -n databases -- postgres -c '\dt'
kubectl delete cluster postgis-restore -n databases
```

Note that a restored cluster does not run `postInitSQL`. Roles and installed extensions come from the base backup.

Deleting the Cluster leaves its PersistentVolumeClaim behind; remove that too once the restoration is done:

```bash
kubectl delete pvc -n databases -l cnpg.io/cluster=postgis-restore
```

## Repository Structure

```text
├── .devcontainer/                       # VSCode Dev Container to manage the cluster
│   ├── devcontainer.json
│   └── Dockerfile
├── .github/
│   ├── ISSUE_TEMPLATE/                  # Bug/documentation/feature/tech-debt issue forms
│   │   ├── bug_report.yml
│   │   ├── config.yml
│   │   ├── documentation-update.yml
│   │   ├── feature-proposal.yml
│   │   └── technical-debt-resolution.yml
│   └── workflows/
│       └── ci.yml                       # pytest + coverage against src/clusterpgis, on pull requests
├── apps/
│   └── databases/                       # PostGIS cluster + dependencies, one Flux Kustomization
│       ├── kustomization.yaml
│       ├── postgis-cluster.yaml
│       ├── postgis-database.yaml
│       ├── postgis-tcproute.yaml
│       ├── postgres-tls.yaml
│       ├── seaweedfs-credentials.yaml
│       ├── seaweedfs-networkpolicy.yaml
│       ├── seaweedfs-release.yaml
│       └── vso-setup.yaml
├── clusters/
│   └── local/                           # Flux's own root (flux bootstrap --path=clusters/local)
│       ├── flux-system/                 # **DO NOT EDIT** Written by `flux bootstrap` 
│       │   ├── gotk-components.yaml
│       │   ├── gotk-sync.yaml
│       │   └── kustomization.yaml
│       ├── barman-cloud.yaml            # Kustomization → infrastructure/barman-cloud/
│       ├── cert-manager.yaml            # Kustomization → infrastructure/cert-manager/
│       ├── cilium.yaml                  # Kustomization → infrastructure/cilium/
│       ├── cnpg-operator.yaml           # Kustomization → infrastructure/cnpg-operator/
│       ├── databases.yaml               # Kustomization → apps/databases/
│       ├── dns.yaml                     # Kustomization → infrastructure/dns/
│       ├── gateway-api-crds.yaml        # Kustomization → infrastructure/gateway-api-crds/
│       ├── gateway.yaml                 # Kustomization → infrastructure/gateway/
│       ├── hubble.yaml                  # Kustomization → infrastructure/hubble/
│       ├── namespaces.yaml              # Kustomization → infrastructure/namespaces/
│       ├── vault-secrets-operator.yaml  # Kustomization → infrastructure/vault-secrets-operator/
│       └── vault.yaml                   # Kustomization → infrastructure/vault/
├── infrastructure/                      # Cluster-wide platform components.
│   ├── barman-cloud/
│   │   ├── barman-cloud-release.yaml
│   │   └── kustomization.yaml
│   ├── cert-manager/
│   │   ├── cert-manager-release.yaml
│   │   └── kustomization.yaml
│   ├── cilium/
│   │   ├── cilium-release.yaml
│   │   ├── cilium-values.yaml
│   │   ├── dns-l2-policy.yaml
│   │   ├── dns-lb-pool.yaml
│   │   ├── gateway-l2-policy.yaml
│   │   ├── gateway-lb-pool.yaml
│   │   └── kustomization.yaml
│   ├── cnpg-operator/
│   │   ├── cnpg-release.yaml
│   │   └── kustomization.yaml
│   ├── dns/
│   │   ├── dns-release.yaml
│   │   └── kustomization.yaml
│   ├── gateway/
│   │   ├── gateway-tls.yaml
│   │   ├── gateway.yaml
│   │   └── kustomization.yaml
│   ├── gateway-api-crds/
│   │   ├── kustomization.yaml
│   │   └── standard-install.yaml        # Vendored Gateway API CRDs
│   ├── hubble/
│   │   ├── cilium-values-hubble.yaml
│   │   ├── hubble-httproute.yaml
│   │   ├── hubble-tls.yaml
│   │   └── kustomization.yaml
│   ├── namespaces/
│   │   ├── kustomization.yaml
│   │   └── namespaces.yaml
│   ├── vault/
│   │   ├── kustomization.yaml
│   │   ├── vault-release.yaml
│   │   └── vault-values.yaml
│   └── vault-secrets-operator/
│       ├── kustomization.yaml
│       └── vso-release.yaml
├── notebooks/
│   ├── data_analysis_notebook.ipynb     # Exploratory analysis and findings
│   └── data_processing_notebook.ipynb   # Data cleaning and integrity checks
├── src/
│   ├── bash/
│   │   ├── start-cluster.sh             # Boot sequence: API, Transit Vault unseal, readiness checks
│   │   ├── stop-cluster.sh              # Graceful shutdown via CNPG declarative hibernation
│   │   └── sync-kubeconfig.sh           # Copies the live k3s kubeconfig into ~/.kube/config
│   └── clusterpgis/                     # The installable clusterpgis package (src layout)
│       ├── data/
│       │   └── __init__.py
│       ├── features/
│       │   └── __init__.py
│       ├── models/
│       │   └── __init__.py
│       ├── visualization/
│       │   └── __init__.py
│       └── __init__.py
├── terraform/                           # OpenTofu modules configuring Vault's internals
│   ├── vault-bootstrap/                 # KV mounts, Kubernetes auth backend, postgis-policy/-role
│   │   ├── .gitignore
│   │   ├── encryption.tf
│   │   ├── kubernetes-auth.tf
│   │   ├── kv.tf
│   │   ├── provider.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   └── vault-database/                  # Database secrets engine + postgis-app-role
│       ├── .gitignore
│       ├── database.tf
│       ├── encryption.tf
│       ├── provider.tf
│       ├── variables.tf
│       └── versions.tf
├── tests/
│   ├── __init__.py
│   ├── conftest.py
│   └── test_example.py
├── .copier-answers.yml                  # Records copier template + answers, for future `copier update`
├── .gitattributes
├── .gitignore
├── .python-version
├── INSTALLATION.md                      # First-time cluster bootstrap, run sequentially
├── justfile                             # `just setup` (uv sync + nbwipers filter), `just test-cov`, `just hubble`/`hubble-ui` (Hubble CLI/UI access), `just vault-shell`/`vault-login` (Vault pod shell access)
├── pyproject.toml                       # uv-managed clusterpgis package + dev tooling
├── README.md                            # Architecture, setup, and operations reference
├── ROADMAP.md                           # Planned future services and technical debt remediation
├── troubleshooting.md                   # Symptom → cause → fix, by subsystem
└── uv.lock
```

### **File Descriptions**

* `.devcontainer/` - Provision a VSCode Dev Container for your needs.
  * `devcontainer.json`: Configuration file for a devcontainer designed to be platform and engine agnostic.
  * `Dockerfile` contains build instructions to provision a Data Science focused Dev Container.
* `.github/`
  * `ISSUE_TEMPLATE/`: Issue templates for bug reports, documentation updates, feature proposals, and technical-debt resolution.
  * `workflows/ci.yml`: Runs `pytest` with coverage against `src/clusterpgis` on pull requests, via `astral-sh/setup-uv`.
* `apps/databases/` the PostGIS cluster and everything it depends on, reconciled as one Flux `Kustomization` (`clusters/local/databases.yaml`).
  * `kustomization.yaml`: every resource this Kustomization builds, in one pass.
  * `vso-setup.yaml`: Creates the `databases` namespace and the `VaultConnection`/`VaultAuth`/`ServiceAccount` VSO uses to authenticate to Vault.
  * `postgres-tls.yaml`: cert-manager `Issuer`s and `Certificate` producing the Postgres server certificate. SANs cover `localhost`/`127.0.0.1` (the socat proxy), the shared Gateway's static LAN IP, and `postgres.internal` (resolves to that same IP via `infrastructure/dns/`).
  * `postgis-cluster.yaml`: The CNPG `Cluster`, its static and dynamic Vault secrets, the `ObjectStore` and `ScheduledBackup` used for backups, and the `postgres-proxy` Deployment.
  * `postgis-tcproute.yaml`: `TCPRoute` attaching the CNPG primary to the shared Gateway's raw-TCP listener (`infrastructure/gateway/`). The listener maps 1:1 to this one backend. Replaces this repo's earlier dedicated `postgis-cluster-external` `LoadBalancer` Service.
  * `postgis-database.yaml`: CNPG `Database` CRD declares `data_science`, its owner, schemas, and PostGIS extensions (reconciles on every generation change, unlike `postInitSQL`, which runs once at initdb).
  * `seaweedfs-release.yaml`: `HelmRepository`/`HelmRelease` for SeaweedFS, master/filer data on the external HDD via `hostPath`, S3 gateway on port 9000 with the `cnpg-backups` bucket created at install.
  * `seaweedfs-credentials.yaml`: `VaultStaticSecret` syncing S3 credentials from `secret/seaweedfs`.
  * `seaweedfs-networkpolicy.yaml`: Restricts SeaweedFS ingress to the `databases` namespace.
* `clusters/local/` Flux's own root, pointed at by `flux bootstrap --path=clusters/local`. One Kustomization per directory under `infrastructure/`/`apps/` below, `dependsOn`-chained into the install order the cluster actually needs: `gateway-api-crds` + `namespaces` → `cilium` → `cert-manager` + `dns` → `gateway` → `hubble`; separately, `vault` → `vault-secrets-operator` → `cnpg-operator` → `barman-cloud` (which also needs `cert-manager`) → `databases` (which also needs `gateway`, for its `TCPRoute` to attach to).
  * `flux-system/` (`gotk-components.yaml`, `gotk-sync.yaml`, `kustomization.yaml`): Flux's own controllers and `GitRepository` source, written by `flux bootstrap`, don't edit directly.
  * `gateway-api-crds.yaml`, `namespaces.yaml`, `cilium.yaml`, `cert-manager.yaml`, `dns.yaml`, `gateway.yaml`, `hubble.yaml`, `vault.yaml`, `vault-secrets-operator.yaml`, `cnpg-operator.yaml`, `barman-cloud.yaml`, `databases.yaml`: one Flux `Kustomization` per matching directory below, each declaring its own `dependsOn`/`healthChecks`.
* `infrastructure/` cluster-wide platform components, listed alphabetically below (Flux's actual install order is `gateway-api-crds` + `namespaces` → `cilium` → `cert-manager` + `dns` → `gateway` → `hubble`; separately, `vault` → `vault-secrets-operator` → `cnpg-operator` → `barman-cloud`, per `clusters/local/` above).
  * `barman-cloud/`
    * `barman-cloud-release.yaml`: `HelmRelease` for the Barman Cloud Plugin, reuses the `cnpg-operator/` directory's own `HelmRepository` rather than declaring a second one for the same chart index.
    * `kustomization.yaml`
  * `cert-manager/`
    * `cert-manager-release.yaml`: `HelmRepository`/`HelmRelease` for cert-manager; CRDs are managed by the chart itself (`crds.enabled: true`), not vendored separately.
    * `kustomization.yaml`
  * `cilium/`
    * `cilium-release.yaml`: `HelmRepository` (OCI, `quay.io/cilium/charts`) and `HelmRelease` for Cilium, with `releaseName`/namespace matching the bootstrap install so Flux adopts the existing release instead of installing a second one. `valuesFrom` has two entries: `cilium-values` (required) and `cilium-values-hubble` (`optional: true`). `optional: true` lets the HelmRelease install cleanly without it; `helm-controller` watches the ConfigMap and re-reconciles the moment it appears, merging Hubble's values in automatically.
    * `cilium-values.yaml`: Helm values for kube-proxy replacement, the k3s API server override, single-replica operator, pod CIDR, Gateway API support, and L2 announcements for the shared Gateway and DNS resolver `LoadBalancer`s below.
    * `gateway-lb-pool.yaml` / `gateway-l2-policy.yaml`: `CiliumLoadBalancerIPPool` / `CiliumL2AnnouncementPolicy` handing a single static LAN IP to the shared Gateway's generated Service (`gateway.networking.k8s.io/gateway-name: internal-gateway`, the label Cilium's Gateway controller stamps on it, confirmed live). Replaces this repo's earlier `postgis-lb-pool`/`postgis-l2-policy`, which gave Postgres its own dedicated `LoadBalancer` before it moved onto this shared Gateway via a `TCPRoute`.
    * `dns-lb-pool.yaml` / `dns-l2-policy.yaml`: Same pattern, a second static LAN IP for the CoreDNS resolver's Service (`dns/` below).
    * `kustomization.yaml`: Bundles the release and all four LB/L2 objects, plus a `configMapGenerator` turning `cilium-values.yaml` into the `ConfigMap` the `HelmRelease`'s `valuesFrom` reads.
  * `cnpg-operator/`
    * `cnpg-release.yaml`: `HelmRepository`/`HelmRelease` for the CloudNativePG operator.
    * `kustomization.yaml`
  * `dns/`
    * `dns-release.yaml`: `HelmRepository`/`HelmRelease` for CoreDNS (official chart), a standalone LAN-facing resolver, separate from k3s's own in-cluster CoreDNS. Answers any `*.internal` query with the shared Gateway's IP (a `template` plugin rule, not a per-hostname record a new tool never needs a DNS edit, only a new `HTTPRoute`/`TCPRoute`) and forwards everything else to the LAN router, so a device can use it as its only DNS server.
    * `kustomization.yaml`
  * `gateway/`
    * `gateway-tls.yaml`: A dedicated self-signed local CA and `ClusterIssuer` chain (`gateway-ca-issuer`) issuing a wildcard `*.internal` certificate for the Gateway's own edge TLS. This is the cert a browser or `psql` client actually sees, distinct from Hubble's internal mTLS chain below.
    * `gateway.yaml`: The one shared `Gateway` (`internal-gateway`) every HTTP(S) tool and Postgres itself attaches a `Route` to instead of minting its own `LoadBalancer` an HTTPS listener (443, TLS from `gateway-tls.yaml`) for web UIs, and a raw TCP listener (5432) for Postgres via `TCPRoute`. `allowedRoutes.namespaces.from: All` on both lets any namespace attach a `Route` without a `ReferenceGrant`.
    * `kustomization.yaml`
  * `gateway-api-crds/`
    * `standard-install.yaml`: Vendored Gateway API CRDs (upstream release manifest, pinned rather than floated). Cilium's Gateway API support depends on these existing first.
    * `kustomization.yaml`
  * `hubble/`
    * `hubble-tls.yaml`: A second, separate self-signed local CA and `ClusterIssuer` chain (`hubble-ca-issuer`) Hubble's internal mTLS trust domain (cilium-agent ↔ hubble-relay ↔ hubble-ui), kept apart from anything a browser trusts.
    * `hubble-httproute.yaml`: Attaches Hubble UI to the shared Gateway at `hubble.internal`.
    * `cilium-values-hubble.yaml`: Cilium chart values enabling Hubble Relay/UI with cert-manager-issued mTLS, referencing `hubble-ca-issuer` above. Generated as the `cilium-values-hubble` ConfigMap by this `kustomization.yaml`, which `cilium-release.yaml` reads as an optional `valuesFrom` source. This directory's own `dependsOn` (`cert-manager`, `gateway`) is what makes the ConfigMap not exist until the issuer it references is real.
    * `kustomization.yaml`
  * `namespaces/`
    * `namespaces.yaml`: Creates every namespace Flux needs a home for up front (`vault`, `vault-secrets-operator-system`, `cnpg-system`, `databases`, `cert-manager`, `gateway`, `dns`). A `HelmRelease` doesn't auto-create its own namespace the way `helm install --create-namespace` does.
    * `kustomization.yaml`
  * `vault/`
    * `vault-release.yaml`: `HelmRepository`/`HelmRelease` for the in-cluster Vault.
    * `vault-values.yaml`: Helm values for transit auto-unseal against the host-level Vault, the Agent Injector disabled (VSO syncs secrets instead of sidecar injection), TLS disabled on the client listener (access is restricted by cluster networking instead).
    * `kustomization.yaml`: Same release-plus-values-ConfigMap pattern as Cilium's.
  * `vault-secrets-operator/`
    * `vso-release.yaml`: `HelmRepository`/`HelmRelease` for the Vault Secrets Operator.
    * `kustomization.yaml`
* `terraform/` OpenTofu modules configuring Vault's internals (KV secrets, the Kubernetes auth backend, the database secrets engine). State is local, gitignored, and encrypted at rest via OpenTofu's own `encryption` block; these modules are applied by hand from the host, not reconciled by Flux.
  * `vault-bootstrap/`: KV mounts and secrets (`secret/postgis`, `secret/seaweedfs`), the Kubernetes auth backend, and the `postgis-policy`/`postgis-role` Vault uses to authorize the cluster's ServiceAccount.
  * `vault-database/`: The database secrets engine connection to `postgis-cluster` and the `postgis-app-role` issuing leased application credentials.
