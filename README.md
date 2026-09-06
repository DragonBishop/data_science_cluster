# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a PostgreSQL server with the PostGIS extension enabled. It provides a scalable foundation for data science projects, such as Extract, Transform, and Load (ETL) pipelines and Machine Learning (ML).

This cluster utilizes Ansible, `FluxCD`, `Kustomization`, and Helm to structure and manage the rollout of the environment:

* **Ansible:** Automates idempotent host-level bootstrapping, system dependencies, and initial cluster initialization.
* **Flux CD:** Continuously reconciles cluster state against this Git repository as the single source of truth to prevent configuration drift.
* **Helm:** Manages third-party packages via `HelmRelease` manifests, allowing clean parameterization through ConfigMaps and Secrets while preserving upstream maintainability.
* **Kustomization:** Breaks down complex Kubernetes resources into manageable, hierarchical modules whose explicit dependency chains (`dependsOn`) Flux follows during reconciliation.

Cluster secrets and security rely on an in-cluster HashiCorp Vault, unsealed automatically at boot via a host-managed GPG-encrypted keyfile. OpenTofu declaratively configures Vault's internal engines, access policies, and Kubernetes authentication backend. Integrated with `cert-manager`, Vault's multi-tier Public Key Infrastructure (PKI) engine dynamically issues and rotates X.509 TLS certificates, while the Vault Secrets Operator (VSO) securely injects static configuration and short-lived, dynamic database credentials directly into application workloads.

Workloads are structured modularly to maximize compute efficiency on local hardware. The cluster maintains an always-on core database architecture, powered by PostgreSQL/PostGIS (CloudNativePG), Cilium eBPF networking and Gateway routing, and SeaweedFS S3-compatible storage. Specialized modules for cluster observability, ETL data pipelines, and machine learning workflows can be deployed dynamically when performing specific data science tasks and torn down afterward to conserve memory and CPU.

Customizable VS Code DevContainer configurations are provided in `.devcontainer/` for both host-side cluster administration and in-cluster runtime workloads. The entire platform has been developed and tested on both **Ubuntu** and **Fedora**.

## Table of Contents

