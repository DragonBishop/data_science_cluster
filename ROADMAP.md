# Project Roadmap

This roadmap outlines the systematic evolution of the k3s cluster from a secure foundational baseline into a robust platform for parallel Extract, Transform, Load (ETL) and Machine Learning (ML) workloads. The goal is to leverage lightweight, open-source services that integrate seamlessly with the existing eBPF networking, PostgreSQL, and storage infrastructure.

## Feature Development

To scale workloads effectively, the architecture requires distinct services optimized for data orchestration, transformation, and model lifecycle management. All recommended applications prioritize a low compute footprint, robust observability, and Kubernetes-native design.

### Foundational Cluster Services

Both ETL and ML workloads rely on a shared operational baseline.

* **GitOps Controller**: ArgoCD Core. It automates declarative state management and synchronizes deployments from Git repositories, chosen specifically for its lightweight nature.
  * *Alternative:* FluxCD should be kept in mind if Argo's sync-wave-based ordering (Vault → VSO → CNPG → app manifests) turns out to be fragile in practice; if that happens, Flux's `dependsOn` feature is the concrete alternative to reach for.
* **Persistent Storage Provisioning**: Local Path Provisioner. This utilizes the built-in k3s storage class to natively bind Persistent Volume Claims to host directories with zero custom kernel requirements and practically zero RAM overhead.
  * *Note:* You should consider migrating to a distributed solution like Longhorn only if you expand to a multi-node cluster that requires volume replication, automated snapshotting, and high availability.
* **Cluster Management UI**: Headlamp (In-Cluster Deployment). Allows for GUI to monitor cluster status and implement changes. Can improve ease of use through a Python script to auto-launch (see technical debt for more information).
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

* **Experiment Tracking & Metadata**: MLflow. This tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in MinIO.
* **Model Serving**: BentoML. This packages models into self-contained, production-ready services using a Python-first framework.
  * *Note:* KServe is a potential alternative if you later require Kubernetes-native inference features like scale-to-zero or advanced GPU scheduling.

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

### 4. Headlamp Auto-Launch Script

The current method for connecting to Headlamp is awkward and clunky, and still requires manually pulling up the browser and pasting the token. A Python Script could automate this work easily, following this algorithm:

The architecture must bridge two distinct execution environments by splitting the workload between a WSL context for cluster operations and a native Windows context for UI automation. Begin in the WSL environment by actively polling the cluster to confirm the Headlamp Service and Pod are genuinely ready, avoiding arbitrary sleeps or unrelated readiness gates. Once verified, generate a fresh service-account token using a shell with `kubectl` access, then restart the Headlamp port-forward, actively polling the local port until it accepts connections. Next, cross the execution boundary by passing this token as an argument or environment variable to a separate, native Windows process capable of invoking a real Chrome-engine browser to render a desktop GUI. This Windows process must launch the user's web browser (check for browser-specific dependencies) under browser-automation control, navigate to the forwarded URL, and explicitly wait for the login DOM element to render. Finally, to bypass the known OS clipboard paste bug, the automation script must inject the token directly into the field using the framework's own input-dispatch mechanism rather than simulating a keyboard paste, and trigger the submit action using that same direct interaction method.

### 7. Vault Token Lifecycle and CLI Key Exposure

* **Current Debt**: `start-cluster.sh` passes the transit unseal keys as CLI parameters, briefly exposing them in process tables (`/proc/<pid>/cmdline`).
* **Remediation**: The `vault operator unseal` CLI lacks a `stdin` read mode. Refactor the script to bypass the CLI entirely by calling Vault's API directly (e.g., via `curl`), passing the keys securely in a POST body.

### 8. Deprecations and Component Versioning

* **Current Debt**: The `spec.backup.barmanObjectStore` field in CloudNativePG is deprecated. Additionally, the Postgres-Proxy bridge utilizes an unpinned image tag (`alpine/socat:latest`).
* **Remediation**: Migrate the CNPG backups to the Barman Cloud Plugin architecture prior to CNPG v1.31.0. Pin the proxy image to an immutable SHA digest to prevent upstream breaking changes. Audit and document the unidentified `clustersecret` operator.

### 9. Single-Node Availability Limits (HA)

* **Current Debt**: Both the HashiCorp Vault and CloudNativePG database are deployed as single replicas (`instances: 1`). The cluster lacks automated failover redundancy.
* **Remediation**: Scale Vault and CloudNativePG to a minimum of 3 replicas with pod anti-affinity rules to tolerate node-level failures when migrating out of local WSL development to a distributed environment.
