## [unreleased]

### 🚀 Features

- Add CILIUM_HELM_RETRIES configuration for Helm installation retries
- [**breaking**] Replace Vault with OpenBao
- [**breaking**] Replace Vault Secrets Operator with External Secrets Operator
- *(network)* [**breaking**] Apply a default-deny baseline with named additional policies
- *(preflight)* Enhance kubectl checks and version validation in preflight script
- *(tekton)* Add Tekton results database and update kustomization
- *(tofu)* Add Tekton results role and policy for database access
- *(tekton)* Add Tekton Results secrets and configuration for OpenBao integration
- *(tekton)* Add TLS certificate configuration for Tekton Results API
- *(tekton)* Update Tekton Results configuration and network policy for database access
- *(tekton)* Mint new Tekton Results database credentials on every pod start
- *(ansible)* Ask for the OpenBao root token up front, only when OpenBao is already initialized
- *(ansible)* Verify what terraform/openbao configured after each apply

### 🐛 Bug Fixes

- *(uninstall)* Leave bpffs mounted and require a reboot before reinstalling
- *(flux)* Apply ESO secrets and Cilium Helm values before their consumers
- *(seaweedfs)* Keep master and filer data under SEAWEEDFS_HOST_PATH
- *(cilium)* Audit network policy and add LocalDirectPolicy for bao
- *(just)* Keep the PostgreSQL root certificate under ~/.config/postgresql
- *(ansible)* Prompt for the OpenBao root token when none is available
- *(flux)* Reconcile SeaweedFS before databases so the backup bucket exists first
- *(ansible)* Stop reporting changes on every bootstrap re-run
- *(flux)* Deploy the dynamic PostGIS credentials with postgis-cluster

### 📚 Documentation

- Document OpenBao and External Secrets Operator
- *(tekton)* Describe the Tekton Results database
- Describe the cluster-config patch files, group_vars/all/ and Galaxy collections

### ♻️ Refactor

- *(cluster-config)* Split the ConfigMap into one patch file per kind of value
- *(ansible)* Build cluster_config from the patch files listed in kustomization.yaml
- *(ansible)* Split each role's tasks into named task files
- *(ansible)* Move the roles into the collection data_science.cluster

### ⚙️ Miscellaneous Tasks

- *(flux)* Pin flux-system to the openbao branch to test the cluster rollout
- *(tekton)* Remove Tekton Chains
- *(molecule)* Start Molecule testing of the bootstrap playbook
- *(tests)* Check cluster-config drift by running flux build and Ansible instead of parsing files
- *(molecule)* Run role scenarios against one shared podman container
- *(molecule)* Run the bootstrap playbook as the default scenario
- *(ansible)* Take collections from the ansible package and lint from the project
- *(molecule)* Add unit-k3s-config, the first role unit scenario
- *(molecule)* Add unit-k3s-stale-cilium-dir
- *(molecule)* Add unit-openbao-keyfile
- *(molecule)* Add unit-openbao-no-passphrase
- *(molecule)* Add unit-k3s-stale-cilium-interface
- *(molecule)* Add unit-opentofu
- Run ansible-lint and the Molecule unit scenarios on pull requests
- *(e2e)* Bootstrap a cluster from the integration scenario on pull requests
- *(release)* Keep the ansible collection version in step with the cluster

### ◀️ Revert

- *(flux)* Unpin flux-system from the openbao branch
## [1.2.0] - 2026-10-01

### 🚀 Features

- Add Tekton operator configuration and resource definitions
- Update egress rules in CiliumNetworkPolicy for improved FQDN matching
- Add TektonConfig with Pipelines, Triggers, and Chains
- Sign Tekton Chains artifacts with Vault Transit
- Add tests for Flux-substituted manifests and cluster-config validation

### ♻️ Refactor

- Centralize secret prompts in vars_prompt, allow seaweedfs.github.io egress
- Move environment-specific values into cluster-config