* [Cluster Architecture](#cluster-architecture)
  * [Host-Side Provisioning](#host-side-provisioning)
  * [Core Database Architecture](#core-database-architecture)
  * [Cluster Monitoring Module](#cluster-monitoring-module)
  * [ETL Pipeline Module](#etl-pipeline-module)
  * [Machine Learning Module](#machine-learning-module)
* [Official Documentation](#official-documentation)
  * [Host Side Tooling](#host-side-tooling)
  * [Core Architecture](#core-architecture)
  * [Cluster Monitoring Services](#cluster-monitoring-services)
  * [ETL and ML Services](#etl-and-ml-services)
* [Cluster Operations](#cluster-operations)
  * [Bootstrap](#bootstrap)
  * [Cluster Lifecycle](#cluster-lifecycle)
  * [Database](#database)
  * [Gateway](#gateway)
  * [Observability (Hubble)](#observability-hubble)
  * [Vault](#vault)
  * [Development](#development)
* [Restoring the Database from SeaweedFS](#restoring-the-database-from-seaweedfs)
* [Repository Structure](#repository-structure)
* [File Descriptions](#file-descriptions)

---

## Cluster Architecture

### Host-Side Provisioning

These tools must be installed or configured on the host machine to bootstrap, template, manage, and operate the cluster:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| Ansible | `2.18+` (`ansible-core`) | Idempotent cluster bootstrap playbook and host setup (`ansible/playbooks/data_cluster.yml`). |
| Flux CLI | `v2.9.4` (`fluxcd.io`) | GitOps controller CLI used for pre-flight validation and repository bootstrapping. |
| GitHub CLI (`gh`) | `gh` | Fallback GitHub authentication for automated repository access if a GitHub App is not configured. |
| Helm | `v3.x` (`get_helm.sh`) | Package manager for Kubernetes charts and HelmRelease dependency resolution. |
| just | `just` | Command runner orchestrating cluster lifecycle, database, and dev recipes (`justfile`). |
| OpenTofu | `1.9.0` (standalone binary) | Declarative secrets, PKI engine, and Kubernetes auth management in Vault (`terraform/vault/`). |
| PostgreSQL Client (`psql`) | `postgresql-client` | Host CLI client for local database administration and connectivity testing. |
| uv | `astral-sh/uv` | Fast Python package manager and virtual environment resolver (`pyproject.toml`). |

### Core Database Architecture

These are the resources that make up the database core of the cluster. It is engineered to scale into demanding and complex workloads, and relies on open source software that is efficient, organized, and lightweight. The version numbers here serve as a reference for those in the manifests intended to be deployed live.

| Component | Version | Description |
| --- | --- | --- |
| Barman Cloud Plugin | `0.7.1` | WAL archiving and base backups for CNPG, via the `ObjectStore` resource rather than in-tree `spec.backup.barmanObjectStore`. |
| cert-manager | `1.21.1` | Manages local edge CA, provisions Vault TLS, and mints leaf certificates via `vault-pki-issuer`. |
| Cilium | `1.20.1` | CNI; replaces k3s's default networking, eBPF routing/load-balancing in place of kube-proxy, serves the Gateway API. |
| CloudNativePG (CNPG) | `0.29.0` | Operator managing the PostgreSQL/PostGIS lifecycle: provisioning, reconciliation, hibernation, backup orchestration. |
| DNS (CoreDNS) | `v1.14.6` | k3s's own in-cluster CoreDNS (`kube-system`), extended with an `internal` zone via a `coredns-custom` ConfigMap (`infrastructure/coredns-custom/`). Resolves `*.internal` to the shared Gateway's IP for LAN clients, alongside its existing `*.svc.cluster.local` role for pods. |
| Flux | `v2.9.4` | GitOps controller; reconciles every `Kustomization` under `clusters/local/`, `dependsOn`-chained starting Gateway API CRDs → Cilium. CLI-installed, unpinned by this repo. |
| Gateway | `v1.6.1` (CRDs) | One shared `Gateway` (`internal-gateway`) every tool attaches a `Route` to: an HTTPS listener (443, wildcard cert) for web UIs, a raw TCP listener (5432) for Postgres. |
| Gateway API | `v1.6.1` (CRDs) | Kubernetes-native API for describing traffic routing. `GatewayClass` names an implementation (e.g. Cilium); `Gateway` defines listeners (ports, protocols, hostnames); `HTTPRoute`/`TCPRoute`/`TLSRoute`/`GRPCRoute`/`UDPRoute` attach to a Gateway and route traffic by protocol to backend Services; `ReferenceGrant` allows routes to reference backends in another namespace; `BackendTLSPolicy` configures TLS to a backend; `ListenerSet` lets a listener be shared/delegated across teams. |
| HashiCorp Vault (in-cluster) | `2.0.4` (chart `0.34.1`) | Main Vault; unseals itself at pod start via a GPG-encrypted keyfile on the host. Hosts KV secrets, Kubernetes Auth, 2-tier PKI engine (Root + Intermediate CA with RFC 5280 Name Constraints), and database secrets engine. |
| Headlamp | `0.45.0` | Cluster GUI; can be installed as a desktop app, or deployed within the cluster. Has a number of plugins that assist with cluster management. |
| Hubble | `v1.20.0` (Relay), `v0.13.5` (UI) | Cilium's network observability layer. Relay/UI run their own cert-manager mTLS trust domain; UI exposed at `hubble.internal` on the shared Gateway. |
| k3s | `v1.36.4+k3s1` | Core control plane and execution environment. Host-installed, unpinned by this repo. |
| PostgreSQL / PostGIS image | `18.6-3.6.4-system-trixie` | Image the CNPG `Cluster` runs (`18.6` PostgreSQL, `3.6.4` PostGIS). |
| SeaweedFS | `4.44.0` | In-cluster S3-compatible object store with TLS issued by `vault-pki-issuer`. CNPG streams WAL and writes scheduled base backups to it over HTTPS (`https://seaweedfs-s3.databases.svc:9000`). |
| Vault Database & PKI Engines | Same as Vault | Issues Postgres login roles on demand (3h default TTL / 24h max) and issues 30-day TLS certificates via cert-manager. |
| Vault Secrets Operator (VSO) | `1.5.1` | Reads Main Vault values into Kubernetes `Secret`s; refreshes static secrets, renews dynamic leases. |

### Cluster Monitoring Module

These are the set of operators that need to be deployed in addition to the core to scale into ETL or ML workloads.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| kube-prometheus-stack | `88.5.4` (chart, latest; not yet deployed) | Deploys the industry-standard Prometheus, Grafana, and Alertmanager bundle for comprehensive metric aggregation and dashboarding, to debug resource spikes and workload bottlenecks. | `victoria-metrics-k8s-stack` uses VictoriaMetrics instead of Prometheus. Lower footprint, but more work to customize. |
| Loki | `v3.7.6` (latest; not yet deployed) | Log aggregation and processing, paired with kube-prometheus-stack to round out metrics + logs observability. | `VictoriaLogs` particularly if using the same stack as above. |
| Tekton Pipelines | `v1.15.0` (latest; not yet deployed) | Cluster-native CI engine with Pipelines/Tasks/PipelineRuns from CRDs. | Woodpecker CI, if a single self-hosted binary with GitHub-Actions-like YAML is preferred over Tekton's CRD model. |
| Tekton Triggers | `v0.37.0` (latest; not yet deployed) | EventListener reacting to GitHub webhook events (push/PR), starting the matching PipelineRun. | GitHubs Actions is the standard for ci workflow, and can offer basic complimentary CI services on github. |
| Tetragon | `v1.7.1` (latest release; not yet deployed) | Real-time, eBPF-based detection of anomalous behavior at the syscall level. Detects unexpected shell spawns inside a container, unauthorized reads of sensitive files, privilege escalation attempts. Shares the eBPF datapath Cilium uses, and comes from the same developer. | Falco is the more battle-tested choice, with a larger existing rule/policy ecosystem, if Tetragon's policy library proves too thin in practice. |

### ETL Pipeline Module

The ETL pipeline rollout focuses on data ingestion, declarative orchestration, and in-database transformation. Python's modules allow for each step in ETL to be accomplished within Python:

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| dbt (dbt-core, dbt-postgres) | `1.12.3` | Executes complex SQL-based transformations natively within the CloudNativePG database, ensuring compute remains close to the data. | Apache Spark is the industry standard for massive-scale, distributed data transformation, but heavier and more appropriate for spinning up dedicated compute clusters rather than pushing compute down in a bare-metal development environment. and more appropriate for pushing compute down into a local database rather than spinning up dedicated compute clusters. |
| dlt | `1.30.0` | Open-source Python library (data load tool) for building declarative data pipelines that load data from REST APIs, databases, and other sources. | Airbyte is a fallback option if a UI-driven ecosystem of pre-built connectors is eventually needed. |
| Prefect | `3.8.4` | Replaces heavy legacy schedulers with a Python-native, highly observable orchestration engine for triggering data pipelines. | Apache Airflow is the industry-standard alternative for data orchestration, but its heavy infrastructure footprint (requiring multiple dedicated scheduler, webserver, and worker pods) makes it overly complex for a lightweight local cluster. |

### Machine Learning Module

The ML expansion focuses on managing experiment tracking, environment provisioning, and model serving, utilizing strictly open-source (Apache 2.0) tooling. Not yet in the repo directory; ordered alphabetically by component name.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| BentoML | `v1.4.39` (latest; not yet installed) | Packages models into self-contained, production-ready services using a Python-first framework. | KServe offers Kubernetes-native inference features like scale-to-zero or advanced GPU scheduling. |
| MLflow | `3.15.2` (latest; not yet installed) | Tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in the cluster's SeaweedFS object store. | Kubeflow is the standard for teams prepared for, and heavily invested in, Kubernetes orchestration. |

---

## Official Documentation

### Host Side Tooling

| Component | Documentation Link |
| --- | --- |
| Ansible | [https://docs.ansible.com/](https://docs.ansible.com/) |
| Flux CLI | [https://fluxcd.io/flux/cmd/](https://fluxcd.io/flux/cmd/) |
| GitHub CLI (`gh`) | [https://cli.github.com/manual/](https://cli.github.com/manual/) |
| Helm | [https://helm.sh/docs/](https://helm.sh/docs/) |
| Just | [https://just.systems/man/en/](https://just.systems/man/en/) |
| OpenTofu | [https://opentofu.org/docs/](https://opentofu.org/docs/) |
| PostgreSQL Client (`psql`) | [https://www.postgresql.org/docs/current/app-psql.html](https://www.postgresql.org/docs/current/app-psql.html) |
| uv | [https://docs.astral.sh/uv/](https://docs.astral.sh/uv/) |

### Core Architecture

| Component | Documentation Link |
| --- | --- |
| Barman Cloud Plugin | [https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/) |
| cert-manager | [https://cert-manager.io/docs/](https://cert-manager.io/docs/) |
| Cilium | [https://docs.cilium.io/](https://docs.cilium.io/) |
| CloudNativePG | [https://cloudnative-pg.io/docs](https://cloudnative-pg.io/docs) |
| CNPG Certificates | [https://cloudnative-pg.io/documentation/current/certificates/](https://cloudnative-pg.io/documentation/current/certificates/) |
| CNPG Hibernation | [https://cloudnative-pg.io/documentation/current/declarative_hibernation/](https://cloudnative-pg.io/documentation/current/declarative_hibernation/) |
| CoreDNS | [https://coredns.io/manual/toc/](https://coredns.io/manual/toc/) |
| Flux | [https://fluxcd.io/flux/](https://fluxcd.io/flux/) |
| Gateway API | [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/) |
| HashiCorp Vault | [https://developer.hashicorp.com/vault/docs](https://developer.hashicorp.com/vault/docs) |
| Headlamp | [https://headlamp.dev/docs/latest/](https://headlamp.dev/docs/latest/) |
| Hubble | [https://docs.cilium.io/en/stable/observability/hubble/](https://docs.cilium.io/en/stable/observability/hubble/) |
| k3s | [https://docs.k3s.io/](https://docs.k3s.io/) |
| PostGIS Extension | [https://postgis.net/documentation/](https://postgis.net/documentation/) |
| PostgreSQL | [https://www.postgresql.org/docs/current/](https://www.postgresql.org/docs/current/) |
| SeaweedFS | [https://github.com/seaweedfs/seaweedfs/wiki](https://github.com/seaweedfs/seaweedfs/wiki) |
| Vault Database Secrets Engine | [https://developer.hashicorp.com/vault/docs/secrets/databases](https://developer.hashicorp.com/vault/docs/secrets/databases) |
| Vault PKI Secrets Engine | [https://developer.hashicorp.com/vault/docs/secrets/pki](https://developer.hashicorp.com/vault/docs/secrets/pki) |
| Vault Secrets Operator | [https://developer.hashicorp.com/vault/docs/vault-secrets-operator](https://developer.hashicorp.com/vault/docs/vault-secrets-operator) |

### Cluster Monitoring Services

| Component | Documentation Link |
| --- | --- |
| kube-prometheus-stack | [https://github.com/prometheus-operator/kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) |
| Loki | [https://grafana.com/docs/loki/latest/](https://grafana.com/docs/loki/latest/) |
| Tetragon | [https://tetragon.io/](https://tetragon.io/) |

### ETL and ML Services

| Component | Documentation Link |
| --- | --- |
| BentoML | [https://docs.bentoml.com/](https://docs.bentoml.com/) |
| dbt | [https://docs.getdbt.com/](https://docs.getdbt.com/) |
| dlt | [https://dlthub.com/docs](https://dlthub.com/docs) |
| MLflow | [https://mlflow.org/docs/latest/index.html](https://mlflow.org/docs/latest/index.html) |
| Prefect | [https://docs.prefect.io/](https://docs.prefect.io/) |
| Tekton Pipelines | [https://tekton.dev/docs/pipelines/](https://tekton.dev/docs/pipelines/) |
| Tekton Triggers | [https://tekton.dev/docs/triggers/](https://tekton.dev/docs/triggers/) |

---

## Cluster Operations

Organized to match the justfile's own section layout (`just --list` shows every recipe in order).

### Bootstrap

One-time, first-install setup: see `INSTALLATION.md` for Requirements and what the script does.

| Command | Operation | When |
| --- | --- | --- |
| `just preflight` | Run host readiness check | Verify host tooling, `gh` auth, firewall rules, and reserved IP range before install |
| `just bootstrap` (accepts flags like `--tags`, `--check`, `-v`) | Run full cluster bootstrap via Ansible | Provision k3s, Cilium, Flux, Vault, and apply initial OpenTofu secrets |

### Cluster Lifecycle

| Command | Operation | When |
| --- | --- | --- |
| `just start` | Start the cluster | Each work session; starts k3s services and automatically unseals Vault |
| `just status` | Check overall cluster health | Post-install verification or periodic health check across Flux, Gateway/DNS, cert-manager, database, backups, SeaweedFS, and Hubble |
| `just fuzzypods` | Interactively inspect a pod | Ad hoc troubleshooting; fuzzy-select a pod from all namespaces and describe it |
| `just stop` (`just stop --force` if a stuck stop needs it) | Stop the cluster | Each work session; gracefully hibernates CNPG PostgreSQL before shutting down k3s |
| `just uninstall` | Uninstall k3s and clear stale local state | Reinstalling from scratch; runs `k3s-uninstall.sh` and clears local Vault/Postgres/Hubble caches and orphaned `terraform/vault` state |

### Database

| Command | Operation | When |
| --- | --- | --- |
| `just db-connect` (`just db-connect localhost` from node) | Connect via psql (app role, host) | Application-level database access with Vault-issued dynamic credentials |
| `kubectl cnpg psql postgis-cluster -n databases` | Connect via psql (superuser, in-cluster) | Ad hoc direct administrative query access as `postgres` superuser |
| `kubectl cnpg backup postgis-cluster -n databases -m plugin --plugin-name barman-cloud.cloudnative-pg.io` | Trigger a manual DB backup | Before schema changes or risky migrations; writes backup to SeaweedFS S3 |
| `kubectl get scheduledbackup -n databases -o yaml \| grep -i suspend` | Check scheduled backup status | Confirming automated nightly backups are active (`suspend: false`) |
| `kubectl cnpg status postgis-cluster -n databases` | Verify CNPG cluster state | Detailed PostgreSQL replication, WAL archiving, and instance diagnostics |

### Gateway

| Command | Operation | When |
| --- | --- | --- |
| `just gateway-check` (`just gateway-check <HOST> <DOMAIN>`) | Verify Gateway routing | Post-install verification or testing Gateway HTTPRoute and TLS edge certificates |

### Observability (Hubble)

| Command | Operation | When |
| --- | --- | --- |
| `just hubble-ui` | Open Hubble web UI | Quick local UI access; starts a background port-forward to `localhost:12000` and opens default browser |
| `just hubble` / `just hubble observe --follow` | Stream Hubble flows (CLI) | Real-time network and security flow inspection over mTLS |
| `just hubble-pf` | Port-forward Hubble Relay only | Direct local port-forward to Hubble Relay on `localhost:4245` |

### Vault

| Command | Operation | When |
| --- | --- | --- |
| `just vault-shell` | Open interactive Vault shell | Direct CLI access inside `vault-0` pod with a sanitized environment |
| `just vault-pf` | Port-forward Vault API to host | Exposes in-cluster Vault API at `https://127.0.0.1:8210` and exports internal CA |
| `kubectl exec -n vault vault-0 -- vault status` | Verify Vault seal state | Diagnostic check for Vault initialization, sealing, and HA status |

### Development

| Command | Operation |
| --- | --- |
| `just install` | Install dependencies |
| `just setup` | Set up the dev environment (install + git filters) |
| `just test-cov` | Run tests with coverage |
| `just update` | Update packages and the lockfile |
| `just git-setup` | Configure the `nbwipers` git filter |

---

## Restoring the Database from SeaweedFS

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
  imageName: ghcr.io/cloudnative-pg/postgis:18.6-3.6.4-system-trixie
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

---

## Repository Structure

```text
├── .devcontainer/                       # VS Code Dev Container configurations
│   ├── cluster/                         # In-cluster ETL/pipeline runtime container
│   │   ├── devcontainer.json
│   │   └── Dockerfile
│   └── host/                            # Host-level cluster management container
│       ├── devcontainer.json
│       └── Dockerfile
├── .github/
│   ├── ISSUE_TEMPLATE/                  # Bug/documentation/feature/tech-debt issue forms
│   │   ├── bug_report.yml
│   │   ├── config.yml
│   │   ├── documentation-update.yml
│   │   ├── feature-proposal.yml
│   │   └── technical-debt-resolution.yml
│   └── workflows/
│       ├── lint.yml                     # ruff check/format
│       ├── tests.yml                    # pytest + coverage
│       └── release.yml                  # PR-title lint + release-please + git-cliff changelog
├── ansible/                             # Ansible playbooks and roles for cluster provisioning
│   ├── inventory/
│   │   ├── group_vars/
│   │   │   └── all.yml
│   │   └── hosts.ini
│   ├── playbooks/
│   │   └── data_cluster.yml
│   ├── requirements.yml
│   └── roles/
│       ├── cilium/
│       ├── flux/
│       ├── k3s/
│       ├── opentofu/
│       └── vault/
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
│       ├── flux-system/                 # **DO NOT EDIT** Written by `flux bootstrap`
│       │   ├── gotk-components.yaml
│       │   ├── gotk-sync.yaml
│       │   └── kustomization.yaml
│       ├── flux-system-policies.yaml    # Kustomization → infrastructure/flux-system-policies/
│       ├── gateway-api-crds.yaml        # Kustomization → infrastructure/gateway-api-crds/
│       ├── gateway.yaml                 # Kustomization → infrastructure/gateway/
│       ├── hubble.yaml                  # Kustomization → infrastructure/hubble/
│       ├── namespaces.yaml              # Kustomization → infrastructure/namespaces/
│       ├── vault-secrets-operator.yaml  # Kustomization → infrastructure/vault-secrets-operator/
│       └── vault.yaml                   # Kustomization → infrastructure/vault/
├── infrastructure/                      # Cluster-wide platform components
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
│   │   ├── kustomization.yaml
│   │   ├── kustomizeconfig.yaml
│   │   ├── lan-l2-policy.yaml
│   │   └── lan-lb-pool.yaml
│   ├── cluster-config/                  # Centralized cluster topology and configuration ConfigMap
│   │   ├── cluster-config.yaml
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
│   ├── gateway-api-crds/
│   │   ├── kustomization.yaml
│   │   └── standard-install.yaml        # Vendored Gateway API CRDs
│   ├── gateway/
│   │   ├── gateway-tls.yaml
│   │   ├── gateway.yaml
│   │   └── kustomization.yaml
│   ├── hubble/
│   │   ├── cilium-values-hubble.yaml
│   │   ├── hubble-httproute.yaml
│   │   └── kustomization.yaml
│   ├── namespaces/
│   │   ├── kustomization.yaml
│   │   └── namespaces.yaml
│   ├── vault-secrets-operator/
│   │   ├── kustomization.yaml
│   │   ├── vso-networkpolicy.yaml
│   │   └── vso-release.yaml
│   └── vault/
│       ├── kustomization.yaml
│       ├── vso-networkpolicy.yaml
│       └── vso-release.yaml
├── notebooks/
│   ├── data_analysis_notebook.ipynb     # Exploratory analysis and findings
│   └── data_processing_notebook.ipynb   # Data cleaning and integrity checks
├── src/
│   ├── bash/
│   │   ├── preflight.sh                 # Read-only host readiness checks
│   │   ├── start-cluster.sh             # Boot sequence: API, in-cluster Vault unseal, readiness checks
│   │   └── stop-cluster.sh              # Graceful shutdown via CNPG declarative hibernation
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
├── terraform/                           # OpenTofu module configuring Vault's internals
│   └── vault/                           # Unified in-cluster Vault: KV mounts, Kubernetes auth, 2-tier PKI engine, DB secrets
│       ├── .gitignore
│       ├── database.tf
│       ├── encryption.tf
│       ├── kubernetes-auth.tf
│       ├── kv.tf
│       ├── pki.tf
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
├── INSTALLATION.md                      # First-time cluster bootstrap: Requirements, then `just bootstrap`
├── justfile                             # `just setup` (review for more commands)
├── pyproject.toml                       # uv-managed clusterpgis package + dev tooling
├── README.md                            # Architecture, setup, and operations reference
├── troubleshooting.md                   # Symptom → cause → fix, by subsystem
└── uv.lock
```

### File Descriptions

* **`.devcontainer/`** - VS Code Dev Container configurations providing isolated development environments.
  * **`cluster/`**: In-cluster ETL and pipeline runtime environment.
    * **`devcontainer.json`**: Devcontainer configuration targeting the in-cluster runtime image with DataOps, Jupyter, and Python tooling.
    * **`Dockerfile`**: Builds the in-cluster runtime image with Python 3.14, `uv`, and the VS Code CLI tunnel daemon (`code tunnel`).
  * **`host/`**: Host-level cluster management container with host networking (`--network=host`) and mounted Kubernetes contexts.
    * **`devcontainer.json`**: Devcontainer configuration mounting host `~/.kube/config` and `~/.config/helm` with direct access to local k3s services.
    * **`Dockerfile`**: Builds the host management environment including `kubectl`, `helm`, `kubectl-cnpg`, `cilium`, `hubble`, `flux`, `postgresql-client`, `just`, and `uv`.
* **`.github/`**
  * **`ISSUE_TEMPLATE/`**: Issue templates for bug reports, documentation updates, feature proposals, and technical-debt resolution.
  * **`workflows/lint.yml`**: On pull requests, via `astral-sh/setup-uv`, runs `ruff check`/`ruff format --check`.
  * **`workflows/tests.yml`**: On pull requests, via `astral-sh/setup-uv`, runs `pytest` with coverage against `src/clusterpgis`.
  * **`workflows/release.yml`**: On pull requests, lints the PR title against Conventional Commits (`amannn/action-semantic-pull-request`); on push to `main`, `release-please` opens/updates a release PR and, once a release is tagged, regenerates `CHANGELOG.md` with `git-cliff` and pushes it back to `main`.
* **`ansible/`** - Automated provisioning and orchestration playbooks for bootstrapping the cluster.
  * **`inventory/`**: Inventory definition (`hosts.ini`) and global variable mapping (`group_vars/all.yml`) sourcing values directly from `infrastructure/cluster-config/cluster-config.yaml`.
  * **`playbooks/data_cluster.yml`**: Main playbook executing roles in order: `k3s` → `cilium` → `flux` → `vault` → `opentofu`.
  * **`requirements.yml`**: Ansible Galaxy collection dependencies (`kubernetes.core`, `cloud.terraform`, `containers.podman`).
  * **`roles/`**: Reusable Ansible roles for configuring k3s systemd service, Gateway API CRDs & Cilium Helm release, GitHub Flux bootstrap, Vault initialization & GPG unseal automation, and OpenTofu state application.
* **`apps/databases/`** - The PostGIS cluster and everything it depends on, reconciled as one Flux `Kustomization` (`clusters/local/databases.yaml`).
  * **`kustomization.yaml`**: Every resource this Kustomization builds, in one pass.
  * **`postgis-cluster.yaml`**: The CNPG `Cluster`, its static and dynamic Vault secrets, the `ObjectStore` (configured with `https://seaweedfs-s3.databases.svc:9000`), and `ScheduledBackup` used for backups.
  * **`postgis-database.yaml`**: CNPG `Database` CRD declares `data_science`, its owner, schemas, and PostGIS extensions.
  * **`postgis-localhost.yaml`**: `CiliumLocalRedirectPolicy` redirecting `127.0.0.1:5432` on the node to the CNPG primary pod via eBPF, selected by CNPG's `instanceRole` label.
  * **`postgis-networkpolicy.yaml`**: Restricts PostGIS database ingress (CNPG operator, Vault) and egress (kube-dns, SeaweedFS S3).
  * **`postgis-tcproute.yaml`**: `TCPRoute` attaching the CNPG primary to the shared Gateway's raw-TCP listener (`infrastructure/gateway/`).
  * **`postgis-tls.yaml`**: cert-manager `Certificate` requesting the Postgres server certificate from `vault-pki-issuer`. SANs cover `localhost`/`127.0.0.1`, `postgis.internal`, and the shared Gateway's static LAN IP.
  * **`seaweedfs-credentials.yaml`**: `VaultStaticSecret` syncing S3 credentials from `secret/seaweedfs`.
  * **`seaweedfs-networkpolicy.yaml`**: Restricts SeaweedFS ingress and egress to the `databases` namespace and `kube-dns`.
  * **`seaweedfs-release.yaml`**: `HelmRepository`/`HelmRelease` for SeaweedFS, master/filer data on the external storage via `hostPath`, S3 gateway on port 9000 with TLS issued by `vault-pki-issuer`, and `cnpg-backups` bucket created at install.
  * **`vso-setup.yaml`**: Creates the `VaultConnection`/`VaultAuth`/`ServiceAccount` VSO uses to authenticate to Vault.
* **`clusters/local/`** - Flux's own root, pointed at by `flux bootstrap --path=clusters/local`. One Kustomization per directory under `infrastructure/`/`apps/` below.
  * **`barman-cloud.yaml`**: Kustomization → `infrastructure/barman-cloud/`
  * **`cert-manager.yaml`**: Kustomization → `infrastructure/cert-manager/`
  * **`cilium.yaml`**: Kustomization → `infrastructure/cilium/`
  * **`cnpg-operator.yaml`**: Kustomization → `infrastructure/cnpg-operator/`
  * **`coredns-custom.yaml`**: Kustomization → `infrastructure/coredns-custom/`
  * **`databases.yaml`**: Kustomization → `apps/databases/`
  * **`flux-system/`**: (`gotk-components.yaml`, `gotk-sync.yaml`, `kustomization.yaml`): Flux's own controllers and `GitRepository` source, written by `flux bootstrap` (do not edit directly).
  * **`flux-system-policies.yaml`**: Kustomization → `infrastructure/flux-system-policies/`
  * **`gateway-api-crds.yaml`**: Kustomization → `infrastructure/gateway-api-crds/`
  * **`gateway.yaml`**: Kustomization → `infrastructure/gateway/`
  * **`hubble.yaml`**: Kustomization → `infrastructure/hubble/`
  * **`namespaces.yaml`**: Kustomization → `infrastructure/namespaces/`
  * **`vault-secrets-operator.yaml`**: Kustomization → `infrastructure/vault-secrets-operator/`
  * **`vault.yaml`**: Kustomization → `infrastructure/vault/`
* **`infrastructure/`** - Cluster-wide platform components, listed alphabetically below:
  * **`barman-cloud/`**: `barman-cloud-release.yaml`, `kustomization.yaml`
  * **`cert-manager/`**: `cert-manager-networkpolicy.yaml`, `cert-manager-release.yaml`, `kustomization.yaml`
  * **`cilium/`**: `cilium-release.yaml`, `cilium-values.yaml`, `clusterwide-networkpolicy.yaml`, `kustomization.yaml`, `kustomizeconfig.yaml`, `lan-l2-policy.yaml`, `lan-lb-pool.yaml`
  * **`cluster-config/`**: `cluster-config.yaml`, `kustomization.yaml` (centralized configuration ConfigMap)
  * **`cnpg-operator/`**: `cnpg-networkpolicy.yaml`, `cnpg-release.yaml`, `kustomization.yaml`
  * **`coredns-custom/`**: `coredns-custom.yaml`, `coredns-lan-service.yaml`, `kustomization.yaml` (internal zone on CoreDNS)
  * **`flux-system-policies/`**: `flux-networkpolicy.yaml`, `kustomization.yaml`
  * **`gateway-api-crds/`**: `kustomization.yaml`, `standard-install.yaml` (vendored Gateway API CRDs)
  * **`gateway/`**: `gateway-tls.yaml`, `gateway.yaml`, `kustomization.yaml`
  * **`hubble/`**: `cilium-values-hubble.yaml`, `hubble-httproute.yaml`, `kustomization.yaml`
  * **`namespaces/`**: `kustomization.yaml`, `namespaces.yaml`
  * **`vault-secrets-operator/`**: `kustomization.yaml`, `vso-networkpolicy.yaml`, `vso-release.yaml`
  * **`vault/`**: `kustomization.yaml`, `kustomizeconfig.yaml`, `vault-networkpolicy.yaml`, `vault-release.yaml`, `vault-tls.yaml`, `vault-values.yaml`
* **`src/`**
  * **`src/bash/`**:
    * **`preflight.sh`**: Read-only host readiness checks (tooling, `gh` auth, firewall state, LAN IP collisions).
    * **`start-cluster.sh`**: Boot sequence: starting k3s systemd unit, waiting for API/node readiness, unsealing the in-cluster Vault, and reactivating hibernated workloads.
    * **`stop-cluster.sh`**: Graceful shutdown: declaratively hibernating the CNPG cluster, waiting for pod termination, and stopping the k3s systemd unit.
  * **`src/clusterpgis/`**: The installable `clusterpgis` Python package structured across `data/`, `features/`, `models/`, and `visualization/`.
* **`terraform/`** - OpenTofu module configuring Vault's internals (KV secrets, Kubernetes auth backend, 2-tier PKI engine, database secrets engine). State is local and gitignored; additionally encrypted at rest via OpenTofu's own `encryption` block. Applied during `just bootstrap`.
  * **`vault/`**: Unified module targeting the **in-cluster** Vault: KV mounts/secrets (`secret/postgis`, `secret/seaweedfs`), Kubernetes auth backend and roles (`postgis-role`, `cert-manager-pki-role`), 2-tier PKI engine (`pki_root`, `pki_int` with RFC 5280 Name Constraints, `internal-server` role), and database secrets engine connection and dynamic role (`postgis-cluster`, `postgis-app-role`).
* **`tests/`**
  * **`conftest.py`**: Shared test fixtures and pytest configuration.
  * **`test_example.py`**: Example test suite for package sanity checks.
