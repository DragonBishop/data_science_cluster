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
* **Network & Gateway Routing**: Cilium (Leverages eBPF for near-zero latency traffic routing, mTLS, and Gateway API support).

### ETL Pipeline Services

The ETL expansion focuses on data ingestion, declarative orchestration, and in-database transformation.

* **Orchestration**: Prefect (Replaces heavy legacy schedulers with a Python-native, highly observable orchestration engine for triggering data pipelines).
* **Data Integration / Ingestion**: Airbyte (Provides an open-source framework with pre-built connectors to extract data from external APIs and load it into PostgreSQL or MinIO. *Note: While the core OSS edition covers single-user needs without paid enterprise features, expect a moderate ongoing maintenance overhead for connector updates*).
* **Data Transformation**: dbt / Data Build Tool (Executes complex SQL-based transformations natively within the CloudNativePG database, ensuring compute remains close to the data).

### Machine Learning Services

The ML expansion focuses on managing experiment tracking, environment provisioning, and model serving, utilizing strictly open-source (Apache 2.0) tooling.

* **Development Workspace**: VS Code Dev Containers (Executes isolated development environments locally via `.devcontainer` definitions, bypassing the need for in-cluster workspaces. This offloads compute from the k3s cluster while allowing seamless integration with terminal-based workflows like LazyVim or local IDE extensions).
* **Experiment Tracking & Metadata**: MLflow (Tracks code versions, hyperparameters, and experiment results, storing metadata in PostgreSQL and artifacts in MinIO).
* **Model Serving**: KServe or BentoML (Deploys trained ML models as scalable REST/gRPC endpoints. Replaces Seldon Core due to its shift to a restrictive Business Source License, ensuring the stack remains genuinely open-source while still utilizing Cilium's Gateway API for low-latency inference routing).

## Technical Debt

While the current cluster architecture securely solves the "secret zero" problem for local development, its reliance on static credentials, single-node points of failure, and permissive networking must be remediated to support scalable automation.

### 1. Transit Vault DNS and Stable TLS

* **Current Debt**: The Transit Vault's certificate Subject Alternative Name (SAN) relies on a hardcoded WSL host IP address. When WSL reallocates this IP, TLS verification breaks and the cluster boots permanently sealed.
* **Remediation**: Assign a stable hostname (e.g., `vault.wsl.local`). Map this via a WSL-side `/etc/hosts` entry for host-level OS resolution, and update the k3s CoreDNS ConfigMap to ensure in-cluster Main Vault pods resolve it to the current WSL IP. This allows the use of a statically generated certificate that survives IP changes, bypassing the need for complex out-of-cluster `cert-manager` glue for a host-side file.

### 2. Network Hardening and Zero Trust

* **Current Debt**: The main Vault listener (port 8200) currently accepts internal cluster traffic globally, violating the principle of least privilege. The Postgres bridge utilizes permissive routing.
* **Remediation**: Implement strict `CiliumNetworkPolicies`. Vault ingress must be restricted strictly to the `vault-secrets-operator-system` namespace. All ETL and ML workload namespaces must be denied direct API access to Vault unless explicitly authorized.

### 3. Dynamic Secrets Generation

* **Current Debt**: Database credentials are manually seeded into the Key-Value (KV-v2) store. This necessitates manual rotation and leaves static credentials exposed within the cluster.
* **Remediation**: Configure HashiCorp Vault's Database Secrets Engine to connect with CloudNativePG. Transition from static KV pairs to dynamically generated PostgreSQL roles and passwords with strict Time-to-Live (TTL) policies. Vault will automatically revoke credentials when pipelines complete or TTLs expire.

### 4. Identity Federation for Workloads

* **Current Debt**: While the foundation for Kubernetes authentication exists (the `postgis-role`), it has not been extended to downstream workloads, increasing the risk of broad credential exposure if a pipeline pod is compromised.
* **Remediation**: Extend the existing Vault Kubernetes Auth pattern to map Service Accounts for Prefect workers and ML inference pods. Ensure these workloads authenticate natively via JWTs to receive temporary tokens granting access strictly to the resources required for their specific tasks.

### 5. Database Hostname-Verified TLS

* **Current Debt**: The CloudNativePG instances support encryption but lack hostname verification (`sslmode=verify-full`) because the server certificates do not include `localhost` or proper domain SANs.
* **Remediation**: Deploy `cert-manager` inside the cluster to issue custom Server Certificates with appropriate Subject Alternative Names for the Postgres cluster, enforcing fully verified TLS connections and automating certificate rotation.

### 6. Single-Node Availability Limits (HA)

* **Current Debt**: Both the HashiCorp Vault and CloudNativePG database are deployed as single replicas (`instances: 1`). The cluster lacks automated failover redundancy.
* **Remediation**: Scale Vault and CloudNativePG to a minimum of 3 replicas with pod anti-affinity rules to tolerate node-level failures when migrating out of local WSL development to a distributed environment.

### 7. Vault Token Lifecycle and CLI Key Exposure

* **Current Debt**: The Transit Vault's unseal token relies on a 768-hour (32-day) periodic expiration without an automated renewal daemon. Furthermore, `start-cluster.sh` passes the transit unseal keys as CLI parameters, briefly exposing them in process tables (`/proc/<pid>/cmdline`).
* **Remediation**: Implement a `vault token renew` daemon on the host system to automatically handle token TTLs. For the unseal key exposure, the `vault operator unseal` CLI lacks a `stdin` read mode. You must either explicitly document and accept this `argv` exposure as a low-severity risk on a single-user host, or refactor the script to bypass the CLI entirely by calling Vault's API directly (e.g., via `curl`), passing the keys securely in a POST body.

### 8. Deprecations and Component Versioning

* **Current Debt**: The `spec.backup.barmanObjectStore` field in CloudNativePG is deprecated. Additionally, the Postgres-Proxy bridge utilizes an unpinned image tag (`alpine/socat:latest`).
* **Remediation**: Migrate the CNPG backups to the Barman Cloud Plugin architecture prior to CNPG v1.31.0. Pin the proxy image to an immutable SHA digest to prevent upstream breaking changes. Audit and document the unidentified `clustersecret` operator.
