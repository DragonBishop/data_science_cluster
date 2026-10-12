# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a PostgreSQL server with the PostGIS extension enabled. It provides a scalable foundation for data science projects, such as Extract, Transform, and Load (ETL) pipelines and Machine Learning (ML).

This cluster utilizes Ansible, `FluxCD`, `Kustomization`, and Helm to structure and manage the rollout of the environment:

* **Ansible:** Automates idempotent host-level bootstrapping, system dependencies, and initial cluster initialization.
* **Flux CD:** Continuously reconciles cluster state against this Git repository as the single source of truth to prevent configuration drift.
* **Helm:** Manages third-party packages via `HelmRelease` manifests, allowing clean parameterization through ConfigMaps and Secrets while preserving upstream maintainability.
* **Kustomization:** Breaks down complex Kubernetes resources into manageable, hierarchical modules whose explicit dependency chains (`dependsOn`) Flux follows during reconciliation.

Cluster secrets and security rely on an in-cluster OpenBao, unsealed at boot from a GPG-encrypted keyfile kept gitignored in this repo (`.local/openbao/`). OpenTofu declaratively configures OpenBao's internal engines, access policies, and Kubernetes authentication backend. Integrated with `cert-manager`, OpenBao's multi-tier Public Key Infrastructure (PKI) engine dynamically issues and rotates X.509 TLS certificates, while the External Secrets Operator (ESO) syncs static configuration and short-lived, dynamic database credentials into Kubernetes `Secret`s for application workloads.

Workloads are structured modularly to maximize compute efficiency on local hardware. The cluster maintains an always-on core database architecture, powered by PostgreSQL/PostGIS (CloudNativePG), Cilium eBPF networking and Gateway routing, and SeaweedFS S3-compatible storage. Specialized modules for cluster observability, ETL data pipelines, and machine learning workflows can be deployed dynamically when performing specific data science tasks and torn down afterward to conserve memory and CPU.

Customizable VS Code DevContainer configurations are provided in `.devcontainer/` for both host-side cluster administration and in-cluster runtime workloads. The entire platform has been developed and tested on both **Ubuntu** and **Fedora**.

## Documentation

* [Installation](docs/INSTALLATION.md): first-time setup
* [Troubleshooting](docs/TROUBLESHOOTING.md): fixes by symptom
* [Repository Structure](docs/REPOSITORY_STRUCTURE.md): what each file does
* [Changelog](docs/CHANGELOG.md): release notes
* [License](LICENSE): MIT

## Table of Contents

