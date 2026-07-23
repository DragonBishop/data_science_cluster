# Project Roadmap

This roadmap outlines the systematic evolution of the k3s cluster from a secure foundational baseline into a robust platform for parallel Extract, Transform, Load (ETL) and Machine Learning (ML) workloads. The goal is to leverage lightweight, open-source services that integrate seamlessly with the existing eBPF networking, PostgreSQL, and storage infrastructure.

## Feature Development

To scale workloads effectively, the architecture requires distinct services optimized for data orchestration, transformation, and model lifecycle management. All recommended applications prioritize a low compute footprint, robust observability, and Kubernetes-native design.

### Foundational Cluster Services

Both ETL and ML workloads rely on a shared operational baseline.

* **GitOps Controller**: ArgoCD (Automates declarative state management and synchronizes deployments from Git repositories).
* **Persistent Storage Provisioning**: Longhorn (Provides dynamic persistent volumes, snapshotting, and replication natively within k3s. *Note: Running Longhorn under WSL2 requires a compatibility spike, as it relies on `iscsid` and specific kernel patches that may necessitate compiling a custom WSL2 kernel to prevent I/O errors under load*).
* **Cluster Management UI**: Headlamp (In-Cluster Deployment) (Expands the existing Windows desktop client usage into a lightweight, browser-based graphical interface hosted on the cluster for ubiquitous monitoring with minimal overhead).
* **Observability Stack**: Prometheus, Grafana, and Loki (Aggregates metrics, dashboarding, and log processing to debug resource spikes and workload bottlenecks).
* **Network & Gateway Routing**: Cilium (Leverages eBPF for near-zero latency traffic routing, mTLS, and Gateway API support. *Note: While it carries a heavier footprint than standard ingress controllers, the performance and security investments are worthwhile, and it has already been successfully installed on the cluster.*)

### ETL Pipeline Services

The ETL expansion focuses on data ingestion, declarative orchestration, and in-database transformation.

* **Orchestration**: Prefect (Replaces heavy legacy schedulers with a Python-native, highly observable orchestration engine for triggering data pipelines).
* **Data Integration / Ingestion**: dlt (data load tool) (Provides an open-source Python library for building declarative data pipelines that load data from REST APIs, databases, and other sources. *Note: Airbyte is a fallback option if a UI-driven ecosystem of pre-built connectors is eventually needed.*)
* **Data Transformation**: dbt / Data Build Tool (Executes complex SQL-based transformations natively within the CloudNativePG database, ensuring compute remains close to the data).

### Machine Learning Services

The ML expansion focuses on managing experiment tracking, environment provisioning, and model serving, utilizing strictly open-source (Apache 2.0) tooling.

* **Experiment Tracking & Metadata**: MLflow (Tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in MinIO).
* **Model Serving**: BentoML (Packages models into self-contained, production-ready services using a Python-first framework. *Note: KServe is a potential alternative if you later require Kubernetes-native inference features like scale-to-zero or advanced GPU scheduling.*)

## Technical Debt

While the current cluster architecture securely solves the "secret zero" problem for local development, its reliance on static credentials, single-node points of failure, and permissive networking must be remediated to support scalable automation.

### 1. Dynamic Secrets Generation

* **Current Debt**: Database credentials are manually seeded into the Key-Value (KV-v2) store. This necessitates manual rotation and leaves static credentials exposed within the cluster.
* **Remediation**: Configure HashiCorp Vault's Database Secrets Engine to connect with CloudNativePG. Transition from static KV pairs to dynamically generated PostgreSQL roles and passwords with strict Time-to-Live (TTL) policies. Vault will automatically revoke credentials when pipelines complete or TTLs expire.

### 2. Identity Federation for Workloads

* **Current Debt**: While the foundation for Kubernetes authentication exists (the `postgis-role`), it has not been extended to downstream workloads, increasing the risk of broad credential exposure if a pipeline pod is compromised.
* **Remediation**: Extend the existing Vault Kubernetes Auth pattern to map Service Accounts for Prefect workers and ML inference pods. Ensure these workloads authenticate natively via JWTs to receive temporary tokens granting access strictly to the resources required for their specific tasks.

### 3. Database Hostname-Verified TLS

* **Current Debt**: The CloudNativePG instances support encryption but lack hostname verification (`sslmode=verify-full`) because the server certificates do not include `localhost` or proper domain SANs.
* **Remediation**: Deploy `cert-manager` inside the cluster to issue custom Server Certificates with appropriate Subject Alternative Names for the Postgres cluster, enforcing fully verified TLS connections and automating certificate rotation.

### 4. Single-Node Availability Limits (HA)

* **Current Debt**: Both the HashiCorp Vault and CloudNativePG database are deployed as single replicas (`instances: 1`). The cluster lacks automated failover redundancy.
* **Remediation**: Scale Vault and CloudNativePG to a minimum of 3 replicas with pod anti-affinity rules to tolerate node-level failures when migrating out of local WSL development to a distributed environment.

### 7. Vault Token Lifecycle and CLI Key Exposure

* **Current Debt**: `start-cluster.sh` passes the transit unseal keys as CLI parameters, briefly exposing them in process tables (`/proc/<pid>/cmdline`).
* **Remediation**: The `vault operator unseal` CLI lacks a `stdin` read mode. Refactor the script to bypass the CLI entirely by calling Vault's API directly (e.g., via `curl`), passing the keys securely in a POST body.

### 8. Deprecations and Component Versioning

* **Current Debt**: The `spec.backup.barmanObjectStore` field in CloudNativePG is deprecated. Additionally, the Postgres-Proxy bridge utilizes an unpinned image tag (`alpine/socat:latest`).
* **Remediation**: Migrate the CNPG backups to the Barman Cloud Plugin architecture prior to CNPG v1.31.0. Pin the proxy image to an immutable SHA digest to prevent upstream breaking changes. Audit and document the unidentified `clustersecret` operator.

[REDACTED - see vault docs]