### ⚙️ Miscellaneous Tasks

- Rename package to pgiscluster and prune unused dependencies
- Remove unused modules and update test descriptions
- Update project configuration and dependencies for data_science_cluster
- Bump cluster resource versions, use GitHub App token for release workflow
- Sync project metadata and tooling with copier template
- Adopt copier template v1.7.0 and generate changelog in release PR
- Update Copier version to v1.7.2
## [1.1.0] - 2026-09-07

### 🚀 Features

- Add GitHub workflows for linting, testing, and release management
- Implement k3s Data Science Cluster provisioning and update Flux tasks for GitHub App integration
- *(uninstall)* Add 'just uninstall' command and script to tear down k3s and clear local state

### 🐛 Bug Fixes

- *(ansible)* Migrate ansible_env to ansible_facts, pause on vault secrets, drop flux wait conditions
- *(ansible)* Update KUBECONFIG default path to use ansible_facts for consistency
- *(bootstrap)* Make one-command cluster bootstrap reliable

### 📚 Documentation

- Update the GitHub authentication instructions, add a GitHub App preflight check
## [1.0.1] - 2026-08-31

### ⚙️ Miscellaneous Tasks

- Use dedicated PAT for release-please instead of repo Actions permission
## [1.0.0] - 2026-08-31

### 🚀 Features

- Add jsonpatch and kubernetes dependencies and their preflight checks
- *(ansible)* Add k3s installation tasks to the k3s role
- Implement firewall setup script for Kubernetes and Cilium
- Update firewall configuration and apply Cilium network policies
- Add release-please workflow and configuration files

### ⚙️ Miscellaneous Tasks

- *(flux)* Upgrade Flux to v2.9.4
## [0.6.0] - 2026-08-30

### 🚀 Features

- Add bootstrap scripts for cluster and Transit Vault setup
- Improve firewall and Vault handling in the bootstrap scripts, remove the notebooks
- Improve firewall and Vault handling in the bootstrap scripts
- Add preflight readiness checks for host setup
- Add initial Ansible configuration and playbook for k3s cluster provisioning, update and regroup python dependencies
- Update Ansible tasks for Vault installation and configuration, including TLS setup and repository adjustments
- Add Ansible tasks for k3s installation and configuration
- Update configuration files to use environment variables for resource sizing and versions
- Add configuration files for cluster settings and resource sizing, including k3s installation tasks
- Update installation instructions and scripts to include envsubst for Cilium configuration
- Update Flux role to bootstrap GitHub repository and reconcile vault kustomization
- Add Ansible configuration and roles for Vault and k3s integration, including secret management and troubleshooting updates
- Update devcontainer and preflight scripts with environment configuration and tooling checks
- Enhance preflight checks and improve cluster startup scripts for better error handling and pod readiness
- Update Cilium Helm values substitution method and enhance preflight checks; remove deprecated bootstrap script

### 📚 Documentation

- Refactor setup and troubleshooting guides, fix rumdl config
- Enhance README for clarity and detail on cluster architecture and components

### ♻️ Refactor

- Give cluster-config its own Flux Kustomization and update the install scripts
- *(vault)* Consolidate Vault deployment and initialization into the bootstrap
- Clean up comments and improve variable descriptions in Terraform configurations
- Rework the start and stop cluster scripts for k3s management and backups
- Improve error handling and process management in the start and stop cluster scripts

### ⚙️ Miscellaneous Tasks

- Add cluster naming support and reorganize install docs
- Restructure devcontainer setup with new host and cluster configurations
- Bump PostGIS, SeaweedFS, Flux, Vault, VSO, Cilium and Terraform provider versions
- *(dev)* Reorder justfile recipes, add prek hook setup, and sync dependencies
- Ignore rumdl cache and virtualenv directory variants in gitignore
- Remove notebooks and jupyter tooling to match include_notebooks=false
## [0.5.0] - 2026-08-21

### 🚀 Features

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

