# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a PostgreSQL server with the PostGIS extension enabled. It provides a scalable foundation for data science projects, such as Extract, Transform, and Load (ETL) pipelines and Machine Learning (ML).

This cluster uses `FluxCD`, Helm, and `Kustomization` to structure the rollout of the cluster:

* Flux provides the GitOps controller that monitors the cluster for any state drift, using git as the source of truth and running periodic reconciliation checks.
* Helm offers a trusted repository of resources for Kubernetes that allow Secrets and ConfigMaps to pass specific values to public, professionally maintained Kubernetes manifests, allowing for complex, custom resources to be easily deployed, moved between different production environments, and still allow most of their maintenance to be handled by the developers.
* `Kustomization` Breaks the complex resources of Kubernetes down into manageable pieces, organizing them according to a consistent, hierarchical structure whose `dependsOn` option `FluxCD` automatically follows in its reconciliations.

This cluster's architecture relies on a system-installed HashiCorp Vault acting as a transit to unseal a cluster-situated Vault. This cluster Vault is the primary store for all secrets in the cluster. Secure provisioning of environment variables from this vault allows users to combine ease of use and best practices for Secrets Management, intended for local use but scalable for enterprises if necessary. OpenTofu is used to declaratively structure and implement secrets in the cluster.

The resources that make up the cluster are modularized to allow for easy pivoting between tasks and managing compute efficiently. The Core Database Architecture has been implemented, and the cluster monitoring services only become necessary to roll out when completing either ETL pipelines, or ML workflows. In theory, one can add the necessary modules to complete a Data Science task, then strip down to the Core Architecture afterwards.

*Note* A DevContainer template for managing the cluster through VSCode is provided, as a bare-bones skeleton for you customize as you wish.

**Developed and tested on Ubuntu.**

## Table of Contents

