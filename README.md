# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster tailored for Data Science development using a PostgreSQL server with the PostGIS extension enabled. It provides a scalable foundation for data science projects, such as Extract, Transform, and Load (ETL) pipelines and Machine Learning (ML).

Four tools roll out this cluster:

* **Ansible:** Bootstraps the host and the cluster idempotently, in order: k3s, Cilium, cert-manager, trust-manager, OpenBao, OpenTofu, SPIRE, and the Flux controllers. Flux adopts each release Ansible installed.
* **Flux CD:** Reconciles the cluster against this Git repository, its single source of truth. Each Flux `Kustomization` applies one directory of manifests in the order its `dependsOn` chain sets, and third-party charts arrive as `HelmRelease`s.
* **OpenTofu:** Declares OpenBao's secrets engines, access policies, PKI and Kubernetes authentication (`terraform/openbao/`).
* **Tekton:** Tests the core after every change Flux applies to it, including the paths into it that the workstation uses.

Cluster secrets and security rely on an in-cluster OpenBao, unsealed at boot from a GPG-encrypted keyfile kept gitignored in this repo (`.local/openbao/`). Integrated with `cert-manager`, OpenBao's multi-tier Public Key Infrastructure (PKI) engine dynamically issues and rotates X.509 TLS certificates, and its database and secrets-aws engines issue the short-lived logins the Secrets Store CSI driver mirrors into Kubernetes `Secret`s every day.

Workloads are structured modularly to maximize compute efficiency on local hardware. The cluster maintains an always-on core database architecture, powered by PostgreSQL/PostGIS (CloudNativePG), Cilium eBPF networking and Gateway routing, and SeaweedFS S3-compatible storage. Specialized modules for testing, cluster observability, ETL data pipelines, and machine learning workflows can be deployed dynamically when performing specific data science tasks and torn down afterward to conserve memory and CPU.

Customizable VS Code DevContainer configurations are provided in `.devcontainer/` for both host-side cluster administration and in-cluster runtime workloads. The entire platform has been developed and tested on both **Ubuntu** and **Fedora**.

## Documentation

* [Access Policy](docs/ACCESSPOLICY.md): permissions, credentials and certificate trust
* [Backups and Restore](docs/BACKUPS_RESTORE.md): restoring the database from SeaweedFS
* [Changelog](docs/CHANGELOG.md): release notes
* [Cluster Operations](docs/OPERATIONS.md): every `just` recipe and the commands beside them
* [Installation](docs/INSTALLATION.md): first-time setup
* [License](LICENSE): MIT
* [Network Policy](docs/NETWORKPOLICY.md): baseline and how to allow traffic
* [Repository Structure](docs/REPOSITORY_STRUCTURE.md): what each file does
* [Troubleshooting](docs/TROUBLESHOOTING.md): fixes by symptom
* [Verification](docs/VERIFICATION.md): checks after the bootstrap

## Table of Contents