### 🐛 Bug Fixes

- Grant NetworkPolicy baseline egress for apiserver, cluster, CoreDNS upstream
- S3/Barman TLS via Vault PKI (endpointCA, seaweedfs-s3-tls, HTTPS probes)
- Flux Kustomization dependsOn wiring for vault/cert-manager rollout
- Allow world-entity ingress to postgis on 5432
- Hubble.internal TLS verification (wrong SAN, wrong CA)

### 📚 Documentation

- Update README/INSTALLATION for NetworkPolicy and secrets refactor
- Update INSTALLATION, README, and troubleshooting for Vault PKI rollout
- Document postgis-localhost.yaml and localRedirectPolicy
- Reference new justfile recipes in INSTALLATION.md and README.md
- Reference new bootstrap recipes, reorganize Cluster Operations table
- Reorganize install steps into 7a/7b, add table of contents

### ♻️ Refactor

- Move cluster-config from Kubernetes ConfigMap to Terraform-managed secret
- Consolidate vault-bootstrap and vault-database terraform into terraform/vault
- Consolidate gateway and hubble TLS issuance onto vault-pki-issuer

### ⚙️ Miscellaneous Tasks

- Prune unused packages from uv.lock
- Trim comments in Kubernetes manifests and devcontainer config
- Trim comments in cluster scripts
- Remove unused postgres-proxy deployment from postgis-cluster.yaml
- Refresh uv.lock

### ◀️ Revert

- Drop loopback externalIPs Service (rejected by Kubernetes API)
## [0.4.0] - 2026-08-13

### 🚀 Features

- Add kustomize configuration files for Cilium and Vault; update vault-values.yaml for environment variable handling
- Add cluster-config.yaml single source of truth, wire manifests via Flux postBuild substitution
- Add Terraform vault-transit-bootstrap module
- Enhance resource management across components, add Cilium NetworkPolicies for health checks
- Update retention policy for backups to 4 days and enhance Cilium network policies for SeaweedFS

### 📚 Documentation

- Remove ROADMAP.md, shift to GitHub Issues for planning and tracking
- Update installation and troubleshooting guides; enhance clarity and modularity of cluster services
- Update troubleshooting and installation docs for DNS/cert changes
- Update installation and troubleshooting documentation; clarify steps for k3s reinstallation and Vault setup
- Update justfile description for clarity on setup commands
- Update troubleshooting docs for kubeconfig and cluster shutdown changes
- Update component descriptions and organization in README.md for clarity
- Update installation instructions and README for clarity; refine Terraform configurations and comments

### ♻️ Refactor

- Replace infrastructure/dns with coredns-custom internal DNS zone
- Consolidate DNS/gateway L2-LB policies into single LAN policy, enable gatewayAPI/egressGateway
- Clarify comments in postgis, gateway, hubble, namespace manifests
- Update TLS configurations and enhance Vault integration across cluster services
- Remove sync-kubeconfig.sh, kubeconfig now managed directly by k3s

### ⚙️ Miscellaneous Tasks

- Add ML orchestration dependencies
## [0.3.0] - 2026-08-05

### 🚀 Features

- *(flux)* Add Flux v2.9.3 component manifests
- *(flux)* Add Flux sync manifests
- Add Gateway API CRDs Flux Kustomization
- Add namespaces Flux Kustomization
- Add cert-manager Flux Kustomization
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
- Add Hubble Relay configuration and troubleshooting guidance for firewall settings
- Add the Vault CLI to the devcontainer and justfile

### 🐛 Bug Fixes

- Add schemas to postgis-database.yaml Database CRD
- Hubble health check in Cilium release
- Enable BPF masquerade in Cilium to prevent pod-to-host timeouts

### 📚 Documentation

- Split docs into README/INSTALLATION/troubleshooting
- Add README table of contents, rename devcontainers/ to .devcontainer/

### ♻️ Refactor