* [Core Database Architecture](#core-database-architecture)
* [Cluster Monitoring Module](#cluster-monitoring-module)
* [ETL Pipeline Module](#etl-pipeline-module)
* [Machine Learning Module](#machine-learning-module)
* [Official Documentation](#official-documentation)
* [Cluster Operations](#cluster-operations)
* [Restoring the Database from SeaweedFS](#restoring-the-database-from-seaweedfs)
* [Repository Structure](#repository-structure)
* [File Descriptions](#file-descriptions)

## Core Database Architecture

These are the resources that make up the database core of the cluster. It is engineered to scale into demanding and complex workloads, and relies on open source software that is efficient, organized, and lightweight. The version numbers here serve as a reference for those in the manifests intended to be deployed live.

| Component | Version | Description |
| --- | --- | --- |
| k3s | `v1.36.2+k3s1` | Core control plane and execution environment. Host-installed, unpinned by this repo. |
| PostgreSQL / PostGIS image | `18.3-3.6.2-system-trixie` | Image the CNPG `Cluster` runs. |
| SeaweedFS | `4.40` | In-cluster S3-compatible object store with TLS issued by `vault-pki-issuer`. CNPG streams WAL and writes scheduled base backups to it over HTTPS (`https://seaweedfs-s3.databases.svc:9000`). |
| Flux | `v2.9.3` | GitOps controller; reconciles every `Kustomization` under `clusters/local/`, `dependsOn`-chained starting Gateway API CRDs → Cilium. CLI-installed, unpinned by this repo. |
| Barman Cloud Plugin | `v0.14.0` | WAL archiving and base backups for CNPG, via the `ObjectStore` resource rather than in-tree `spec.backup.barmanObjectStore`. |
| cert-manager | `v1.21.1` | Manages local edge CA, provisions Vault TLS, and mints leaf certificates via `vault-pki-issuer`. |
| Cilium | `1.20.0` | CNI; replaces k3s's default networking, eBPF routing/load-balancing in place of kube-proxy, serves the Gateway API. |
| CloudNativePG (CNPG) | `1.30.0` | Operator managing the PostgreSQL/PostGIS lifecycle: provisioning, reconciliation, hibernation, backup orchestration. |
| DNS (CoreDNS) | `v1.14.6` | k3s's own in-cluster CoreDNS (`kube-system`), extended with an `internal` zone via a `coredns-custom` ConfigMap (`infrastructure/coredns-custom/`). Resolves `*.internal` to the shared Gateway's IP for LAN clients, alongside its existing `*.svc.cluster.local` role for pods. |
| Gateway | `v1.6.1` (CRDs) | One shared `Gateway` (`internal-gateway`) every tool attaches a `Route` to: an HTTPS listener (443, wildcard cert) for web UIs, a raw TCP listener (5432) for Postgres. |
| Gateway API | `v1.6.1` (CRDs) | Kubernetes-native API for describing traffic routing. `GatewayClass` names an implementation (e.g. Cilium); `Gateway` defines listeners (ports, protocols, hostnames); `HTTPRoute`/`TCPRoute`/`TLSRoute`/`GRPCRoute`/`UDPRoute` attach to a Gateway and route traffic by protocol to backend Services; `ReferenceGrant` allows routes to reference backends in another namespace; `BackendTLSPolicy` configures TLS to a backend; `ListenerSet` lets a listener be shared/delegated across teams. |
| Hubble | `v1.20.0` (Relay), `v0.13.5` (UI) | Cilium's network observability layer. Relay/UI run their own cert-manager mTLS trust domain; UI exposed at `hubble.internal` on the shared Gateway. |
| HashiCorp Vault (in-cluster) | `2.0.3` | Main Vault; auto-unseals against the host's native Transit Vault at pod start. Hosts KV secrets, Kubernetes Auth, 2-tier PKI engine (Root + Intermediate CA with RFC 5280 Name Constraints), and database secrets engine. |
| Vault Secrets Operator (VSO) | `1.5.0` | Reads Main Vault values into Kubernetes `Secret`s; refreshes static secrets, renews dynamic leases. |
| Vault Database & PKI Engines | Same as Vault | Issues Postgres login roles on demand (3h default TTL / 24h max) and issues 30-day TLS certificates via cert-manager. |
| Headlamp | `0.44.0` | Cluster GUI; can be installed as a desktop app, or deployed within the cluster. Has a number of plugins that assist with cluster management. |

### Cluster Monitoring Module

These are the set of operators that need to be deployed in addition to the core to scale into ETL or ML workloads.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| kube-prometheus-stack | `88.1.5` (chart, latest; not yet deployed) | Deploys the industry-standard Prometheus, Grafana, and Alertmanager bundle for comprehensive metric aggregation and dashboarding, to debug resource spikes and workload bottlenecks. | `victoria-metrics-k8s-stack` uses VictoriaMetrics instead of Prometheus. Lower footprint, but more work to customize. |
| Loki | `v3.7.5` (latest; not yet deployed) | Log aggregation and processing, paired with kube-prometheus-stack to round out metrics + logs observability. | `VictoriaLogs` particularly if using the same stack as above. |
| Tetragon | `v1.7.0` (latest release; not yet deployed) | Real-time, eBPF-based detection of anomalous behavior at the syscall level. Detects unexpected shell spawns inside a container, unauthorized reads of sensitive files, privilege escalation attempts. Shares the eBPF datapath Cilium uses, and comes from the same developer. | Falco is the more battle-tested choice, with a larger existing rule/policy ecosystem, if Tetragon's policy library proves too thin in practice. |
| Tekton Pipelines | `v1.13.0` (latest; not yet deployed) | Cluster-native CI engine with Pipelines/Tasks/PipelineRuns from CRDs. | Woodpecker CI, if a single self-hosted binary with GitHub-Actions-like YAML is preferred over Tekton's CRD model. |
| Tekton Triggers | `v0.33.0` (latest; not yet deployed) | EventListener reacting to GitHub webhook events (push/PR), starting the matching PipelineRun. | GitHubs Actions is the standard for ci workflow, and can offer basic complimentary CI services on github. |

### ETL Pipeline Module

The ETL pipeline rollout focuses on data ingestion, declarative orchestration, and in-database transformation. Python's modules allow for each step in ETL to be accomplished within Python:

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| dbt (dbt-core, dbt-postgres) | `1.12.0` | Executes complex SQL-based transformations natively within the CloudNativePG database, ensuring compute remains close to the data. | Apache Spark is the industry standard for massive-scale, distributed data transformation, but heavier and more appropriate for spinning up dedicated compute clusters rather than pushing compute down in a bare-metal development environment. and more appropriate for pushing compute down into a local database rather than spinning up dedicated compute clusters. |
| dlt | `1.29.1` | Open-source Python library (data load tool) for building declarative data pipelines that load data from REST APIs, databases, and other sources. | Airbyte is a fallback option if a UI-driven ecosystem of pre-built connectors is eventually needed. |
| Prefect | `3.8.1` | Replaces heavy legacy schedulers with a Python-native, highly observable orchestration engine for triggering data pipelines. | Apache Airflow is the industry-standard alternative for data orchestration, but its heavy infrastructure footprint (requiring multiple dedicated scheduler, webserver, and worker pods) makes it overly complex for a lightweight local cluster. |

### Machine Learning Module

The ML expansion focuses on managing experiment tracking, environment provisioning, and model serving, utilizing strictly open-source (Apache 2.0) tooling. Not yet in the repo directory; ordered alphabetically by component name.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| BentoML | `v1.4.39` (latest; not yet installed) | Packages models into self-contained, production-ready services using a Python-first framework. | KServe offers Kubernetes-native inference features like scale-to-zero or advanced GPU scheduling. |
| MLflow | `3.15.1` (latest; not yet installed) | Tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in the cluster's SeaweedFS object store. | Kubeflow is the standard for teams prepared for, and heavily invested in, Kubernetes orchestration. |

## Official Documentation

### Host Side Tooling Documentation

| Component | Documentation Link |
| --- | --- |
| OpenTofu | [https://opentofu.org/docs/](https://opentofu.org/docs/) |

### Core Architecture Documentation

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
| Vault PKI Secrets Engine | [https://developer.hashicorp.com/vault/docs/secrets/pki](https://developer.hashicorp.com/vault/docs/secrets/pki) |
| Vault Secrets Operator | [https://developer.hashicorp.com/vault/docs/vault-secrets-operator](https://developer.hashicorp.com/vault/docs/vault-secrets-operator) |
| Vault Database Secrets Engine | [https://developer.hashicorp.com/vault/docs/secrets/databases](https://developer.hashicorp.com/vault/docs/secrets/databases) |
| Headlamp | [https://headlamp.dev/docs/latest/](https://headlamp.dev/docs/latest/) |

### Cluster Monitoring Services Documentation

| Component | Documentation Link |
| --- | --- |
| kube-prometheus-stack | [https://github.com/prometheus-operator/kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) |
| Loki | [https://grafana.com/docs/loki/latest/](https://grafana.com/docs/loki/latest/) |
| Tetragon | [https://tetragon.io/](https://tetragon.io/) |

### ETL and ML Services Documentation

| Component | Documentation Link |
| --- | --- |
| Tekton Pipelines | [https://tekton.dev/docs/pipelines/](https://tekton.dev/docs/pipelines/) |
| Tekton Triggers | [https://tekton.dev/docs/triggers/](https://tekton.dev/docs/triggers/) |
| dbt | [https://docs.getdbt.com/](https://docs.getdbt.com/) |
| dlt | [https://dlthub.com/docs](https://dlthub.com/docs) |
| Prefect | [https://docs.prefect.io/](https://docs.prefect.io/) |
| BentoML | [https://docs.bentoml.com/](https://docs.bentoml.com/) |
| MLflow | [https://mlflow.org/docs/latest/index.html](https://mlflow.org/docs/latest/index.html) |

## Cluster Operations

Organized to match the justfile's own section layout (`just --list` shows every recipe).

### Bootstrap

One-time, first-install setup — see `INSTALLATION.md` for Requirements and what the script does.

| Command | Operation |
| --- | --- |
| `just bootstrap` | Run the full first-time cluster bootstrap |

### Cluster Lifecycle

| Command | Operation | When |
| --- | --- | --- |
| `just start` | Start the cluster | Each work session |
| `just stop` (`just stop --force` if a stuck stop needs it) | Stop the cluster | Each work session |
| `just fuzzypods` | Interactively inspect a pod | Ad hoc troubleshooting; fuzzy-select a pod from all namespaces and describe it |
| `just status` | Check overall cluster health | Post-install verification, or a periodic sanity check across Flux, Gateway/DNS, cert-manager, database, backups, SeaweedFS, and Hubble |
| `flux get kustomizations -A` | Check Flux sync state | Confirming the GitOps install graph is Ready end to end |

### Database

| Command | Operation | When |
| --- | --- | --- |
| `just db-connect` (`just db-connect localhost` from the node itself) | Connect via psql (app role, host) | Application-level access with Vault-issued credentials |
| `kubectl cnpg psql postgis-cluster -n databases` | Connect via psql (superuser, in-cluster) | Ad hoc query access as the superuser |
| `kubectl cnpg backup postgis-cluster -n databases -m plugin --plugin-name barman-cloud.cloudnative-pg.io` | Trigger a manual DB backup | Before a risky schema change, outside the nightly automated backup |
| `kubectl get scheduledbackup -n databases -o yaml \| grep -i suspend` | Check scheduled backups aren't suspended | Confirming nightly backups are actually running |
| `kubectl cnpg status postgis-cluster -n databases` | Verify CNPG state | Troubleshooting only |

### Observability (Hubble)

| Command | Operation | When |
| --- | --- | --- |
| `just hubble-ui` | Open Hubble UI | Quick local access; starts its own port-forward and opens the browser |
| `just hubble observe --follow` (or any other `hubble` subcommand) | View Hubble flows (CLI) | Ad hoc network observability, independent of the web UI |
| `just hubble-pf` | Port-forward Hubble Relay only | Lower-level primitive `just hubble` uses internally; no TLS cert setup |

### Vault

| Command | Operation | When |
| --- | --- | --- |
| `just vault-shell` | Open a Vault shell | Interactive Vault work inside the `vault-0` pod, where addressing already works; inherited `VAULT_TOKEN` is unset first, run `vault login` once inside to authenticate |
| `just vault-pf` | Port-forward in-cluster Vault to the host | Internal plumbing `just bootstrap` uses; prefer `just vault-shell` for ad hoc CLI work instead of using this directly |
| `kubectl exec -n vault vault-0 -- vault status` | Verify Vault state | Troubleshooting only |

### Development

| Command | Operation |
| --- | --- |
| `just install` | Install dependencies |
| `just setup` | Set up the dev environment (install + git filters) |
| `just test-cov` | Run tests with coverage |
| `just update` | Update packages and the lockfile |
| `just git-setup` | Configure the `nbwipers` git filter |

---

## **Restoring the Database from SeaweedFS**

Recovery with the Barman Cloud Plugin requires the user to roll out this `.yaml` manifest. It bootstraps a *new* cluster from the object store and replays WAL to a chosen point, leaving the original untouched. Define the backup as an external cluster and name it as the bootstrap source:

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

The restore cluster's `storage.size` must be at least the source cluster's. Confirm the space exists before starting:

```bash
df -h /var/lib/rancher/k3s/storage
kubectl apply -f /tmp/postgis-restore.yaml
kubectl get cluster postgis-restore -n databases -w
kubectl cnpg psql postgis-restore -n databases -- postgres -c '\dt'
kubectl delete cluster postgis-restore -n databases
```

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
│       └── ci.yml                       # ruff lint/format + pytest + coverage
├── apps/
│   └── databases/                       # PostGIS cluster + dependencies, one Flux Kustomization
│       ├── kustomization.yaml
│       ├── postgis-cluster.yaml
│       ├── postgis-database.yaml
│       ├── postgis-localhost.yaml
│       ├── postgis-networkpolicy.yaml
│       ├── postgis-tcproute.yaml
│       ├── postgis-tls.yaml
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
│       ├── coredns-custom.yaml          # Kustomization → infrastructure/coredns-custom/
│       ├── databases.yaml               # Kustomization → apps/databases/
│       ├── flux-system-policies.yaml    # Kustomization → infrastructure/flux-system-policies/
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
│   │   ├── cert-manager-networkpolicy.yaml
│   │   ├── cert-manager-release.yaml
│   │   └── kustomization.yaml
│   ├── cilium/
│   │   ├── cilium-release.yaml
│   │   ├── cilium-values.yaml
│   │   ├── clusterwide-networkpolicy.yaml
│   │   ├── kustomizeconfig.yaml
│   │   ├── lan-l2-policy.yaml
│   │   ├── lan-lb-pool.yaml
│   │   └── kustomization.yaml
│   ├── cnpg-operator/
│   │   ├── cnpg-networkpolicy.yaml
│   │   ├── cnpg-release.yaml
│   │   └── kustomization.yaml
│   ├── coredns-custom/                  # internal zone on k3s's own CoreDNS
│   │   ├── coredns-custom.yaml
│   │   ├── coredns-lan-service.yaml
│   │   └── kustomization.yaml
│   ├── flux-system-policies/
│   │   ├── flux-networkpolicy.yaml
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
│   │   └── kustomization.yaml
│   ├── namespaces/
│   │   ├── kustomization.yaml
│   │   └── namespaces.yaml
│   ├── vault/
│   │   ├── kustomization.yaml
│   │   ├── kustomizeconfig.yaml
│   │   ├── vault-networkpolicy.yaml
│   │   ├── vault-release.yaml
│   │   ├── vault-tls.yaml
│   │   └── vault-values.yaml
│   └── vault-secrets-operator/
│       ├── kustomization.yaml
│       ├── vso-networkpolicy.yaml
│       └── vso-release.yaml
├── notebooks/
│   ├── data_analysis_notebook.ipynb     # Exploratory analysis and findings
│   └── data_processing_notebook.ipynb   # Data cleaning and integrity checks
├── src/
│   ├── bash/
│   │   ├── start-cluster.sh             # Boot sequence: API, Transit Vault unseal, readiness checks
│   │   └── stop-cluster.sh              # Graceful shutdown via CNPG declarative hibernation
│   ├── k3s/
│   │   └── config.yaml                  # k3s server config, installed via `just bootstrap`
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
├── terraform/                           # OpenTofu modules configuring cluster-config and Vault's internals
│   ├── cluster-config/                  # cluster-config Secret: GATEWAY_IP, COREDNS_LAN_IP, HOST_IP, CILIUM_VERSION
│   │   ├── kubernetes-secret.tf
│   │   ├── provider.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   ├── vault/                           # Unified in-cluster Vault: KV mounts, Kubernetes auth, 2-tier PKI engine, DB secrets
│   │   ├── .gitignore
│   │   ├── database.tf
│   │   ├── encryption.tf
│   │   ├── kubernetes-auth.tf
│   │   ├── kv.tf
│   │   ├── pki.tf
│   │   ├── provider.tf
│   │   ├── variables.tf
│   │   └── versions.tf
│   └── vault-transit-bootstrap/         # Host Transit Vault: autounseal policy/token, vault-transit-secret/-ca
│       ├── .gitignore
│       ├── agent-token-file.tf
│       ├── encryption.tf
│       ├── kubernetes-secrets.tf
│       ├── policy.tf
│       ├── provider.tf
│       ├── token.tf
│       └── versions.tf
├── tests/
│   ├── __init__.py
│   ├── conftest.py
│   └── test_example.py
├── .copier-answers.yml                  # Records copier template + answers, for future `copier update`
├── .gitattributes
├── .gitignore
├── .python-version
├── INSTALLATION.md                      # First-time cluster bootstrap: Requirements, then `just bootstrap`
├── justfile                             # `just setup` (review for more commands)
├── pyproject.toml                       # uv-managed clusterpgis package + dev tooling
├── README.md                            # Architecture, setup, and operations reference
├── troubleshooting.md                   # Symptom → cause → fix, by subsystem
└── uv.lock
```

### **File Descriptions**

* **`.devcontainer/`** - Provision a VSCode Dev Container
  * **`devcontainer.json`**: Configuration file for a devcontainer designed to be platform and engine agnostic.
  * **`Dockerfile`** contains build instructions to provision a Data Science focused Dev Container.
* **`.github/`**
  * **`ISSUE_TEMPLATE/`** - Issue templates for bug reports, documentation updates, feature proposals, and technical-debt resolution.
  * **`workflows/ci.yml`** - On pull requests, via `astral-sh/setup-uv`: a `lint` job runs `ruff check`/`ruff format --check`, and a `tests` job runs `pytest` with coverage against `src/clusterpgis`.
* **`apps/databases/`** the PostGIS cluster and everything it depends on, reconciled as one Flux `Kustomization` (`clusters/local/databases.yaml`).
  * **`kustomization.yaml`** - every resource this Kustomization builds, in one pass.
  * **`vso-setup.yaml`** - Creates the `VaultConnection`/`VaultAuth`/`ServiceAccount` VSO uses to authenticate to Vault.
  * **`postgis-tls.yaml`** - cert-manager `Certificate` requesting the Postgres server certificate from `vault-pki-issuer`. SANs cover `localhost`/`127.0.0.1`, `postgis.internal`, and the shared Gateway's static LAN IP.
  * **`postgis-cluster.yaml`** - The CNPG `Cluster`, its static and dynamic Vault secrets, the `ObjectStore` (configured with `https://seaweedfs-s3.databases.svc:9000`) and `ScheduledBackup` used for backups.
  * **`postgis-tcproute.yaml`** - `TCPRoute` attaching the CNPG primary to the shared Gateway's raw-TCP listener (`infrastructure/gateway/`).
  * **`postgis-localhost.yaml`** - `CiliumLocalRedirectPolicy` redirecting `127.0.0.1:5432` on the node to the CNPG primary pod via eBPF, selected by CNPG's `instanceRole` label.
  * **`postgis-database.yaml`** - CNPG `Database` CRD declares `data_science`, its owner, schemas, and PostGIS extensions.
  * **`postgis-networkpolicy.yaml`** - Restricts PostGIS database ingress (CNPG operator, Vault) and egress (kube-dns, SeaweedFS S3).
  * **`seaweedfs-release.yaml`** - `HelmRepository`/`HelmRelease` for SeaweedFS, master/filer data on the external HDD via `hostPath`, S3 gateway on port 9000 with TLS issued by `vault-pki-issuer`, and `cnpg-backups` bucket created at install.
  * **`seaweedfs-credentials.yaml`** - `VaultStaticSecret` syncing S3 credentials from `secret/seaweedfs`.
  * **`seaweedfs-networkpolicy.yaml`** - Restricts SeaweedFS ingress and egress to the `databases` namespace and `kube-dns`.
* **`clusters/local/`** - Flux's own root, pointed at by `flux bootstrap --path=clusters/local`. One Kustomization per directory under `infrastructure/`/`apps/` below.
  * **`flux-system/`** - (`gotk-components.yaml`, `gotk-sync.yaml`, `kustomization.yaml`): Flux's own controllers and `GitRepository` source, written by `flux bootstrap`, don't edit directly.
  * **`gateway-api-crds.yaml`, `namespaces.yaml`, `cilium.yaml`, `cert-manager.yaml`, `gateway.yaml`, `hubble.yaml`, `coredns-custom.yaml`, `vault.yaml`, `vault-secrets-operator.yaml`, `cnpg-operator.yaml`, `barman-cloud.yaml`, `databases.yaml`, `flux-system-policies.yaml`** - one Flux `Kustomization` per matching directory below, each declaring its own `dependsOn`/`healthChecks`.
* **`infrastructure/`** cluster-wide platform components, listed alphabetically below:
  * **`barman-cloud/`**
    * **`barman-cloud-release.yaml`** - `HelmRelease` for the Barman Cloud Plugin
    * **`kustomization.yaml`**
  * **`cert-manager/`**
    * **`cert-manager-release.yaml`** - `HelmRepository`/`HelmRelease` for cert-manager; CRDs are managed by the chart itself (`crds.enabled: true`), not vendored separately.
    * **`cert-manager-networkpolicy.yaml`** - Scopes cert-manager ingress to kube-apiserver webhook calls and egress to kube-dns, kube-apiserver, and Vault API (port 8200).
    * **`kustomization.yaml`**
  * **`cilium/`**
    * **`cilium-release.yaml`** - `HelmRepository` (OCI, `quay.io/cilium/charts`) and `HelmRelease` for Cilium, with `releaseName`/namespace matching the bootstrap install so Flux adopts the existing release instead of installing a second one. `valuesFrom` has two entries: `cilium-values` (required) and `cilium-values-hubble` (`optional: true`). `optional: true` lets the HelmRelease install cleanly without it; `helm-controller` watches the ConfigMap and re-reconciles the moment it appears, merging Hubble's values in automatically. `upgrade.crds: CreateReplace` applies new CRDs shipped by a chart upgrade (e.g. `CiliumLocalRedirectPolicy`).
    * **`cilium-values.yaml`** - Helm values for kube-proxy replacement, the k3s API server override, single-replica operator, pod CIDR, Gateway API support, L2 announcements, the egress gateway feature flag (`egressGateway.enabled`), and local redirect policy support (`localRedirectPolicy`).
    * **`clusterwide-networkpolicy.yaml`** - Cluster-wide default baseline policy allowing host ingress, cluster/kube-apiserver egress, and CoreDNS lookups.
    * **`lan-lb-pool.yaml`** / **`lan-l2-policy.yaml`** - `CiliumLoadBalancerIPPool` (a reserved block, `${GATEWAY_IP}-192.0.2.250`) / `CiliumL2AnnouncementPolicy`. Each Service claims one IP, pinned via `spec.addresses` (Gateway objects) or the `lbipam.cilium.io/ips` annotation (plain Services).
    * **`kustomization.yaml`** - Bundles the release and both LB/L2 objects, plus a `configMapGenerator` turning `cilium-values.yaml` into the `ConfigMap` the `HelmRelease`'s `valuesFrom` reads.
  * **`cnpg-operator/`**
    * **`cnpg-release.yaml`** - `HelmRepository`/`HelmRelease` for the CloudNativePG operator.
    * **`cnpg-networkpolicy.yaml`** - Restricts CNPG operator ingress and egress to `databases` (ports 8000/5432), `cnpg-system` (gRPC port 9090 for Barman Cloud Plugin), `kube-dns`, and `kube-apiserver`.
    * **`kustomization.yaml`**
  * **`coredns-custom/`**
    * **`coredns-custom.yaml`** - A `coredns-custom` ConfigMap in `kube-system`, picked up by the `*.server` import already in k3s's base Corefile. Adds an `internal` zone answering every `*.internal` name with the shared Gateway's IP.
    * **`coredns-lan-service.yaml`** - A second Service (`coredns-external`, LoadBalancer) selecting the same pods as the operator-managed `kube-dns` ClusterIP Service, so LAN clients/routers can actually reach the resolver.
    * **`kustomization.yaml`**
  * **`flux-system-policies/`**
    * **`flux-networkpolicy.yaml`** - Baseline CiliumNetworkPolicy for `flux-system` controllers.
    * **`kustomization.yaml`**
  * **`gateway/`**
    * **`gateway-tls.yaml`** - Wildcard `*.internal` edge `Certificate` for the Gateway, issued via `vault-pki-issuer`.
    * **`gateway.yaml`** - Shared `Gateway` (`internal-gateway`). An HTTPS listener (443, TLS from `gateway-tls.yaml`) for web UIs, a raw TCP listener (5432) for Postgres via `TCPRoute`.
    * **`kustomization.yaml`**
  * **`gateway-api-crds/`**
    * **`standard-install.yaml`** - Vendored Gateway API CRDs.
    * **`kustomization.yaml`**
  * **`hubble/`**
    * **`hubble-httproute.yaml`** - Attaches Hubble UI to the shared Gateway at `hubble.internal`.
    * **`cilium-values-hubble.yaml`** - Cilium chart values enabling Hubble Relay/UI with cert-manager-issued mTLS, referencing `vault-pki-issuer`.
    * **`kustomization.yaml`**
  * **`namespaces/`**
    * **`namespaces.yaml`** - Creates every namespace Flux needs a home for up front (`vault`, `vso-system`, `cnpg-system`, `databases`, `cert-manager`, `gateway`). A `HelmRelease` doesn't auto-create its own namespace.
    * **`kustomization.yaml`**
  * **`vault/`**
    * **`vault-tls.yaml`** - Creates local CA (`vault-local-ca`), `vault-ca-issuer`, server certificate (`vault-server-cert`), cross-namespace CA bundle for VSO (`vault-ca-databases`), and the `vault-pki-issuer` ClusterIssuer backed by Vault's intermediate PKI engine with tokenrequest RBAC.
    * **`vault-release.yaml`** - `HelmRepository`/`HelmRelease` for the in-cluster Vault.
    * **`vault-values.yaml`** - Helm values for transit auto-unseal against the host-level Vault, the Agent Injector disabled (VSO syncs secrets instead of sidecar injection).
    * **`vault-networkpolicy.yaml`** - Scopes Vault ingress to `vso-system` and `cert-manager`, and egress to the host Transit Vault (`${HOST_IP}:8200`) and Postgres (`5432`).
    * **`kustomization.yaml`** - Bundles the release, TLS resources, and values ConfigMap.
  * **`vault-secrets-operator/`**
    * **`vso-release.yaml`** - `HelmRepository`/`HelmRelease` for the Vault Secrets Operator.
    * **`vso-networkpolicy.yaml`** - Scopes VSO egress to kube-dns, kube-apiserver, and Vault API (`vault.vault.svc:8200`).
    * **`kustomization.yaml`**
* **`terraform/`** OpenTofu modules configuring cluster-config and Vault's internals (KV secrets, Kubernetes auth backend, 2-tier PKI engine, database secrets engine, host Transit Vault autounseal token). State is local and gitignored throughout; the Vault-facing modules additionally encrypt state at rest via OpenTofu's own `encryption` block, since they handle credentials. These modules are applied by `just bootstrap`; see `INSTALLATION.md` for what it does and how to apply them by hand if needed.
  * **`cluster-config/`** - Creates the `cluster-config` Secret in `flux-system` (`GATEWAY_IP`, `COREDNS_LAN_IP`, `HOST_IP`, `CILIUM_VERSION`), read by `gateway`, `coredns-custom`, `cilium`, `vault`, and `databases` via Flux's `postBuild.substituteFrom`. Values come from a `terraform.tfvars` you provide (gitignored), never committed. Applied first, right after k3s is installed
  * **`vault/`** - Unified module targeting the **in-cluster** Vault: KV mounts/secrets (`secret/postgis`, `secret/seaweedfs`), Kubernetes auth backend and roles (`postgis-role`, `cert-manager-pki-role`), 2-tier PKI engine (`pki_root`, `pki_int` with RFC 5280 Name Constraints, `internal-server` role), and database secrets engine connection and dynamic role (`postgis-cluster`, `postgis-app-role`).
  * **`vault-transit-bootstrap/`** - The transit engine/key, `autounseal-policy`, and the periodic orphan token the in-cluster Vault uses for auto-unseal. Targets the **host** Transit Vault (port 8200).
