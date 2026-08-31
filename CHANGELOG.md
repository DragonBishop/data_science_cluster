## [1.0.0] - 2026-08-31

### ◀️ Revert

- Drop loopback externalIPs Service (rejected by Kubernetes API)

### ♻️ Refactor

- Reorganize into manifests/ and scripts/ directories, expand start/stop-cluster.sh and postgis-cluster.yaml
- Improve sync-kubeconfig.sh clarity and validation checks
- Simplify sync-kubeconfig.sh, deploy Headlamp in-cluster instead of Windows client
- Simplify operator availability check in stop-cluster.sh
- Replace postgis-external-service with postgis-tcproute
- Move cluster scripts to src/bash/
- Clean up justfile, drop unnecessary settings file, use dynamic Cilium versioning
- Replace infrastructure/dns with coredns-custom internal DNS zone
- Consolidate DNS/gateway L2-LB policies into single LAN policy, enable gatewayAPI/egressGateway
- Clarify comments in postgis, gateway, hubble, namespace manifests
- Update TLS configurations and enhance Vault integration across cluster services
- Remove sync-kubeconfig.sh, kubeconfig now managed directly by k3s
- Move cluster-config from Kubernetes ConfigMap to Terraform-managed secret
- Consolidate vault-bootstrap and vault-database terraform into terraform/vault
- Consolidate gateway and hubble TLS issuance onto vault-pki-issuer
- Vault deployment and initialization
- Clean up comments and improve variable descriptions in Terraform configurations

### ⚙️ Miscellaneous Tasks

- Rename vso_setup.yaml to vso-setup.yaml
- Add .gitignore
- Archive legacy k3s manifests into k3s_archive/
- Rename k3s_archive/.vscode/tasks.json to .archive/, simplify devcontainer Dockerfile
- Archive superseded MinIO backups manifest
- Remove misplaced issue templates from .vscode/
- Convert GitHub issue templates from Markdown to YAML forms
- Remove old Markdown issue templates, superseded by YAML forms
- Remove .archive/, legacy pre-Flux manifests no longer needed
- Remove personal contact links from issue template config
- Sync copier template to v1.0.4
- Update uv.lock
- Trim comments in Kubernetes manifests and devcontainer config
- Trim comments in cluster scripts
- Remove unused postgres-proxy deployment from postgis-cluster.yaml
- Update uv.lock
- Add cluster naming support and reorganize install docs
- Restructure devcontainer setup with new host and cluster configurations
- *(dev)* Reorder justfile recipes, add prek hook setup, and sync dependencies
- Ignore rumdl cache and virtualenv directory variants in gitignore
- *(main)* Release 0.1.0
- *(main)* Release 1.0.0

### 🐛 Bug Fixes

- Insert env vars in vault-values.yaml, remove WSL-side extra copy in sync-kubeconfig.sh
- Restore trimmed devcontainer.json content
- Correct bug report issue form title/name fields
- Remove GitHub bug report YAML form (schema issue), consolidate gitignore into .gitignore
- Add schemas to postgis-database.yaml Database CRD
- Hubble health check in Cilium release
- Enable BPF masquerade in Cilium to prevent pod-to-host timeouts
- Grant NetworkPolicy baseline egress for apiserver, cluster, CoreDNS upstream
- S3/Barman TLS via Vault PKI (endpointCA, seaweedfs-s3-tls, HTTPS probes)
- Flux Kustomization dependsOn wiring for vault/cert-manager rollout
- Allow world-entity ingress to postgis on 5432
- Hubble.internal TLS verification (wrong SAN, wrong CA)

### 📚 Documentation

- Document kubeconfig sync workflow for Headlamp/Lens/VS Code access
- Rewrite README for CNPG/vault/script changes, add pipeline planning doc, remove main.py stub
- Add ROADMAP.md, remove pipeline.md, update README for new layout
- Clarify Cilium installation prerequisites and commands
- Expand ROADMAP foundational/ETL/ML sections, add notes on alternatives
- Update README with project roadmap, refine devcontainer and cluster scripts
- Update README and ROADMAP for clarity in Vault and k3s configurations
- Clarify systemd-to-script handover in README and cluster scripts
- Add SeaweedFS backup restore instructions, pre-flight validation, backup gitignore patterns
- Add first-time setup instructions, optional Headlamp installation
- Split docs into README/INSTALLATION/troubleshooting
- Add README table of contents, rename devcontainers/ to .devcontainer/
- Remove ROADMAP.md, shift to GitHub Issues for planning and tracking
- Update installation and troubleshooting guides; enhance clarity and modularity of cluster services
- Update troubleshooting and installation docs for DNS/cert changes
- Update installation and troubleshooting documentation; clarify steps for k3s reinstallation and Vault setup
- Update justfile description for clarity on setup commands
- Update troubleshooting docs for kubeconfig and cluster shutdown changes
- Update component descriptions and organization in README.md for clarity
- Update installation instructions and README for clarity; refine Terraform configurations and comments
- Update README/INSTALLATION for NetworkPolicy and secrets refactor
- Update INSTALLATION, README, and troubleshooting for Vault PKI rollout
- Document postgis-localhost.yaml and localRedirectPolicy
- Reference new justfile recipes in INSTALLATION.md and README.md
- Reference new bootstrap recipes, reorganize Cluster Operations table
- Reorganize install steps into 7a/7b, add table of contents
- Refactor setup and troubleshooting guides, fix rumdl config
- Enhance README for clarity and detail on cluster architecture and components

### 🚀 Features

