# ⎈ k3s Data Science Cluster

This repository provisions a self-contained local Kubernetes cluster for data science development, designed to run ETL pipelines and machine learning workloads on a local workstation. Its core database is PostgreSQL with the PostGIS extension on CloudNativePG, backed by SeaweedFS object storage for database backups, Loki logs and OCI registry images. Prometheus, Grafana and Tetragon provide metrics, alerting and security event visibility across the full stack.

The cluster runs production-quality infrastructure on a single node. Ansible bootstraps the host and installs each component in order, then Flux takes over and reconciles every component from this Git repository. Cilium enforces network policy at the eBPF layer, and Tekton tests the core after every change Flux applies.

OpenBao is the cluster's secrets authority and PKI root, with its secrets engines, access policies and PKI configuration declared by OpenTofu. It unseals itself from a static seal key in a Kubernetes `Secret`, drives cert-manager's certificate issuance, and supplies short-lived database and S3 credentials that the Secrets Store CSI driver delivers to workloads. SPIRE builds on that PKI chain, assigning SPIFFE cryptographic identities to workloads. Keep the seal key, recovery keys and root token in an external secret store.

VS Code DevContainers in `.devcontainer/` cover both host-side cluster management and in-cluster runtime workloads. The cluster has been developed and tested on Ubuntu and Fedora.

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
  * [Provisioning Tools](#provisioning-tools)
  * [Source Control](#source-control)
  * [Cluster Operation Tools](#cluster-operation-tools)
  * [Host Database Access](#host-database-access)
  * [Platform](#platform)
  * [Networking](#networking)
  * [Secrets, Certificates and Identity](#secrets-certificates-and-identity)
  * [Databases and Storage](#databases-and-storage)
  * [Testing](#testing)
  * [Observability](#observability)
  * [Workstation UIs](#workstation-uis)
* [Official Documentation](#official-documentation)
  * [Provisioning Tools](#provisioning-tools-1)
  * [Source Control](#source-control-1)
  * [Cluster Operation Tools](#cluster-operation-tools-1)
  * [Host Database Access](#host-database-access-1)
  * [Platform](#platform-1)
  * [Networking](#networking-1)
  * [Secrets, Certificates and Identity](#secrets-certificates-and-identity-1)
  * [Databases and Storage](#databases-and-storage-1)
  * [Testing](#testing-1)
  * [Observability](#observability-1)
  * [Workstation UIs](#workstation-uis-1)

---

## Cluster Architecture

The first four tables list host-side tools. The remaining tables describe the core cluster components. Version numbers here correspond to those in the manifests.

### Provisioning Tools

**uv** runs the Python tooling, and **Ansible** bootstraps the cluster with **Helm**, the **Flux CLI** and **OpenTofu**. The **GitHub CLI** is the fallback for repository access:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| Ansible | `ansible` `14.5.0` (`ansible-core` `2.21.5`), from `uv.lock` | Idempotent cluster bootstrap playbook and host setup (`dragonbishop.cluster.data_cluster`). `just bootstrap` runs it through `uv run` and first installs the collections that the `dragonbishop.cluster` `galaxy.yml` depends on. |
| Flux CLI | `flux2-cli` / `flux` (the `gotk-components.yaml` Flux Version) | Creates Flux's Git credentials during bootstrap (`flux create secret`), and inspects and reconciles Flux afterwards. |
| GitHub CLI (`gh`) | `gh` | Fallback GitHub authentication for automated repository access if a GitHub App is not configured. |
| Helm | `helm` | Installs Cilium during bootstrap, before Flux exists, and reads chart metadata for `just preflight`. |
| OpenTofu | `tofu` (OpenTofu's package repository) | Declarative secrets, PKI engine, and Kubernetes auth management in OpenBao (`terraform/openbao/`). |
| uv | `astral-sh/uv` | Builds `.venv` from `uv.lock`, Python included. `just bootstrap` and the dev recipes run through it. |

### Source Control

**Git** initializes a source download for `just setup`:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| Git | `git` | `just setup` runs `git init` in a source download that lacks `.git`. The GitHub CLI fallback reads the `origin` URL. |

### Cluster Operation Tools

**just** runs every recipe, and **kubectl**, the **kubectl cnpg plugin**, the **Tekton CLI**, **jq** and **fzf** inspect and operate the running cluster:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| fzf | `fzf` | Interactive pod picker for `just fuzzypods`. |
| jq | `jq` | Optional for alert and scrape summaries in `just status`. |
| just | `just` | Command runner orchestrating cluster lifecycle, database, and dev recipes (`justfile`). |
| kubectl | `v1.37.2` <!-- renovate: datasource=github-releases depName=kubernetes/kubernetes --> (`KUBECTL_VERSION`, matching `K3S_VERSION`, packaged per minor version) | Kubernetes CLI for every cluster operation and recipe. |
| kubectl cnpg plugin | `kubectl-cnpg` / krew (the CNPG operator's minor version) | CloudNativePG status, backups, restarts, and `psql` sessions that run inside the primary pod (`kubectl cnpg ...`). |
| Tekton CLI (`tkn`) | `tektoncd-cli` | Lists and follows PipelineRuns, TaskRuns and their logs, and follows the run `just core-test` starts. |

### Host Database Access

**pgiscluster** reaches the database from the host:

| Tool | Version / Package | Purpose |
| --- | --- | --- |
| pgiscluster | `0.2.0`, from `uv.lock` | Python package providing `HostDBConnector`/`HostAdminDBConnector` classes for connecting ETL/ML job code on the host to the database. |

### Platform

**k3s** runs the node with its bundled **metrics-server** and **local-path provisioner**, **Flux** reconciles everything on it from this repository, and the **Prometheus Operator CRDs** keep the core's monitors resolving:

| Component | Version | Description |
| --- | --- | --- |
| Flux | `v2.10.0` | GitOps controller. It reconciles every `Kustomization` under `clusters/local/`, `dependsOn`-chained starting Gateway API CRDs → Cilium. Pinned by the committed `clusters/local/flux-system/gotk-components.yaml`, which `flux install --components=source-controller,kustomize-controller,helm-controller,notification-controller --network-policy=false --export` regenerates after a CLI upgrade. |
| k3s | `v1.37.2+k3s1` <!-- renovate: datasource=github-releases depName=k3s-io/k3s --> | Core control plane and execution environment. `just bootstrap` installs `K3S_VERSION`. An existing node upgrades through the k3s installer with `INSTALL_K3S_VERSION`. k3s also bundles the Gateway API CRDs (its `gateway-api-crd` chart). The vendored `infrastructure/gateway/crds/standard-install.yaml` follows k3s's bundled version. |
| local-path provisioner | `v0.0.37` (bundled with k3s) | k3s's default `local-path` StorageClass. The PostgreSQL volumes use it (`POSTGRES_STORAGE_CLASS`). |
| metrics-server | `v0.9.0` (bundled with k3s) | Serves `kubectl top` and the resource metrics API from each kubelet. |
| Prometheus Operator CRDs | `93.3.1` (kube-prometheus-stack chart, operator `v0.95.2`, planned for 3.0) | `ServiceMonitor`, `PodMonitor` and the other Prometheus Operator CRDs. HelmRelease `prometheus-crds` installs and upgrades them from the kube-prometheus-stack chart with every component off, ahead of the cert-manager, OpenBao and Hubble monitors that use them. |

### Networking

**Cilium** carries the cluster's traffic, one shared **Gateway** built on the **Gateway API** takes every request from the LAN, **CoreDNS** resolves its names, and **Hubble** shows its flows, through Relay and Hubble UI:

| Component | Version | Description |
| --- | --- | --- |
| Cilium | `1.20.4` <!-- renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io --> | CNI. It replaces k3s's default networking, routes and load-balances with eBPF in place of kube-proxy, and serves the Gateway API. |
| DNS (CoreDNS) | `v1.14.6` | k3s's in-cluster CoreDNS in `kube-system`. ConfigMap `coredns-custom` (`infrastructure/cilium/lan/coredns-config.yaml`) adds a `cluster.internal` zone that resolves `*.cluster.internal` to the shared Gateway's IP for LAN clients. Pods still resolve `*.svc.cluster.local` through it. |
| Gateway | `v1.6.1` (CRDs) | One shared `Gateway` (`internal-gateway`): HTTPS (443, wildcard cert) for web UIs and raw TCP (5432) for Postgres. [Adding an HTTPS service](docs/NETWORKPOLICY.md#adding-an-https-service) needs a route and a receiver rule. Approve its namespace once. |
| Gateway API | `v1.6.1` (CRDs) | Kubernetes-native API for describing traffic routing. Its kinds are listed below. |
| Hubble | Same as Cilium | Cilium's network observability layer: flow visibility in the agent, DNS and drop metrics for Prometheus, and Relay, which gathers flows for Hubble UI over mTLS with certificates from `openbao-pki-issuer`. `just hubble` runs the Hubble CLI inside the agent. |
| Hubble UI | `v0.13.6` (via Cilium) | Service map and flow browser. Reached only from the workstation at `https://localhost:12000` (`just ui hubble`), through the HTTPS container in its own pod. |

The Gateway API's kinds:

* `GatewayClass` names an implementation, such as Cilium.
* `Gateway` defines listeners: ports, protocols and hostnames.
* Routes attach to a Gateway and send traffic to backend Services:
  * `HTTPRoute` for HTTP and HTTPS.
  * `GRPCRoute` for gRPC.
  * `TLSRoute` for TLS passed through by SNI.
  * `TCPRoute` for raw TCP.
  * `UDPRoute` for UDP.
* `ReferenceGrant` lets routes reference backends in another namespace.
* `BackendTLSPolicy` configures TLS to a backend.
* `ListenerSet` lets teams share or delegate a listener.

### Secrets, Certificates and Identity

**OpenBao** holds the cluster's secrets and issues its certificates and logins through its **Database & PKI Engines** and its **secrets-aws plugin**. **cert-manager** delivers the certificates into Kubernetes, **trust-manager** distributes the CA bundles, the **Secrets Store CSI Driver** with the **OpenBao CSI Provider** delivers the logins, and **SPIRE** gives workloads their identities:

| Component | Version | Description |
| --- | --- | --- |
| cert-manager | `v1.21.3` <!-- renovate: datasource=helm depName=cert-manager registryUrl=https://charts.jetstack.io --> | Issues every certificate in the cluster: OpenBao's own TLS from the name-constrained `openbao-local-ca`, service certificates from `openbao-pki-issuer`, and certificates workstations trust from the namespaced `openbao-desktop-issuer` Issuers. |
| Desktop CA | Same as OpenBao | OpenBao PKI mount `pki_desktop`, an intermediate under the cluster's PKI root and the only CA a workstation is asked to trust. It may sign only `localhost` and `INTERNAL_DOMAIN` names, and only the `gateway`, `kube-system` and `tekton-pipelines` namespaces can request from it. The bootstrap asks whether to install it, with OpenBao's CA, into the machine's trust store ([Access Policy](docs/ACCESSPOLICY.md)). |
| OpenBao (in-cluster) | `2.7.2` <!-- renovate: datasource=docker depName=openbao/openbao --> (chart `0.30.7` <!-- renovate: datasource=helm depName=openbao registryUrl=https://openbao.github.io/openbao-helm -->) | Secrets backend on Integrated Storage (Raft). It unseals itself from the static seal key in Secret `openbao-seal-key`, and Flux replaces it on an upgrade unattended. Its chart's snapshot agent saves a Raft snapshot on `OPENBAO_SNAPSHOT_SCHEDULE` to the SeaweedFS bucket `openbao-snapshots`. Hosts KV secrets, Kubernetes Auth, the PKI engine (one root with two name-constrained intermediates: the service CA and the desktop CA) and the database secrets engine. Its UI opens on the workstation at `https://localhost:8210/ui` (`just ui openbao`). |
| OpenBao CSI Provider | `2.0.3` (via OpenBao chart `0.30.7` <!-- renovate: datasource=helm depName=openbao registryUrl=https://openbao.github.io/openbao-helm -->) | DaemonSet in `openbao` that logs in to OpenBao with each mounting pod's ServiceAccount token and reads the logins its `SecretProviderClass` names. |
| OpenBao Database & PKI Engines | Same as OpenBao | Issues Postgres login roles on demand (3h default TTL / 24h max) and issues 30-day TLS certificates via cert-manager. |
| OpenBao secrets-aws plugin | `v0.3.3` <!-- renovate: datasource=docker depName=ghcr.io/openbao/openbao-plugin-secrets-aws --> | Mounted at `seaweedfs/`. It creates a SeaweedFS IAM user with a key pair scoped to the backup bucket for each read, with a 4-day lease. OpenBao downloads it at startup. |
| OpenBao snapshot agent | `0.4.5` <!-- renovate: datasource=docker depName=ghcr.io/openbao/openbao-snapshot-agent --> | The OpenBao chart's CronJob: every `OPENBAO_SNAPSHOT_SCHEDULE` it saves a Raft snapshot and uploads it to the SeaweedFS bucket `openbao-snapshots`, deleting copies older than `OPENBAO_SNAPSHOT_RETENTION_DAYS`. It's for rolling back a bad upgrade. |
| Secrets Store CSI Driver | `1.6.2` <!-- renovate: datasource=helm depName=secrets-store-csi-driver registryUrl=https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts --> | DaemonSet in `kube-system` that mounts provider-fetched logins into pods, mirrors them into Kubernetes `Secret`s and reads them again every `CREDENTIAL_ROTATION_INTERVAL`. |
| SPIRE | `1.16.0` <!-- renovate: datasource=docker depName=ghcr.io/spiffe/spire-agent --> (chart `0.30.4` <!-- renovate: datasource=helm depName=spire registryUrl=https://spiffe.github.io/helm-charts-hardened -->) | SPIFFE workload identity in `spire`, with its CA signed by OpenBao's PKI. Issues SVIDs that the Flux controllers use to authenticate each other and that Prometheus and every metrics target present to each other. The SPIFFE CSI driver (`0.2.7`) mounts the agent's Workload API socket into pods, and spire-controller-manager registers `ClusterSPIFFEID`s. |
| trust-manager | `v0.26.0` <!-- renovate: datasource=helm depName=trust-manager registryUrl=https://charts.jetstack.io --> | Distributes CA certificates: copies `openbao-ca-bundle`, `openbao-root-ca` and `postgres-client-ca` as ConfigMaps or Secrets into each namespace labelled `data-cluster/ca-bundles`, and `openbao-issuer-ca` into the namespaces holding a desktop Issuer. |

### Databases and Storage

**CloudNativePG** runs the **PostgreSQL / PostGIS image**, and the **Barman Cloud Plugin** writes its backups to **SeaweedFS**. **Zot** is the cluster's OCI registry and pull-through cache:

| Component | Version | Description |
| --- | --- | --- |
| Barman Cloud Plugin | `0.8.1` <!-- renovate: datasource=helm depName=plugin-barman-cloud registryUrl=https://cloudnative-pg.github.io/charts --> | WAL archiving and base backups for CNPG through the `ObjectStore` resource. |
| CloudNativePG (CNPG) | `0.29.1` <!-- renovate: datasource=helm depName=cloudnative-pg registryUrl=https://cloudnative-pg.github.io/charts --> | Operator managing the PostgreSQL/PostGIS lifecycle: provisioning, reconciliation, hibernation, backup orchestration. |
| PostgreSQL / PostGIS image | `18.6-3.7.0-system-trixie` <!-- renovate: datasource=docker depName=ghcr.io/cloudnative-pg/postgis --> | PostgreSQL/PostGIS operand image. |
| SeaweedFS | `4.52.0` <!-- renovate: datasource=helm depName=seaweedfs registryUrl=https://seaweedfs.github.io/seaweedfs/helm --> | In-cluster S3-compatible object store with TLS issued by `openbao-pki-issuer`. CNPG streams WAL and writes scheduled base backups to it over HTTPS (`https://seaweedfs-s3.seaweedfs.svc:9000`). Its IAM API lets OpenBao create and delete Barman's key pairs. |
| Zot | `0.1.134` <!-- renovate: datasource=helm depName=zot registryUrl=https://zotregistry.dev/helm-charts --> | OCI registry in `zot`. Stores images in the SeaweedFS bucket `zot` and serves them at `zot.${INTERNAL_DOMAIN}` through the shared Gateway. Acts as a pull-through cache for ghcr.io, docker.io, quay.io and registry.k8s.io. k3s's containerd resolves image pulls for those four registries through it. The `tekton-builder` user may push to `dev/**`. S3 credentials and the push htpasswd come from the CSI driver; a `credential-watch` sidecar restarts the pod when the S3 key pair rotates. |

### Testing

The **Tekton Operator** installs **Tekton Pipelines** and **Tekton Triggers**, which run **`core-test`** at the end of every bootstrap and on every pull request, and the **Tekton Dashboard** shows their runs. Tekton's controllers live in `tekton`, the EventListener and Triggers in `tekton-triggers`, and Tasks, Pipelines and their runs in `tekton-pipelines`:

| Component | Version | Description |
| --- | --- | --- |
| `code-quality` | `infrastructure/tekton/pipelines/code-quality/` (planned for 3.0) | GitHub e2e runs it against the provisioned cluster. It validates rendered Flux manifests with kubeconform using the live cluster's CRD schemas and scans those manifests, OpenTofu and devcontainer files with Trivy. |
| `core-test` | `infrastructure/tekton/pipelines/core-test/` (planned for 3.0) | The Pipeline that checks the live core at the end of every bootstrap, and on a pull request's commits on the workstation and in GitHub e2e: Flux, workloads, CA bundles, servers that refuse clients without a certificate, the data-science client's OpenBao and PostgreSQL login with their refusals, and network policies that drop unauthorized pods. |
| Tekton Dashboard | `v0.74.0` <!-- renovate: datasource=github-releases depName=tektoncd/dashboard --> | Read-only web view of Pipelines, runs and their logs, from the upstream release Flux applies (`infrastructure/tekton/dashboard/`). Reached only from the workstation at `https://localhost:12001` (`just ui tekton`), through the HTTPS container in its own pod. |
| Tekton Operator | `v0.81.3` <!-- renovate: datasource=github-releases depName=tektoncd/operator --> | Installs Pipelines, Triggers and the pruner from one `TektonConfig`. |
| Tekton Pipelines | `v1.15.5` (via Tekton Operator `v0.81.3` <!-- renovate: datasource=github-releases depName=tektoncd/operator -->) | Cluster-native CI engine with Pipelines/Tasks/PipelineRuns from CRDs. |
| Tekton Triggers | `v0.37.2` (via Tekton Operator `v0.81.3` <!-- renovate: datasource=github-releases depName=tektoncd/operator -->) | The `flux-events` EventListener (planned for 3.0) turns events from Flux's notification-controller into PipelineRuns. While Flux follows a pull request's branch, each commit it applies starts `core-test`. |

### Observability

**kube-prometheus-stack** collects the cluster's metrics, **Grafana Alloy** ships pod logs to **Loki**, and **Tetragon** observes processes and file access. Every metrics scrape is encrypted and authenticated: targets use their native TLS where they have it, and **Ghostunnel** sidecars serve the rest over SPIFFE mTLS, with **spiffe-helper** giving Prometheus its identity:

| Component | Version | Description |
| --- | --- | --- |
| Ghostunnel | `v1.11.5` <!-- renovate: datasource=docker depName=ghostunnel/ghostunnel --> (planned for 3.0) | `metrics-tls` sidecar beside each plaintext metrics endpoint. It serves the pod's SPIRE identity and admits only Prometheus's SPIFFE ID. |
| Grafana Alloy | `v1.22.0` (chart `1.16.0`, planned for 3.0) | DaemonSet that tails pod logs through the Kubernetes API and ships them to Loki, TaskRun pod logs included, along with Kubernetes events. |
| kube-prometheus-stack | `93.3.1` (chart, operator `v0.95.2`, Grafana `13.3.1`, planned for 3.0) | Prometheus, Alertmanager, Grafana, kube-state-metrics and node-exporter. Prometheus and Alertmanager keep their data on host paths. Grafana keeps its state in PostgreSQL database `grafana` and is reached at `grafana.cluster.internal` through the shared Gateway. Alerts are read in Grafana. |
| Loki | `3.6.18` (chart `7.6.0`, planned for 3.0) | Single-process log storage and queries. Logs live in the core SeaweedFS bucket `loki`, the WAL on a host path. Grafana queries it over HTTPS. |
| spiffe-helper | `0.12.3` <!-- renovate: datasource=docker depName=ghcr.io/spiffe/spiffe-helper --> (planned for 3.0) | Sidecar in the Prometheus and kube-state-metrics pods that writes the pod's SVID and SPIRE's trust bundle to files. Prometheus presents and verifies them when it scrapes, and kube-state-metrics serves its own mTLS with them. |
| Tetragon | `v1.8.0` (chart `1.8.0`, planned for 3.0) | eBPF runtime observation in `kube-system`. It records process executions and reads and writes of sensitive files, and Alloy ships its events to Loki. Alert `SensitiveFileAccess` fires when a process in a pod touches one of those files, and Grafana's alerting view shows it. Shares the eBPF datapath Cilium uses, and comes from the same developer. |

### Workstation UIs

These are the graphical tools for the cluster on the workstation. Each opens in a browser or in VS Code's Simple Browser except Headlamp, which is a desktop app. Their certificates verify once the bootstrap's trust prompt is answered yes ([Access Policy](docs/ACCESSPOLICY.md#workstation-trust)).

Hubble UI and the Tekton Dashboard serve plain HTTP without authentication, so each pod gets a `localhost-tls` container: Ghostunnel serving HTTPS from a `localhost` certificate (desktop CA) and forwarding locally to the UI. A CiliumLocalRedirectPolicy sends the workstation's `127.0.0.1:12000` (Hubble UI) or `127.0.0.1:12001` (Tekton Dashboard) to that container. Both are reachable from the local workstation only.

| UI | Version | Address | Description |
| --- | --- | --- | --- |
| Grafana | Same as kube-prometheus-stack | `https://grafana.cluster.internal` | Dashboards, logs and alerts, through the shared Gateway with its certificate from the desktop CA. Grafana has its own login. |
| Headlamp | `0.45.0` (desktop app) | `~/.kube/config` | Kubernetes GUI on the host, reading the admin kubeconfig. Its plugins assist with cluster management. |
| Hubble UI | `v0.13.6` (via Cilium) | `https://localhost:12000` (`just ui hubble`) | Service map and flow browser, through its `localhost-tls` container. |
| OpenBao UI | Same as OpenBao | `https://localhost:8210/ui` (`just ui openbao`) | OpenBao's own UI through its existing loopback redirect, serving its own certificate from the name-constrained `openbao-local-ca`. OpenBao has its own login. |
| Tekton Dashboard | `v0.74.0` | `https://localhost:12001` (`just ui tekton`) | Read-only view of Pipelines, runs and their logs, through its `localhost-tls` container. |

---

## Official Documentation

### Provisioning Tools

| Tool | Documentation |
| --- | --- |
| Ansible | [https://docs.ansible.com/](https://docs.ansible.com/) |
| Flux CLI | [https://fluxcd.io/flux/cmd/](https://fluxcd.io/flux/cmd/) |
| GitHub CLI (`gh`) | [https://cli.github.com/manual/](https://cli.github.com/manual/) |
| Helm | [https://helm.sh/docs/](https://helm.sh/docs/) |
| OpenTofu | [https://opentofu.org/docs/](https://opentofu.org/docs/) |
| uv | [https://docs.astral.sh/uv/](https://docs.astral.sh/uv/) |

### Source Control

| Tool | Documentation |
| --- | --- |
| Git | [https://git-scm.com/doc](https://git-scm.com/doc) |

### Cluster Operation Tools

| Tool | Documentation |
| --- | --- |
| fzf | [https://junegunn.github.io/fzf/](https://junegunn.github.io/fzf/) |
| just | [https://just.systems/man/en/](https://just.systems/man/en/) |
| kubectl | [https://kubernetes.io/docs/reference/kubectl/](https://kubernetes.io/docs/reference/kubectl/) |
| kubectl cnpg plugin | [https://cloudnative-pg.io/documentation/current/kubectl-plugin/](https://cloudnative-pg.io/documentation/current/kubectl-plugin/) |
| Tekton CLI (`tkn`) | [https://tekton.dev/docs/cli/](https://tekton.dev/docs/cli/) |

### Host Database Access

| Tool | Documentation |
| --- | --- |
| pgiscluster | [https://pypi.org/project/pgiscluster/](https://pypi.org/project/pgiscluster/) |

### Platform

| Component | Documentation |
| --- | --- |
| Flux | [https://fluxcd.io/flux/](https://fluxcd.io/flux/) |
| k3s | [https://docs.k3s.io/](https://docs.k3s.io/) |
| local-path provisioner | [https://github.com/rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) |
| metrics-server | [https://github.com/kubernetes-sigs/metrics-server](https://github.com/kubernetes-sigs/metrics-server) |
| Prometheus Operator CRDs | [https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) |

### Networking

| Component | Documentation |
| --- | --- |
| Cilium | [https://docs.cilium.io/](https://docs.cilium.io/) |
| DNS (CoreDNS) | [https://coredns.io/manual/toc/](https://coredns.io/manual/toc/) |
| Gateway | [https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/) |
| Gateway API | [https://gateway-api.sigs.k8s.io/](https://gateway-api.sigs.k8s.io/) |
| Hubble | [https://docs.cilium.io/en/stable/observability/hubble/](https://docs.cilium.io/en/stable/observability/hubble/) |
| Hubble UI | [https://github.com/cilium/hubble-ui](https://github.com/cilium/hubble-ui) |

### Secrets, Certificates and Identity

| Component | Documentation |
| --- | --- |
| cert-manager | [https://cert-manager.io/docs/](https://cert-manager.io/docs/) |
| Desktop CA | [`docs/ACCESSPOLICY.md#workstation-trust`](docs/ACCESSPOLICY.md#workstation-trust), [https://openbao.org/docs/secrets/pki/](https://openbao.org/docs/secrets/pki/) |
| OpenBao (in-cluster) | [https://openbao.org/docs/](https://openbao.org/docs/) |
| OpenBao CSI Provider | [https://openbao.org/docs/platform/k8s/csi/](https://openbao.org/docs/platform/k8s/csi/) |
| OpenBao Database & PKI Engines | [https://openbao.org/docs/secrets/databases/](https://openbao.org/docs/secrets/databases/), [https://openbao.org/docs/secrets/pki/](https://openbao.org/docs/secrets/pki/) |
| OpenBao secrets-aws plugin | [https://github.com/openbao/openbao-plugins/tree/main/secrets/aws](https://github.com/openbao/openbao-plugins/tree/main/secrets/aws) |
| OpenBao snapshot agent | [https://github.com/openbao/openbao-snapshot-agent](https://github.com/openbao/openbao-snapshot-agent) |
| Secrets Store CSI Driver | [https://secrets-store-csi-driver.sigs.k8s.io/](https://secrets-store-csi-driver.sigs.k8s.io/) |
| SPIRE | [https://spiffe.io/docs/latest/spire-about/](https://spiffe.io/docs/latest/spire-about/) |
| trust-manager | [https://cert-manager.io/docs/trust/trust-manager/](https://cert-manager.io/docs/trust/trust-manager/) |

### Databases and Storage

| Component | Documentation |
| --- | --- |
| Barman Cloud Plugin | [https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/](https://cloudnative-pg.io/plugin-barman-cloud/docs/intro/) |
| CloudNativePG (CNPG) | [https://cloudnative-pg.io/docs](https://cloudnative-pg.io/docs), [https://cloudnative-pg.io/documentation/current/certificates/](https://cloudnative-pg.io/documentation/current/certificates/), [https://cloudnative-pg.io/documentation/current/declarative_hibernation/](https://cloudnative-pg.io/documentation/current/declarative_hibernation/) |
| PostgreSQL / PostGIS image | [https://www.postgresql.org/docs/current/](https://www.postgresql.org/docs/current/), [https://postgis.net/documentation/](https://postgis.net/documentation/) |
| SeaweedFS | [https://github.com/seaweedfs/seaweedfs/wiki](https://github.com/seaweedfs/seaweedfs/wiki) |
| Zot | [https://zotregistry.dev/](https://zotregistry.dev/) |

### Testing

| Component | Documentation |
| --- | --- |
| `code-quality` | [`infrastructure/tekton/pipelines/code-quality/`](infrastructure/tekton/pipelines/code-quality/) |
| `core-test` | [`infrastructure/tekton/pipelines/core-test/`](infrastructure/tekton/pipelines/core-test/) |
| Tekton Dashboard | [https://tekton.dev/docs/dashboard/](https://tekton.dev/docs/dashboard/) |
| Tekton Operator | [https://tekton.dev/docs/operator/](https://tekton.dev/docs/operator/) |
| Tekton Pipelines | [https://tekton.dev/docs/pipelines/](https://tekton.dev/docs/pipelines/) |
| Tekton Triggers | [https://tekton.dev/docs/triggers/](https://tekton.dev/docs/triggers/) |

### Observability

| Component | Documentation |
| --- | --- |
| Ghostunnel | [https://github.com/ghostunnel/ghostunnel](https://github.com/ghostunnel/ghostunnel) |
| Grafana Alloy | [https://grafana.com/docs/alloy/latest/](https://grafana.com/docs/alloy/latest/) |
| kube-prometheus-stack | [https://github.com/prometheus-operator/kube-prometheus](https://github.com/prometheus-operator/kube-prometheus) |
| Loki | [https://grafana.com/docs/loki/latest/](https://grafana.com/docs/loki/latest/) |
| spiffe-helper | [https://github.com/spiffe/spiffe-helper](https://github.com/spiffe/spiffe-helper) |
| Tetragon | [https://tetragon.io/](https://tetragon.io/) |

### Workstation UIs

| UI | Documentation |
| --- | --- |
| Grafana | [https://grafana.com/docs/grafana/latest/](https://grafana.com/docs/grafana/latest/) |
| Headlamp | [https://headlamp.dev/docs/latest/](https://headlamp.dev/docs/latest/) |
| Hubble UI | [https://github.com/cilium/hubble-ui](https://github.com/cilium/hubble-ui) |
| OpenBao UI | [https://openbao.org/docs/configuration/ui/](https://openbao.org/docs/configuration/ui/) |
| Tekton Dashboard | [https://tekton.dev/docs/dashboard/](https://tekton.dev/docs/dashboard/) |
