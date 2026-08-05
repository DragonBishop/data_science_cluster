# Project Roadmap

This roadmap outlines the evolution of the k3s cluster from a secure foundational baseline into a robust platform, with modular support for parallel Extract, Transform, Load (ETL) and Machine Learning (ML) workloads. The goal is to leverage lightweight, open-source services that integrate seamlessly with the existing eBPF networking, PostgreSQL, and storage infrastructure.

## Feature Development

To scale workloads effectively, the architecture requires distinct services optimized for data orchestration, transformation, and model lifecycle management. All recommended applications prioritize a low compute footprint, robust observability, and Kubernetes-native design.

### Foundational Cluster Services

Both ETL and ML workloads rely on a shared operational baseline.

* **GitOps Controller**: FluxCD. Its `dependsOn` + health-check gating enforces the install graph this stack's bootstrap depends on (Gateway API CRDs → Cilium → cert-manager → Vault → VSO → CNPG → barman-cloud → SeaweedFS → Cluster) as an explicit dependency graph rather than priority ordering. Headlamp's Flux plugin covers the UI.
  * *Alternative:* ArgoCD is the alternative if a built-in web UI and RBAC across multiple teams or clusters becomes a requirement Headlamp's plugin doesn't cover. Its ordering model is sync-waves (priority annotations per resource) rather than an explicit graph, so adopting it means re-expressing this install order as wave numbers instead of `dependsOn` edges.That's a different manifest structure, not just a different controller.
* **Persistent Storage Provisioning**: Local Path Provisioner. This utilizes the built-in k3s storage class to natively bind Persistent Volume Claims to host directories with zero custom kernel requirements and practically zero RAM overhead.
  * *Note:* A migration to a distributed solution like Longhorn should be considered only if the architecture expands to a multi-node cluster that requires volume replication, automated snapshotting, and high availability.
  * **Runtime Security & Threat Detection**: Falco. This provides real-time, eBPF-based detection of anomalous behavior at the syscall level. It detects unexpected shell spawns inside a container, unauthorized reads of sensitive files, privilege escalation attempts. It gives  the cluster a runtime/process-level security signal to complement Cilium's network-layer visibility.
  * *Alternative:* Tetragon is worth reconsidering later, since it's built by the same team as Cilium and shares its eBPF datapath rather than running a second, independent probe alongside it. Falco is the more battle-tested choice for now, with a larger existing rule/policy ecosystem.
* **Observability Stack**: kube-prometheus-stack & Loki. This deploys the industry-standard Prometheus, Grafana, and Alertmanager bundle alongside Loki for comprehensive metric aggregation, dashboarding, and log processing to debug resource spikes and workload bottlenecks.
* **Network & Gateway Routing**: Cilium (already in cluster) serves as both the CNI and the Gateway API implementation — its eBPF architecture bypasses traditional iptables, reducing CPU overhead during heavy ETL data shuffling, and its Gateway API support is the intended path for low-latency model inference routing and traffic management (e.g. canary deployments) for ML serving.

### ETL Pipeline Services

The ETL expansion focuses on data ingestion, declarative orchestration, and in-database transformation.

* **Orchestration**: Prefect. This replaces heavy legacy schedulers with a Python-native, highly observable orchestration engine for triggering data pipelines.
  * *Note:* Apache Airflow is the industry-standard alternative for data orchestration, but its heavy infrastructure footprint—requiring multiple dedicated scheduler, webserver, and worker pods—makes it overly complex for a lightweight local cluster.
* **Data Integration / Ingestion**: dlt (data load tool). This provides an open-source Python library for building declarative data pipelines that load data from REST APIs, databases, and other sources.
  * *Note:* Airbyte is a fallback option if a UI-driven ecosystem of pre-built connectors is eventually needed.
* **Data Transformation**: dbt (Data Build Tool). This executes complex SQL-based transformations natively within the CloudNativePG database, ensuring compute remains close to the data.
  * *Note:* Apache Spark is the industry standard for massive-scale, distributed data transformation, but dbt is far lighter and more appropriate for pushing compute down into a local database rather than spinning up dedicated compute clusters.

### Machine Learning Services

The ML expansion focuses on managing experiment tracking, environment provisioning, and model serving, utilizing strictly open-source (Apache 2.0) tooling.

* **Experiment Tracking & Metadata**: MLflow. This tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in the cluster's SeaweedFS object store.
* **Model Serving**: BentoML. This packages models into self-contained, production-ready services using a Python-first framework.
  * *Note:* KServe is a potential alternative if Kubernetes-native inference features like scale-to-zero or advanced GPU scheduling are later required.

## Technical Debt

**1. Resource requests and limits cover only the database** — `postgis-cluster.yaml` sets requests/limits for the Postgres container and the `postgres-proxy` socat sidecar; every other component (Cilium, cert-manager, Vault, VSO, the CNPG operator, Barman Cloud, SeaweedFS, CoreDNS, Hubble Relay/UI) runs BestEffort. A resource spike in any of those has no ceiling and no guaranteed floor.

**2. No monitoring or alerting for the platform itself** — kube-prometheus-stack and Loki are scoped above as ETL/ML tooling for workload observability, but today there is no dashboard or alert for whether Vault, Cilium, or the CNPG operator are themselves healthy; the only signal is a manual `kubectl`/`flux get kustomizations`/`kubectl cnpg status` check.

**3. NetworkPolicies cover only SeaweedFS** — `apps/databases/seaweedfs-networkpolicy.yaml` is the sole network policy in the repo. Postgres, Vault, VSO, cert-manager, the CNPG operator, and Barman Cloud all have unrestricted intra-cluster network access.

**4. OpenTofu state is single-operator** — `terraform/vault-bootstrap/` and `terraform/vault-database/` both use local, encrypted-at-rest state behind one passphrase in one password manager. Fine for the current one-person setup; a second operator needs a real passphrase-distribution or remote-backend story before touching either module.

**5. No documented Cilium upgrade runbook** — `cilium-release.yaml`'s `upgrade.remediation.remediateLastFailure: true` rolls back a failed HelmRelease automatically, but nothing documents the human side: confirming the target version's Gateway API compatibility before bumping, or what to check after. `helm rollback cilium -n kube-system` from the host remains the manual escape hatch if the automatic remediation itself needs overriding.

**6. Identity Federation for Workloads** — Extending the existing Vault Kubernetes auth pattern (`postgis-role`) to Prefect workers and ML inference pods isn't useful to build yet, because those workloads don't exist yet. This is squarely an ETL/ML-stage item; revisit it when the first Prefect worker or inference pod actually needs a scoped-down Service Account and Vault role, rather than speculatively building the mapping now.

*Note: Single-node HA is not part of the current build, but would be necessary for any multi-node expansion of this cluster.*