- Add Falco runtime security scanning, initialize uv python project
- Add CNPG postgis-cluster manifest, add MinIO backups manifest, retire postgis-k3s.yaml
- Add transit-vault secrets (vault-values, vso_setup), retire vault-manifest.yaml
- Add start-cluster.sh, stop-cluster.sh, sync-kubeconfig.sh scripts
- Improve start-cluster.sh error handling and reporting
- Add CiliumNetworkPolicy for Vault ingress, dynamic host IP support
- Add VS Code task for Headlamp startup, update README/ROADMAP
- Add devcontainer Dockerfile and devcontainer.json, rename README_cluster.md to README.md
- Switch postgis-cluster to dynamic Vault secrets, add Barman/SeaweedFS backups
- Add GitHub issue form templates (misplaced under .vscode/)
- Add SeaweedFS backup restoration and pre-flight validation to README
- Add Cilium configuration
- Enhance cluster startup/shutdown scripts
- Add GitHub bug report issue form
- Add working GitHub issue templates (Markdown format)
- Add Gateway API CRDs Flux Kustomization
- Add namespaces Flux Kustomization
- Add cert-manager Flux Kustomization
- Move Cilium values into infrastructure/cilium/ for Flux
- Move Vault values into infrastructure/vault/ for Flux, drop old NetworkPolicy manifest
- Move postgis-cluster/postgres-tls/vso-setup into apps/databases/ for Flux
- Update seaweedfs backups manifest and cluster scripts for Flux migration
- Add Cilium Flux Kustomization and HelmRelease
- Replace vendored cert-manager CRD dump with Helm-based HelmRelease
- Add cert-manager namespace to infrastructure configuration
- Add Vault Flux Kustomization and HelmRelease
- Add Terraform vault-bootstrap module (auth, kv, encryption)
- Add CNPG operator and Vault Secrets Operator Flux Kustomizations and HelmReleases
- Add Barman Cloud Flux Kustomization and HelmRelease
- Add SeaweedFS Flux Kustomization and HelmRelease
- Add postgis-database Database CRD, simplify postgis-cluster.yaml Kustomization
- Add SeaweedFS NetworkPolicy restricting master/filer to databases namespace
- Add Terraform vault-database module
- Add external LoadBalancer service for postgis, Cilium L2 announcement policy and LB IP pool
- Add shared Gateway component with dedicated Cilium L2/LB policies
- Add dedicated DNS component with Cilium L2/LB policies
- Add dedicated Hubble component
- Add Hubble Relay/UI configuration, integrate with Cilium HelmRelease
- Initialize project via copier template (uv, pytest, CI, notebooks)
- Add ETL/ML python dependencies, remove placeholder report stubs
- Add Hubble Relay configuration and troubleshooting guidance for firewall settings
- Enhance documentation and tooling with Vault CLI commands
- Add kustomize configuration files for Cilium and Vault; update vault-values.yaml for environment variable handling
- Add cluster-config.yaml single source of truth, wire manifests via Flux postBuild substitution
- Add Terraform vault-transit-bootstrap module
- Enhance resource management across components, add Cilium NetworkPolicies for health checks
- Update retention policy for backups to 4 days and enhance Cilium network policies for SeaweedFS
- Add postgis CiliumNetworkPolicy
- Add vault CiliumNetworkPolicy
- Add vault-secrets-operator CiliumNetworkPolicy
- Add cnpg-operator CiliumNetworkPolicy
- Add clusterwide CiliumNetworkPolicy, rename flux-system allow-kubelet-probes to flux-networkpolicy
- Add Vault 2-tier PKI engine (root/intermediate CA, internal-server role)
- Add/extend CiliumNetworkPolicies for cert-manager, cnpg-operator, vault
- Add CNPG-managed localhost Service for postgis-cluster
- Enable Cilium localRedirectPolicy for node-local Service redirection
- Expose postgis-cluster primary on localhost:5432
- Add db-connect, vault-pf, and thin start/stop wrappers to justfile
- Add just status, a read-only cluster health check
- Add bootstrap recipes for k3s config, cluster network, Cilium, and Vault setup
- Add bootstrap scripts for cluster and Transit Vault setup
- Update dependencies and configurations across multiple components
- Enhance installation and bootstrap scripts with firewall and Vault improvements
- Enhance installation and bootstrap scripts with firewall and Vault improvements
- Add preflight readiness checks for host setup
- Refactor cluster configuration management and update installation scripts
- Add initial Ansible configuration and playbook for k3s cluster provisioning, update and regroup python dependencies
- Update Ansible tasks for Vault installation and configuration, including TLS setup and repository adjustments
- Add Ansible tasks for k3s installation and configuration
- Update configuration files to use environment variables for resource sizing and versions
- Add configuration files for cluster settings and resource sizing, including k3s installation tasks
- Update installation instructions and scripts to include envsubst for Cilium configuration
- Update Flux role to bootstrap GitHub repository and reconcile vault kustomization
- Add Ansible configuration and roles for Vault and k3s integration, including secret management and troubleshooting updates
- Update devcontainer and preflight scripts with environment configuration and tooling checks
- Refactor start and stop cluster scripts for improved k3s management and backup handling
- Refactor start and stop cluster scripts for improved error handling and process management
- Enhance preflight checks and improve cluster startup scripts for better error handling and pod readiness
- Update Cilium Helm values substitution method and enhance preflight checks; remove deprecated bootstrap script
- Remove notebooks and jupyter tooling to align with include_notebooks=false
- Add jsonpatch and kubernetes dependencies to project
- Add jsonpatch and kubernetes dependencies to project
- Implement firewall setup script for Kubernetes and Cilium
- Update firewall configuration and apply Cilium network policies
- Add release-please workflow and configuration files
