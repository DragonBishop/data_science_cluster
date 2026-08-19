# Project Roadmap

This roadmap outlines the evolution of the k3s cluster from a secure foundational baseline into a robust platform, with modular support for parallel Extract, Transform, Load (ETL) and Machine Learning (ML) workloads. The goal is to leverage lightweight, open-source services that integrate seamlessly with the existing eBPF networking, PostgreSQL, and storage infrastructure.

## Technical Debt

**1. Resource requests and limits** `postgis-cluster.yaml` sets requests/limits for the Postgres container and the `postgres-proxy` socat sidecar; every other component (Cilium, cert-manager, Vault, VSO, the CNPG operator, Barman Cloud, SeaweedFS, CoreDNS, Hubble Relay/UI) runs BestEffort. A resource spike in any of those has no ceiling and no guaranteed floor.

**2. NetworkPolicies require implemention:** `apps/databases/seaweedfs-networkpolicy.yaml` is the sole network policy in the repo. Postgres, Vault, VSO, cert-manager, the CNPG operator, and Barman Cloud all have unrestricted intra-cluster network access.

**3. Single Operator OpenTofu state:** `terraform/vault-bootstrap/` and `terraform/vault-database/` both use local, encrypted-at-rest state behind one passphrase securely. Fine for the current one-person setup; a second operator needs a real passphrase-distribution or remote-backend story before touching either module.

**4. Workloads Identity Federation:** Extending the existing Vault Kubernetes auth pattern (`postgis-role`) to Prefect workers and ML inference pods is useful to build as an ETL/ML-stage item, when the first Prefect worker or inference pod actually needs a scoped-down Service Account and Vault role.

*Note: Single-node HA is not part of the current build, but would be necessary for any multi-node expansion of this cluster.*