- *(flux)* Move Cilium values into infrastructure/cilium/
- *(flux)* Move Vault values into infrastructure/vault/, drop the old NetworkPolicy manifest
- *(flux)* Move postgis-cluster, postgres-tls and vso-setup into apps/databases/
- Simplify operator availability check in stop-cluster.sh
- Replace postgis-external-service with postgis-tcproute
- Move cluster scripts to src/bash/
- Clean up justfile, drop unnecessary settings file, use dynamic Cilium versioning

### ⚙️ Miscellaneous Tasks

- Convert GitHub issue templates from Markdown to YAML forms
- Remove old Markdown issue templates, superseded by YAML forms
- Remove .archive/, legacy pre-Flux manifests no longer needed
- Initialize the project from the copier template
- Add ETL/ML Python dependencies, remove placeholder report stubs
- Remove personal contact links from issue template config
- Sync copier template to v1.0.4
## [0.2.0] - 2026-08-02

### 🚀 Features

- Switch postgis-cluster to dynamic Vault secrets, add Barman/SeaweedFS backups
- Add SeaweedFS backup restoration and pre-flight validation to README
- Add Cilium configuration
- Enhance cluster startup/shutdown scripts

### 🐛 Bug Fixes

- Restore trimmed devcontainer.json content
- Correct bug report issue form title/name fields
- Remove GitHub bug report YAML form (schema issue), consolidate gitignore into .gitignore

### 📚 Documentation

- Update README with project roadmap, refine devcontainer and cluster scripts
- Update README and ROADMAP for clarity in Vault and k3s configurations
- Clarify systemd-to-script handover in README and cluster scripts
- Add SeaweedFS backup restore instructions, pre-flight validation, backup gitignore patterns
- Add first-time setup instructions, optional Headlamp installation

### ⚙️ Miscellaneous Tasks

- Rename k3s_archive/.vscode/tasks.json to .archive/, simplify devcontainer Dockerfile
- Archive superseded MinIO backups manifest
- Add GitHub issue form templates
- Remove misplaced issue templates from .vscode/
- Add a GitHub bug report issue form
- Add GitHub issue templates in Markdown format
## [0.1.0] - 2026-07-24

### 🚀 Features

- Create the repository with the PostgreSQL/PostGIS stack and setup README
- Add Falco runtime security scanning, initialize uv python project
- Add CNPG postgis-cluster manifest, add MinIO backups manifest, retire postgis-k3s.yaml
- Add transit-vault secrets (vault-values, vso_setup), retire vault-manifest.yaml
- Add start-cluster.sh, stop-cluster.sh, sync-kubeconfig.sh scripts
- Improve start-cluster.sh error handling and reporting
- Add CiliumNetworkPolicy for Vault ingress, dynamic host IP support
- Add VS Code task for Headlamp startup, update README/ROADMAP
- Add devcontainer Dockerfile and devcontainer.json, rename README_cluster.md to README.md

### 🐛 Bug Fixes

- Insert env vars in vault-values.yaml, remove WSL-side extra copy in sync-kubeconfig.sh

### 📚 Documentation

- Document kubeconfig sync workflow for Headlamp/Lens/VS Code access
- Rewrite README for CNPG/vault/script changes, add pipeline planning doc, remove main.py stub
- Add ROADMAP.md, remove pipeline.md, update README for new layout
- Clarify Cilium installation prerequisites and commands
- Expand ROADMAP foundational/ETL/ML sections, add notes on alternatives

### ♻️ Refactor

- Reorganize into manifests/ and scripts/ directories, expand start/stop-cluster.sh and postgis-cluster.yaml
- Improve sync-kubeconfig.sh clarity and validation checks
- Simplify sync-kubeconfig.sh, deploy Headlamp in-cluster instead of Windows client

### ⚙️ Miscellaneous Tasks

- Rename vso_setup.yaml to vso-setup.yaml
- Add .gitignore
- Archive legacy k3s manifests into k3s_archive/