* [Cluster Architecture](#cluster-architecture)
  * [Host-Side Provisioning](#host-side-provisioning)
  * [Core Database Architecture](#core-database-architecture)
  * [CI Module](#ci-module)
  * [Observability Module](#observability-module)
  * [ETL Pipeline Module](#etl-pipeline-module)
  * [Machine Learning Module](#machine-learning-module)
* [Network Policy](#network-policy)
  * [Baseline](#baseline)
  * [Additional Policies](#additional-policies)
* [Official Documentation](#official-documentation)
  * [Host Side Tooling](#host-side-tooling)
  * [Core Architecture](#core-architecture)
  * [CI Module](#ci-module-1)
  * [Observability Module](#observability-module-1)
  * [ETL and ML Modules](#etl-and-ml-modules)
* [Cluster Operations](#cluster-operations)
  * [Bootstrap](#bootstrap)
  * [Cluster Lifecycle](#cluster-lifecycle)
  * [Database](#database)
  * [Development](#development)
* [Restoring the Database from SeaweedFS](#restoring-the-database-from-seaweedfs)

---

## Cluster Architecture

### Host-Side Provisioning

These tools must be installed or configured on the host machine to bootstrap, template, manage, and operate the cluster:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| Ansible | `ansible` `14.5.0` (`ansible-core` `2.21.5`), from `uv.lock` | Idempotent cluster bootstrap playbook and host setup (`ansible/data_cluster.yml`). `just bootstrap` runs it through `uv run` and installs the collections in `ansible/requirements.yml` first. |
| Flux CLI | `v2.9.6` (`fluxcd.io`) | Creates Flux's Git credentials during bootstrap (`flux create secret`), and inspects and reconciles Flux afterwards. |
| fzf | `fzf` | Interactive pod picker for `just fuzzypods`. |
| GitHub CLI (`gh`) | `gh` | Fallback GitHub authentication for automated repository access if a GitHub App is not configured. |
| GnuPG (`gpg`) | `gnupg` / `gnupg2` | Encrypts and decrypts the OpenBao unseal keyfile in `.local/openbao/`. |
| Helm | `v4.x` (`get-helm-4`) | Installs Cilium during bootstrap, before Flux exists, and reads chart metadata for `just preflight`. |
| Hubble CLI | `hubble` (`cilium/hubble` release) | Streams flows and policy verdicts from Hubble Relay (`just hubble`). |
| just | `just` | Command runner orchestrating cluster lifecycle, database, and dev recipes (`justfile`). |
| kubectl | `v1.37.1` (`KUBECTL_VERSION`, matching `K3S_VERSION`) | Kubernetes CLI for every cluster operation and recipe. The same version runs in-cluster as the `registry.k8s.io/kubectl` image in the Tekton Results init containers. |
| kubectl cnpg plugin | `1.30.1` (the CNPG operator version) | CloudNativePG status, backups, `psql` and restarts (`kubectl cnpg ...`). |
| OpenSSL | `openssl` | `just preflight` checks that it is installed. |
| OpenTofu | `1.12.6` (standalone binary) | Declarative secrets, PKI engine, and Kubernetes auth management in OpenBao (`terraform/openbao/`). |
| PostgreSQL Client (`psql`) | `postgresql-client` | Host CLI client for local database administration and connectivity testing. |
| uv | `astral-sh/uv` | Builds `.venv` from `uv.lock`, Python included; `just bootstrap` and the dev recipes run through it. |

### Core Database Architecture

These are the resources that make up the database core of the cluster. It is engineered to scale into demanding and complex workloads, and relies on open source software that is efficient, organized, and lightweight. The version numbers here serve as a reference for those in the manifests intended to be deployed live.

| Component | Version | Description |
| --- | --- | --- |
| Barman Cloud Plugin | `0.8.1` | WAL archiving and base backups for CNPG, via the `ObjectStore` resource rather than in-tree `spec.backup.barmanObjectStore`. |
| cert-manager | `1.21.2` | Manages local edge CA, provisions OpenBao TLS, and mints leaf certificates via `openbao-pki-issuer`. |
| Cilium | `1.20.2` | CNI; replaces k3s's default networking, eBPF routing/load-balancing in place of kube-proxy, serves the Gateway API. |
| CloudNativePG (CNPG) | `0.29.1` | Operator managing the PostgreSQL/PostGIS lifecycle: provisioning, reconciliation, hibernation, backup orchestration. |
| DNS (CoreDNS) | `v1.14.6` | k3s's own in-cluster CoreDNS (`kube-system`), extended with an `internal` zone via a `coredns-custom` ConfigMap (`infrastructure/coredns-custom/`). Resolves `*.internal` to the shared Gateway's IP for LAN clients, alongside its existing `*.svc.cluster.local` role for pods. |
| Flux | `v2.9.6` | GitOps controller; reconciles every `Kustomization` under `clusters/local/`, `dependsOn`-chained starting Gateway API CRDs → Cilium. Pinned by the committed `clusters/local/flux-system/gotk-components.yaml`, which `flux install --components=source-controller,kustomize-controller,helm-controller,notification-controller --network-policy=false --export` regenerates after a CLI upgrade. |
| Gateway | `v1.6.1` (CRDs) | One shared `Gateway` (`internal-gateway`) every tool attaches a `Route` to: an HTTPS listener (443, wildcard cert) for web UIs, a raw TCP listener (5432) for Postgres. |
| Gateway API | `v1.6.1` (CRDs) | Kubernetes-native API for describing traffic routing. `GatewayClass` names an implementation (e.g. Cilium); `Gateway` defines listeners (ports, protocols, hostnames); `HTTPRoute`/`TCPRoute`/`TLSRoute`/`GRPCRoute`/`UDPRoute` attach to a Gateway and route traffic by protocol to backend Services; `ReferenceGrant` allows routes to reference backends in another namespace; `BackendTLSPolicy` configures TLS to a backend; `ListenerSet` lets a listener be shared/delegated across teams. |
| OpenBao (in-cluster) | `2.7.1` (chart `0.30.3`) | Secrets backend on PebbleDB storage; `just start` unseals it from the GPG-encrypted keyfile in `.local/openbao/`. Hosts KV secrets, Kubernetes Auth, 2-tier PKI engine (Root + Intermediate CA with RFC 5280 Name Constraints), and database secrets engine. |
| Headlamp | `0.45.0` | Cluster GUI; can be installed as a desktop app, or deployed within the cluster. Has a number of plugins that assist with cluster management. |
| Hubble | `v1.20.2` (Relay), `v0.13.6` (UI) | Cilium's network observability layer. Relay runs its own cert-manager mTLS trust domain; the `hubble` CLI reaches it at `localhost:4245` through a local redirect. |
| k3s | `v1.37.1+k3s1` | Core control plane and execution environment. `just bootstrap` installs `K3S_VERSION`; an existing node upgrades through the k3s installer with `INSTALL_K3S_VERSION`. k3s also bundles the Gateway API CRDs (its `gateway-api-crd` chart), so `GATEWAY_API_VERSION` follows k3s's bundled version. |
| [pgiscluster](https://pypi.org/project/pgiscluster/) | `0.2.0` | Python package providing `HostDBConnector`/`HostAdminDBConnector` classes for connecting ETL/ML job code to the database. |
| PostgreSQL / PostGIS image | `18.6-3.6.4-system-trixie` | Image the CNPG `Cluster` runs (`18.6` PostgreSQL, `3.6.4` PostGIS). |
| Prometheus Operator CRDs | `32.0.1` (chart, operator `v0.94.1`; planned for 3.0) | `ServiceMonitor`, `PodMonitor` and the other Prometheus Operator CRDs, installed in the core so the monitors beside core components keep resolving while observability is off. Pinned to the operator version kube-prometheus-stack ships. |
| SeaweedFS | `4.48.0` | In-cluster S3-compatible object store with TLS issued by `openbao-pki-issuer`. CNPG streams WAL and writes scheduled base backups to it over HTTPS (`https://seaweedfs-s3.databases.svc:9000`). |
| OpenBao Database & PKI Engines | Same as OpenBao | Issues Postgres login roles on demand (3h default TTL / 24h max) and issues 30-day TLS certificates via cert-manager. |
| External Secrets Operator (ESO) | `2.12.0` | Syncs OpenBao values into Kubernetes `Secret`s; refreshes static secrets hourly and generates new dynamic database credentials every 2h. |

### CI Module

Tekton runs the cluster's CI: Pipelines execute the work, Triggers start runs from events, and Results keeps run history in the core database.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| Tekton Pipelines | `v1.15.3` (via Tekton Operator `v0.81.2`) | Cluster-native CI engine with Pipelines/Tasks/PipelineRuns from CRDs. | Woodpecker CI, if a single self-hosted binary with GitHub-Actions-like YAML is preferred over Tekton's CRD model. |
| Tekton Triggers | `v0.37.1` (via Tekton Operator `v0.81.2`) | EventListener reacting to GitHub webhook events (push/PR), starting the matching PipelineRun. | GitHubs Actions is the standard for ci workflow, and can offer basic complimentary CI services on github. |
| Tekton Results | `v0.20.0` (via Tekton Operator `v0.81.2`) | Keeps PipelineRun and TaskRun records in the PostGIS `tekton_results` database after the pruner removes the runs, for `TEKTON_RESULTS_RETENTION`. Each pod start gets its own OpenBao database login. | The pruner alone, if history past the last `TEKTON_PRUNER_KEEP` runs isn't needed. Loki with a log forwarder for run logs, which Results doesn't store here. |

### Observability Module

Metrics, logs and runtime security for the whole cluster, switched on when debugging resource spikes, workload bottlenecks or suspicious behavior.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| Grafana Alloy | `v1.20.1` (chart `1.13.1`; planned for 3.0) | DaemonSet that tails pod logs through the Kubernetes API and ships them to Loki, TaskRun pod logs included. | Fluent Bit, a lighter log forwarder that also ships to Loki. |
| kube-prometheus-stack | `92.3.0` (chart, operator `v0.94.1`; planned for 3.0) | Deploys the industry-standard Prometheus, Grafana, and Alertmanager bundle for comprehensive metric aggregation and dashboarding, to debug resource spikes and workload bottlenecks. | `victoria-metrics-k8s-stack` uses VictoriaMetrics instead of Prometheus. Lower footprint, but more work to customize. |
| Loki | `v3.7.8` (chart `18.15.1`; planned for 3.0) | Log aggregation and processing, paired with kube-prometheus-stack to round out metrics + logs observability. | `VictoriaLogs` particularly if using the same stack as above. |
| Tetragon | `v1.7.1` (chart `1.7.1`; planned for 3.0) | Real-time, eBPF-based detection of anomalous behavior at the syscall level. Detects unexpected shell spawns inside a container, unauthorized reads of sensitive files, privilege escalation attempts. Shares the eBPF datapath Cilium uses, and comes from the same developer. | Falco is the more battle-tested choice, with a larger existing rule/policy ecosystem, if Tetragon's policy library proves too thin in practice. |

### ETL Pipeline Module

The ETL pipeline rollout focuses on data ingestion, declarative orchestration, and in-database transformation. Python's modules allow for each step in ETL to be accomplished within Python:

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| dbt (dbt-core, dbt-postgres) | `1.12.5` (dbt-core), `1.11.0` (dbt-postgres); planned for 3.0 | Executes complex SQL-based transformations natively within the CloudNativePG database, ensuring compute remains close to the data. | Apache Spark is the industry standard for massive-scale, distributed data transformation, but heavier and more appropriate for spinning up dedicated compute clusters rather than pushing compute down in a bare-metal development environment. and more appropriate for pushing compute down into a local database rather than spinning up dedicated compute clusters. |
| dlt | `1.31.0` (planned for 3.0) | Open-source Python library (data load tool) for building declarative data pipelines that load data from REST APIs, databases, and other sources. | Airbyte is a fallback option if a UI-driven ecosystem of pre-built connectors is eventually needed. |
| Prefect | `3.8.8` (planned for 3.0) | Replaces heavy legacy schedulers with a Python-native, highly observable orchestration engine for triggering data pipelines. | Apache Airflow is the industry-standard alternative for data orchestration, but its heavy infrastructure footprint (requiring multiple dedicated scheduler, webserver, and worker pods) makes it overly complex for a lightweight local cluster. |

### Machine Learning Module

The ML expansion focuses on managing experiment tracking, environment provisioning, and model serving, utilizing strictly open-source (Apache 2.0) tooling. Not yet in the repo directory; ordered alphabetically by component name.

| Component | Version | Description | Alternatives |
| --- | --- | --- | --- |
| BentoML | `v1.4.39` (planned for 3.0) | Packages models into self-contained, production-ready services using a Python-first framework. | KServe offers Kubernetes-native inference features like scale-to-zero or advanced GPU scheduling. |
| Flux image automation | `v1.2.5` (image-reflector and image-automation controllers, Flux `v2.9.6`; planned for 3.0) | Watches the registry for new model image tags and pushes each one to the `flux/image-updates` branch, so a merged pull request rolls out the new model. The controllers join the core Flux install. | Bumping the image tag by hand in a pull request. |
| MLflow | `3.17.0` (planned for 3.0) | Tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in the cluster's SeaweedFS object store. | Kubeflow is the standard for teams prepared for, and heavily invested in, Kubernetes orchestration. |
| zot | `v2.1.22` (chart `0.1.128`; planned for 3.0) | In-cluster OCI registry for model service images, storing them in a SeaweedFS bucket. The release Pipeline pushes to it, and containerd pulls from it through a local redirect. | Harbor, a fuller registry with a UI, scanning and replication, at a much larger footprint. |

---

## Network Policy

### Baseline

Every pod gets these policies, kept in `infrastructure/cilium/`, `infrastructure/gateway/` and `infrastructure/namespaces/`.

1. Pods send freely to other pods, to DNS through CoreDNS, and to the Kubernetes API on port 6443.
2. A pod accepts traffic from its own namespace, the kubelet and the Gateway.
3. The Gateway carries traffic from the LAN and the node into the cluster. Pods talk to each other directly.

* New namespace → add it with its same-namespace rule in `namespaces.yaml`
* Reached from the LAN → add a Gateway route

### Additional Policies

Other traffic needs a policy that names its ports and lives with the component that needs it.

* Called from another namespace → incoming rule on the receiving pod, naming the caller. Sensitive services (OpenBao, Postgres) also check the caller's credentials.
* Calls an internet site → outgoing rule on the sending pod, naming the domain.
* Calls a host port → outgoing rule on the sending pod.

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
| OpenBao | [https://openbao.org/docs/](https://openbao.org/docs/) |
| Headlamp | [https://headlamp.dev/docs/latest/](https://headlamp.dev/docs/latest/) |
| Hubble | [https://docs.cilium.io/en/stable/observability/hubble/](https://docs.cilium.io/en/stable/observability/hubble/) |
| k3s | [https://docs.k3s.io/](https://docs.k3s.io/) |
| pgiscluster | [https://pypi.org/project/pgiscluster/](https://pypi.org/project/pgiscluster/) |
| PostGIS Extension | [https://postgis.net/documentation/](https://postgis.net/documentation/) |
| PostgreSQL | [https://www.postgresql.org/docs/current/](https://www.postgresql.org/docs/current/) |
| Prometheus Operator CRDs | [https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-operator-crds](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-operator-crds) |
| SeaweedFS | [https://github.com/seaweedfs/seaweedfs/wiki](https://github.com/seaweedfs/seaweedfs/wiki) |
| OpenBao Database Secrets Engine | [https://openbao.org/docs/secrets/databases/](https://openbao.org/docs/secrets/databases/) |
| OpenBao PKI Secrets Engine | [https://openbao.org/docs/secrets/pki/](https://openbao.org/docs/secrets/pki/) |
| External Secrets Operator | [https://external-secrets.io/latest/](https://external-secrets.io/latest/) |

### CI Module

| Component | Documentation Link |
| --- | --- |
| Tekton Pipelines | [https://tekton.dev/docs/pipelines/](https://tekton.dev/docs/pipelines/) |
| Tekton Triggers | [https://tekton.dev/docs/triggers/](https://tekton.dev/docs/triggers/) |
| Tekton Results | [https://tekton.dev/docs/results/](https://tekton.dev/docs/results/) |

### Observability Module

| Component | Documentation Link |
| --- | --- |
| Grafana Alloy | [https://grafana.com/docs/alloy/latest/](https://grafana.com/docs/alloy/latest/) |
| kube-prometheus-stack | [https://github.com/prometheus-operator/kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) |
| Loki | [https://grafana.com/docs/loki/latest/](https://grafana.com/docs/loki/latest/) |
| Tetragon | [https://tetragon.io/](https://tetragon.io/) |

### ETL and ML Modules

| Component | Documentation Link |
| --- | --- |
| BentoML | [https://docs.bentoml.com/](https://docs.bentoml.com/) |
| dbt | [https://docs.getdbt.com/](https://docs.getdbt.com/) |
| dlt | [https://dlthub.com/docs](https://dlthub.com/docs) |
| Flux image automation | [https://fluxcd.io/flux/guides/image-update/](https://fluxcd.io/flux/guides/image-update/) |
| MLflow | [https://mlflow.org/docs/latest/index.html](https://mlflow.org/docs/latest/index.html) |
| Prefect | [https://docs.prefect.io/](https://docs.prefect.io/) |
| zot | [https://zotregistry.dev/](https://zotregistry.dev/) |

---

## Cluster Operations

Organized to match the justfile's own section layout (`just --list --unsorted` shows every recipe in file order).

### Bootstrap

One-time, first-install setup: see [Installation](docs/INSTALLATION.md) for Requirements and what the script does.

| Command | Operation | When |
| --- | --- | --- |
| `just setup-firewall` | Configure host firewall rules | Before install; opens what Kubernetes and Cilium need in firewalld (Fedora) or ufw (Ubuntu) |
| `just preflight` | Run host readiness check | Verify host tooling, `gh` auth, firewall rules, and reserved IP range before install |
| `just bootstrap` (accepts flags like `--tags`, `--check`, `-v`) | Run full cluster bootstrap via Ansible | Provision k3s, Cilium, Flux, OpenBao, and apply initial OpenTofu secrets |

### Cluster Lifecycle

Start and stop the cluster each work session, check its health, and inspect or reach into it while it runs.

| Command | Operation | When |
| --- | --- | --- |
| `just start` | Start the cluster | Each work session; starts k3s, unseals OpenBao, wakes `postgis-cluster` from hibernation and resumes its scheduled backups |
| `just status` | Check overall cluster health | Post-install verification or periodic health check across Flux, Gateway/DNS, cert-manager, database, backups, SeaweedFS, and Hubble |
| `just stop` (`just stop --force` if a stuck stop needs it) | Stop the cluster | Each work session; gracefully hibernates CNPG PostgreSQL before shutting down k3s |
| `just uninstall` | Uninstall k3s and clear stale local state | Reinstalling from scratch; runs `k3s-uninstall.sh` and clears `.local/openbao`, local Postgres/Hubble caches, orphaned `terraform/openbao` state, and Cilium's persistent host files; reboot before the next `just bootstrap` |
| `just fuzzypods` | Interactively inspect a pod | Ad hoc troubleshooting; fuzzy-select a pod from all namespaces and describe it |
| `just gateway-check` (`just gateway-check <DOMAIN> [HOST]`) | Verify Gateway routing | Post-install verification or testing Gateway HTTPRoute and TLS edge certificates |
| `just hubble` (runs `hubble status`) / `just hubble observe --follow` | Run the Hubble CLI against Hubble Relay | Relay status, or real-time network and security flow inspection over mTLS |
| `just bao-ca` | Export OpenBao CA and print its address | OpenBao API and UI are at `https://127.0.0.1:8210` through a local redirect; exports the internal CA to `.local/openbao/certs/` |
| `just bao-shell` | Open interactive OpenBao shell | Direct `bao` CLI access inside `openbao-0` pod with a sanitized environment |

### Database

| Command | Operation | When |
| --- | --- | --- |
| `just db-connect` (`just db-connect localhost` from node) | Connect via psql (app role, host) | Application-level database access with OpenBao-issued dynamic credentials |
| `kubectl cnpg psql postgis-cluster -n databases` | Connect via psql (superuser, in-cluster) | Ad hoc direct administrative query access as `postgres` superuser |
| `just backup` | Trigger a manual DB backup | Before schema changes or risky migrations; writes backup to SeaweedFS S3 |
| `kubectl get scheduledbackup -n databases -o yaml \| grep -i suspend` | Check scheduled backup status | Confirming automated nightly backups are active (`suspend: false`) |
| `kubectl cnpg status postgis-cluster -n databases` | Verify CNPG cluster state | Detailed PostgreSQL replication, WAL archiving, and instance diagnostics |

### Development

| Command | Operation |
| --- | --- |
| `just setup` | Set up the dev environment (`install`, then `git-setup`) |
| `just install` | Install every dependency group and extra from the lockfile |
| `just update` | Update packages and the lockfile |
| `just git-setup` | Install the pre-commit hooks with `prek` |

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