* [Cluster Architecture](#cluster-architecture)
  * [Host-Side Provisioning](#host-side-provisioning)
  * [Core Architecture](#core-architecture)
  * [Tekton Module (TBD)](#tekton-module-tbd)
  * [Observability Module (TBD)](#observability-module-tbd)
  * [ETL Pipeline Module (TBD)](#etl-pipeline-module-tbd)
  * [Machine Learning Module (TBD)](#machine-learning-module-tbd)
* [Official Documentation](#official-documentation)
  * [Host Side Tooling](#host-side-tooling)
  * [Core Architecture](#core-architecture-1)
  * [Tekton Module](#tekton-module)
  * [Observability Module](#observability-module)
  * [ETL and ML Modules](#etl-and-ml-modules)

---

## Cluster Architecture

### Host-Side Provisioning

These tools must be installed or configured on the host machine to bootstrap, template, manage, and operate the cluster.

**uv** runs the Python tooling, and **Ansible** bootstraps the cluster with **Helm**, the **Flux CLI** and **OpenTofu**. The **GitHub CLI** is the fallback for repository access:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| Ansible | `ansible` `14.5.0` (`ansible-core` `2.21.5`), from `uv.lock` | Idempotent cluster bootstrap playbook and host setup (`dragonbishop.cluster.data_cluster`). `just bootstrap` runs it through `uv run` and first installs the collections that the `dragonbishop.cluster` `galaxy.yml` depends on. |
| Flux CLI | `v2.10.0` (`fluxcd.io`) | Creates Flux's Git credentials during bootstrap (`flux create secret`), and inspects and reconciles Flux afterwards. |
| GitHub CLI (`gh`) | `gh` | Fallback GitHub authentication for automated repository access if a GitHub App is not configured. |
| Helm | `v4.x` (`get-helm-4`) | Installs Cilium during bootstrap, before Flux exists, and reads chart metadata for `just preflight`. |
| OpenTofu | `1.13.1` (standalone binary) | Declarative secrets, PKI engine, and Kubernetes auth management in OpenBao (`terraform/openbao/`). |
| uv | `astral-sh/uv` | Builds `.venv` from `uv.lock`, Python included; `just bootstrap` and the dev recipes run through it. |

**GnuPG** protects the OpenBao keyfile, and **Git** initializes a source download for `just setup`:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| Git | `git` | `just setup` runs `git init` in a source download without `.git`; the GitHub CLI fallback reads the `origin` URL. |
| GnuPG (`gpg`) | `gnupg` / `gnupg2` | Encrypts and decrypts the OpenBao unseal keyfile in `.local/openbao/`. |

**just** runs every recipe, and **kubectl**, the **kubectl cnpg plugin**, the **Tekton CLI**, **Headlamp** and **fzf** inspect and operate the running cluster:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| fzf | `fzf` | Interactive pod picker for `just fuzzypods`. |
| Headlamp | `0.45.0` (desktop app) | Cluster GUI on the host, reading `~/.kube/config`. Its plugins assist with cluster management. |
| just | `just` | Command runner orchestrating cluster lifecycle, database, and dev recipes (`justfile`). |
| kubectl | `v1.37.2` <!-- renovate: datasource=github-releases depName=kubernetes/kubernetes --> (`KUBECTL_VERSION`, matching `K3S_VERSION`) | Kubernetes CLI for every cluster operation and recipe. |
| kubectl cnpg plugin | `1.30.1` (the CNPG operator version) | CloudNativePG status, backups, restarts, and `psql` sessions inside the primary pod (`kubectl cnpg ...`), so the host needs no PostgreSQL client. |
| Tekton CLI (`tkn`) | `tektoncd-cli` | Lists and follows PipelineRuns, TaskRuns and their logs. |

**pgiscluster** reaches the database from the host:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| [pgiscluster](https://pypi.org/project/pgiscluster/) | `0.2.0`, from `uv.lock` | Python package providing `HostDBConnector`/`HostAdminDBConnector` classes for connecting ETL/ML job code on the host to the database. |

### Core Architecture

The core is always on and holds every piece of the cluster's state. It relies on open source software that is efficient, organized, and lightweight. The version numbers here serve as a reference for those in the manifests intended to be deployed live.

**k3s** runs the node, **Flux** reconciles everything on it from this repository, and the **Prometheus Operator CRDs** keep the core's monitors resolving:

| Component | Version | Description |
| --- | --- | --- |
| Flux | `v2.10.0` | GitOps controller; reconciles every `Kustomization` under `clusters/local/`, `dependsOn`-chained starting Gateway API CRDs → Cilium. Pinned by the committed `clusters/local/flux-system/gotk-components.yaml`, which `flux install --components=source-controller,kustomize-controller,helm-controller,notification-controller --network-policy=false --export` regenerates after a CLI upgrade. |
| k3s | `v1.37.1+k3s1` <!-- renovate: datasource=github-releases depName=k3s-io/k3s --> | Core control plane and execution environment. `just bootstrap` installs `K3S_VERSION`; an existing node upgrades through the k3s installer with `INSTALL_K3S_VERSION`. k3s also bundles the Gateway API CRDs (its `gateway-api-crd` chart), so the vendored `infrastructure/gateway-api-crds/standard-install.yaml` follows k3s's bundled version. |
| Prometheus Operator CRDs | `32.0.1` (chart, operator `v0.94.1`; planned for 3.0) | `ServiceMonitor`, `PodMonitor` and the other Prometheus Operator CRDs, installed in the core so the monitors beside core components keep resolving while observability is off. Pinned to the operator version kube-prometheus-stack ships. |

**Cilium** carries the cluster's traffic, one shared **Gateway** built on the **Gateway API** takes every request from the LAN, **CoreDNS** resolves its names, and **Hubble** shows its flows:

| Component | Version | Description |
| --- | --- | --- |
| Cilium | `1.20.3` <!-- renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io --> | CNI; replaces k3s's default networking, eBPF routing/load-balancing in place of kube-proxy, serves the Gateway API. |
| DNS (CoreDNS) | `v1.14.6` | k3s's own in-cluster CoreDNS (`kube-system`), extended with a `cluster.internal` zone via a `coredns-custom` ConfigMap (`infrastructure/cilium/coredns-custom.yaml`). Resolves `*.cluster.internal` to the shared Gateway's IP for LAN clients, alongside its existing `*.svc.cluster.local` role for pods. |
| Gateway | `v1.6.1` (CRDs) | One shared `Gateway` (`internal-gateway`): HTTPS (443, wildcard cert) for web UIs and raw TCP (5432) for Postgres. [Adding an HTTPS service](docs/NETWORKPOLICY.md#adding-an-https-service) needs a route and a receiver rule; approve its namespace once. |
| Gateway API | `v1.6.1` (CRDs) | Kubernetes-native API for describing traffic routing. `GatewayClass` names an implementation (e.g. Cilium); `Gateway` defines listeners (ports, protocols, hostnames); `HTTPRoute`/`TCPRoute`/`TLSRoute`/`GRPCRoute`/`UDPRoute` attach to a Gateway and route traffic by protocol to backend Services; `ReferenceGrant` allows routes to reference backends in another namespace; `BackendTLSPolicy` configures TLS to a backend; `ListenerSet` lets a listener be shared/delegated across teams. |
| Hubble | `v1.20.2` (Relay), `v0.13.6` (UI) | Cilium's network observability layer. Relay runs its own cert-manager mTLS trust domain. |

**OpenBao** holds the cluster's secrets and issues its certificates and logins through its **Database & PKI Engines** and its **secrets-aws plugin**. **cert-manager** delivers the certificates into Kubernetes, and the **Secrets Store CSI Driver** with the **OpenBao CSI Provider** delivers the logins:

| Component | Version | Description |
| --- | --- | --- |
| cert-manager | `v1.21.2` <!-- renovate: datasource=helm depName=cert-manager registryUrl=https://charts.jetstack.io --> | Manages local edge CA, provisions OpenBao TLS, and mints leaf certificates via `openbao-pki-issuer`. |
| OpenBao (in-cluster) | `2.7.1` <!-- renovate: datasource=docker depName=openbao/openbao --> (chart `0.30.4` <!-- renovate: datasource=helm depName=openbao registryUrl=https://openbao.github.io/openbao-helm -->) | Secrets backend on PebbleDB storage; `just start` unseals it from the GPG-encrypted keyfile in `.local/openbao/`. Hosts KV secrets, Kubernetes Auth, 2-tier PKI engine (Root + Intermediate CA with RFC 5280 Name Constraints), and database secrets engine. |
| OpenBao Database & PKI Engines | Same as OpenBao | Issues Postgres login roles on demand (3h default TTL / 24h max) and issues 30-day TLS certificates via cert-manager. |
| OpenBao CSI Provider | `2.0.3` (via OpenBao chart `0.30.4` <!-- renovate: datasource=helm depName=openbao registryUrl=https://openbao.github.io/openbao-helm -->) | DaemonSet in `openbao` that logs in to OpenBao with each mounting pod's ServiceAccount token and reads the logins its `SecretProviderClass` names. |
| OpenBao secrets-aws plugin | `v0.3.2` <!-- renovate: datasource=docker depName=ghcr.io/openbao/openbao-plugin-secrets-aws --> | Mounted at `seaweedfs/`; creates a SeaweedFS IAM user with a key pair scoped to the backup bucket for each read, with a 4-day lease. OpenBao downloads it at startup. |
| Secrets Store CSI Driver | `1.6.1` <!-- renovate: datasource=helm depName=secrets-store-csi-driver registryUrl=https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts --> | DaemonSet in `kube-system` that mounts provider-fetched logins into pods, mirrors them into Kubernetes `Secret`s and reads them again every `CREDENTIAL_ROTATION_INTERVAL`. |

**CloudNativePG** runs the **PostgreSQL / PostGIS image**, and the **Barman Cloud Plugin** writes its backups to **SeaweedFS**:

| Component | Version | Description |
| --- | --- | --- |
| Barman Cloud Plugin | `0.8.1` <!-- renovate: datasource=helm depName=plugin-barman-cloud registryUrl=https://cloudnative-pg.github.io/charts --> | WAL archiving and base backups for CNPG, via the `ObjectStore` resource rather than in-tree `spec.backup.barmanObjectStore`. |
| CloudNativePG (CNPG) | `0.29.1` <!-- renovate: datasource=helm depName=cloudnative-pg registryUrl=https://cloudnative-pg.github.io/charts --> | Operator managing the PostgreSQL/PostGIS lifecycle: provisioning, reconciliation, hibernation, backup orchestration. |
| PostgreSQL / PostGIS image | `18.6-3.6.4-system-trixie` | Image the CNPG `Cluster` runs (`18.6` PostgreSQL, `3.6.4` PostGIS). |
| SeaweedFS | `4.51.0` <!-- renovate: datasource=helm depName=seaweedfs registryUrl=https://seaweedfs.github.io/seaweedfs/helm --> | In-cluster S3-compatible object store with TLS issued by `openbao-pki-issuer`. CNPG streams WAL and writes scheduled base backups to it over HTTPS (`https://seaweedfs-s3.seaweedfs.svc:9000`). Its IAM API lets OpenBao create and delete Barman's key pairs. |

The **Tekton Operator** installs **Tekton Pipelines**, **Tekton Triggers** and **Tekton Results**, which run **`core-test`** after every change Flux applies to the core. **Zot** holds the cluster's images. Tekton's controllers, Results and their Secrets live in `tekton`, the EventListener and Triggers in `tekton-triggers`, and Tasks, Pipelines and their runs in `tekton-pipelines`:

| Component | Version | Description |
| --- | --- | --- |
| `core-test` | `infrastructure/tekton-pipelines/pipelines/core-test/` (planned for 3.0) | The Pipeline that checks the live core after every change Flux applies to it from `main`: Flux, workloads, Gateway TLS, OpenBao, a dynamic database login, backups and Hubble drops. |
| Tekton Operator | `v0.81.2` <!-- renovate: datasource=github-releases depName=tektoncd/operator --> | Installs Pipelines, Triggers, Results and the pruner from one `TektonConfig`. |
| Tekton Pipelines | `v1.15.3` (via Tekton Operator `v0.81.2` <!-- renovate: datasource=github-releases depName=tektoncd/operator -->) | Cluster-native CI engine with Pipelines/Tasks/PipelineRuns from CRDs. |
| Tekton Results | `v0.20.0` (via Tekton Operator `v0.81.2` <!-- renovate: datasource=github-releases depName=tektoncd/operator -->) | Keeps PipelineRun and TaskRun records in the PostGIS `tekton_results` database after the pruner removes the runs, for `TEKTON_RESULTS_RETENTION`. Each pod reads its database login from Secret `tekton-results-postgres` at start, which the Secrets Store CSI driver fills from the API pod's mount. |
| Tekton Triggers | `v0.37.1` (via Tekton Operator `v0.81.2` <!-- renovate: datasource=github-releases depName=tektoncd/operator -->) | The `flux-events` EventListener (planned for 3.0) turns events from Flux's notification-controller into PipelineRuns, so a merge to `main` starts `core-test`. |
| Zot | `v2.1.22` (chart `0.1.128`; planned for 3.0) | In-cluster OCI registry and pull-through cache for every public registry the node pulls from, storing images in the `zot` SeaweedFS bucket. The Tekton module builds images into it, and containerd pulls through it. |

### Tekton Module (TBD)

The Tekton module tests everything outside the core: a pushed branch against the live cluster, each module's test Pipeline, and the images in `images/`. `just tekton on|off` switches it, and its run history stays in Tekton Results.

| Component | Version | Description |
| --- | --- | --- |
| Buildah (`buildah-ns` catalog Task) | `0.8.0` (planned for 3.0) | Builds each `images/<name>/` into Zot in the `image-build` and `test` Pipelines. |
| skopeo (`skopeo-copy` catalog Task) | `0.4.0` (planned for 3.0) | Copies a tested image digest from Zot to ghcr.io in the `image-publish` Pipeline. |
| Trivy (`trivy-scanner` catalog Task) | `0.2.0` (planned for 3.0) | Scans each built image; `image-build` fails on a CRITICAL finding. |
| ZAP (`zaproxy/zap-stable`) | `2.17.0` (planned for 3.0) | Scans every HTTP route the test Pipelines reach: passive checks on each test run, and active attacks on the throwaway cluster `e2e.yml` builds. |

### Observability Module (TBD)

Metrics, logs and runtime security for the whole cluster, switched on when debugging resource spikes, workload bottlenecks or suspicious behavior.

| Component | Version | Description |
| --- | --- | --- |
| Grafana Alloy | `v1.20.1` (chart `1.13.1`; planned for 3.0) | DaemonSet that tails pod logs through the Kubernetes API and ships them to Loki, TaskRun pod logs included. |
| kube-prometheus-stack | `92.3.0` (chart, operator `v0.94.1`; planned for 3.0) | Deploys the industry-standard Prometheus, Grafana, and Alertmanager bundle for comprehensive metric aggregation and dashboarding, to debug resource spikes and workload bottlenecks. |
| Loki | `v3.7.8` (chart `18.15.1`; planned for 3.0) | Log aggregation and processing, paired with kube-prometheus-stack to round out metrics + logs observability. |
| Tetragon | `v1.7.1` (chart `1.7.1`; planned for 3.0) | Real-time, eBPF-based detection of anomalous behavior at the syscall level. Detects unexpected shell spawns inside a container, unauthorized reads of sensitive files, privilege escalation attempts. Shares the eBPF datapath Cilium uses, and comes from the same developer. |

### ETL Pipeline Module (TBD)

The ETL pipeline rollout focuses on data ingestion, declarative orchestration, and in-database transformation. Python's modules allow for each step in ETL to be accomplished within Python:

| Component | Version | Description |
| --- | --- | --- |
| dbt (dbt-core, dbt-postgres) | `1.12.5` (dbt-core), `1.11.0` (dbt-postgres); planned for 3.0 | Executes complex SQL-based transformations natively within the CloudNativePG database, ensuring compute remains close to the data. |
| dlt | `1.31.0` (planned for 3.0) | Open-source Python library (data load tool) for building declarative data pipelines that load data from REST APIs, databases, and other sources. |
| Prefect | `3.8.8` (planned for 3.0) | Python-native, observable orchestration engine for triggering data pipelines. |

### Machine Learning Module (TBD)

The ML expansion focuses on managing experiment tracking, environment provisioning, and model serving, utilizing strictly open-source (Apache 2.0) tooling. Not yet in the repo directory; ordered alphabetically by component name.

| Component | Version | Description |
| --- | --- | --- |
| BentoML | `v1.4.39` (planned for 3.0) | Packages models into self-contained, production-ready services using a Python-first framework. |
| MLflow | `3.17.0` (planned for 3.0) | Tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in the cluster's SeaweedFS object store. |

---

## Official Documentation

### Host Side Tooling

| Component | Documentation Link |
| --- | --- |
| Ansible | [https://docs.ansible.com/](https://docs.ansible.com/) |
| Flux CLI | [https://fluxcd.io/flux/cmd/](https://fluxcd.io/flux/cmd/) |
| GitHub CLI (`gh`) | [https://cli.github.com/manual/](https://cli.github.com/manual/) |
| Helm | [https://helm.sh/docs/](https://helm.sh/docs/) |
| OpenTofu | [https://opentofu.org/docs/](https://opentofu.org/docs/) |
| uv | [https://docs.astral.sh/uv/](https://docs.astral.sh/uv/) |

| Component | Documentation Link |
| --- | --- |
| Git | [https://git-scm.com/doc](https://git-scm.com/doc) |
| GnuPG (`gpg`) | [https://www.gnupg.org/documentation/](https://www.gnupg.org/documentation/) |

| Component | Documentation Link |
| --- | --- |
| fzf | [https://junegunn.github.io/fzf/](https://junegunn.github.io/fzf/) |
| Headlamp | [https://headlamp.dev/docs/latest/](https://headlamp.dev/docs/latest/) |
| just | [https://just.systems/man/en/](https://just.systems/man/en/) |
| kubectl | [https://kubernetes.io/docs/reference/kubectl/](https://kubernetes.io/docs/reference/kubectl/) |
| kubectl cnpg plugin | [https://cloudnative-pg.io/documentation/current/kubectl-plugin/](https://cloudnative-pg.io/documentation/current/kubectl-plugin/) |
| Tekton CLI (`tkn`) | [https://tekton.dev/docs/cli/](https://tekton.dev/docs/cli/) |

| Component | Documentation Link |
| --- | --- |
| pgiscluster | [https://pypi.org/project/pgiscluster/](https://pypi.org/project/pgiscluster/) |

### Core Architecture

| Component | Documentation Link |
| --- | --- |
| Flux | [https://fluxcd.io/flux/](https://fluxcd.io/flux/) |
| k3s | [https://docs.k3s.io/](https://docs.k3s.io/) |
| Prometheus Operator CRDs | [https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-operator-crds](https://github.com/prometheus-community/helm-charts/tree/main/charts/prometheus-operator-crds) |

| Component | Documentation Link |
| --- | --- |
| Cilium | [https://docs.cilium.io/](https://docs.cilium.io/) |
| CoreDNS | [https://coredns.io/manual/toc/](https://coredns.io/manual/toc/) |
| Gateway API | [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/) |
| Hubble | [https://docs.cilium.io/en/stable/observability/hubble/](https://docs.cilium.io/en/stable/observability/hubble/) |

| Component | Documentation Link |
| --- | --- |
| cert-manager | [https://cert-manager.io/docs/](https://cert-manager.io/docs/) |
| OpenBao | [https://openbao.org/docs/](https://openbao.org/docs/) |
| OpenBao Database Secrets Engine | [https://openbao.org/docs/secrets/databases/](https://openbao.org/docs/secrets/databases/) |
| OpenBao PKI Secrets Engine | [https://openbao.org/docs/secrets/pki/](https://openbao.org/docs/secrets/pki/) |
| OpenBao secrets-aws plugin | [https://github.com/openbao/openbao-plugins/tree/main/secrets/aws](https://github.com/openbao/openbao-plugins/tree/main/secrets/aws) |
| OpenBao CSI Provider | [https://openbao.org/docs/platform/k8s/csi/](https://openbao.org/docs/platform/k8s/csi/) |
| Secrets Store CSI Driver | [https://secrets-store-csi-driver.sigs.k8s.io/](https://secrets-store-csi-driver.sigs.k8s.io/) |

| Component | Documentation Link |
| --- | --- |
| Barman Cloud Plugin | [https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/) |
| CloudNativePG | [https://cloudnative-pg.io/docs](https://cloudnative-pg.io/docs) |
| CNPG Certificates | [https://cloudnative-pg.io/documentation/current/certificates/](https://cloudnative-pg.io/documentation/current/certificates/) |
| CNPG Hibernation | [https://cloudnative-pg.io/documentation/current/declarative_hibernation/](https://cloudnative-pg.io/documentation/current/declarative_hibernation/) |
| PostGIS Extension | [https://postgis.net/documentation/](https://postgis.net/documentation/) |
| PostgreSQL | [https://www.postgresql.org/docs/current/](https://www.postgresql.org/docs/current/) |
| SeaweedFS | [https://github.com/seaweedfs/seaweedfs/wiki](https://github.com/seaweedfs/seaweedfs/wiki) |

| Component | Documentation Link |
| --- | --- |
| Tekton Operator | [https://tekton.dev/docs/operator/](https://tekton.dev/docs/operator/) |
| Tekton Pipelines | [https://tekton.dev/docs/pipelines/](https://tekton.dev/docs/pipelines/) |
| Tekton Results | [https://tekton.dev/docs/results/](https://tekton.dev/docs/results/) |
| Tekton Triggers | [https://tekton.dev/docs/triggers/](https://tekton.dev/docs/triggers/) |
| Zot | [https://zotregistry.dev/](https://zotregistry.dev/) |

### Tekton Module

| Component | Documentation Link |
| --- | --- |
| Buildah | [https://buildah.io/](https://buildah.io/) |
| skopeo | [https://github.com/containers/skopeo](https://github.com/containers/skopeo) |
| Trivy | [https://trivy.dev/](https://trivy.dev/) |
| ZAP | [https://www.zaproxy.org/docs/](https://www.zaproxy.org/docs/) |

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
| MLflow | [https://mlflow.org/docs/latest/index.html](https://mlflow.org/docs/latest/index.html) |
| Prefect | [https://docs.prefect.io/](https://docs.prefect.io/) |
