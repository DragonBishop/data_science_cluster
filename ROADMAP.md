# Project Roadmap

This roadmap outlines the evolution of the k3s cluster from a secure foundational baseline into a robust platform, with modular support for parallel Extract, Transform, Load (ETL) and Machine Learning (ML) workloads. The goal is to leverage lightweight, open-source services that integrate seamlessly with the existing eBPF networking, PostgreSQL, and storage infrastructure.

## Feature Development

To scale workloads effectively, the architecture requires distinct services optimized for data orchestration, transformation, and model lifecycle management. All recommended applications prioritize a low compute footprint, robust observability, and Kubernetes-native design.

### Foundational Cluster Services

Both ETL and ML workloads rely on a shared operational baseline.

* **GitOps Controller**: ArgoCD Core. It automates declarative state management and synchronizes deployments from Git repositories, chosen specifically for its lightweight nature.
  * *Alternative:* FluxCD should be kept in mind if Argo's sync-wave-based ordering (Vault → VSO → CNPG → app manifests) turns out to be fragile in practice; if that happens, Flux's `dependsOn` feature is the concrete alternative to reach for.
* **Persistent Storage Provisioning**: Local Path Provisioner. This utilizes the built-in k3s storage class to natively bind Persistent Volume Claims to host directories with zero custom kernel requirements and practically zero RAM overhead.
  * *Note:* A migration to a distributed solution like Longhorn should be considered only if the architecture expands to a multi-node cluster that requires volume replication, automated snapshotting, and high availability.
  * **Runtime Security & Threat Detection**: Falco. This provides real-time, eBPF-based detection of anomalous behavior at the syscall level — unexpected shell spawns inside a container, unauthorized reads of sensitive files, privilege escalation attempts — giving the cluster a runtime/process-level security signal to complement Cilium's network-layer visibility.
  * *Alternative:* Tetragon is worth reconsidering later, since it's built by the same team as Cilium and shares its eBPF datapath rather than running a second, independent probe alongside it. Falco is the more battle-tested choice for now, with a larger existing rule/policy ecosystem.
* **Observability Stack**: kube-prometheus-stack & Loki. This deploys the industry-standard Prometheus, Grafana, and Alertmanager bundle alongside Loki for comprehensive metric aggregation, dashboarding, and log processing to debug resource spikes and workload bottlenecks.
* **Network & Gateway Routing**: Cilium (already in cluster). While it carries a heavier footprint than standard ingress controllers, its eBPF architecture bypasses traditional iptables to eliminate network bottlenecks and significantly reduce CPU overhead during heavy ETL data shuffling. For ML workloads, its native Gateway API support enables low-latency model inference and advanced traffic management, such as canary deployments for new models.

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

**1. Single-Node Availability Limits (HA)** — Scaling Vault and CloudNativePG to 3 replicas with pod anti-affinity remains appropriate only once this moves out of local, single-node development. Not a priority while the cluster is still single-node local development and ETL/ML workloads aren't yet running.

**2. Identity Federation for Workloads** — Extending the existing Vault Kubernetes auth pattern (`postgis-role`) to Prefect workers and ML inference pods isn't useful to build yet, because those workloads don't exist yet. This is squarely an ETL/ML-stage item; revisit it when the first Prefect worker or inference pod actually needs a scoped-down Service Account and Vault role, rather than speculatively building the mapping now.

**3. `tiger`/`topology` schemas owned by `postgres`, not `app_readwrite`** — `apps/databases/postgis-database.yaml`'s `spec.schemas` block (added to fix `postgis_topology`/`postgis_tiger_geocoder` extension installation, which requires their target schema to pre-exist) doesn't set `owner:`, so CNPG's reconciler created both schemas owned by the connecting superuser instead of the group role. `pg_read_all_data`/`pg_write_all_data` already cover read/write on existing objects there, so nothing is broken today, but any future `CREATE`/`ALTER`/`DROP` inside `tiger`/`topology` needs `postgres`-level access that Vault-issued leases don't have. Fix: add `owner: app_readwrite` to both entries in `spec.schemas`.
