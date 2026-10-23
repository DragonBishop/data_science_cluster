## [2.0.0] - 2026-10-12

### 🚀 Features

- Add CILIUM_HELM_RETRIES configuration for Helm installation retries
- [**breaking**] Replace Vault with OpenBao
- [**breaking**] Replace Vault Secrets Operator with External Secrets Operator
- *(network)* [**breaking**] Apply a default-deny baseline with named additional policies
- *(ansible)* Ask for the OpenBao root token up front, only when OpenBao is already initialized
- *(ansible)* Verify what terraform/openbao configured after each apply

### 🐛 Bug Fixes

- *(uninstall)* Leave bpffs mounted and require a reboot before reinstalling
- *(cilium)* Audit network policy and add LocalDirectPolicy for bao
- *(ansible)* Prompt for the OpenBao root token when none is available
- *(ansible)* Stop reporting changes on every bootstrap re-run
- *(k3s)* Give the bootstrap user write access to the kubeconfig
- Update e2e workflow and sync tasks to use FLUX_GIT_BRANCH for dynamic branch handling

### ♻️ Refactor

- *(ansible)* Build cluster_config from the patch files listed in kustomization.yaml
- *(ansible)* Split each role's tasks into named task files
- *(ansible)* Move the roles into the collection data_science.cluster

### ⚙️ Miscellaneous Tasks

- *(molecule)* Start Molecule testing of the bootstrap playbook
- *(molecule)* Run role scenarios against one shared podman container
- *(molecule)* Run the bootstrap playbook as the default scenario
- *(ansible)* Take collections from the ansible package and lint from the project
- *(molecule)* Add unit-k3s-config, the first role unit scenario
- *(molecule)* Add unit-k3s-stale-cilium-dir
- *(molecule)* Add unit-openbao-keyfile
- *(molecule)* Add unit-openbao-no-passphrase
- *(molecule)* Add unit-k3s-stale-cilium-interface
- *(molecule)* Add unit-opentofu
- *(e2e)* Bootstrap a cluster from the integration scenario on pull requests
- *(release)* Keep the ansible collection version in step with the cluster
## [1.2.0] - 2026-10-01

### ♻️ Refactor

- Centralize secret prompts in vars_prompt, allow seaweedfs.github.io egress
- Move environment-specific values into cluster-config
## [1.1.0] - 2026-09-07

### 🚀 Features

- Implement k3s Data Science Cluster provisioning and update Flux tasks for GitHub App integration

### 🐛 Bug Fixes

- *(ansible)* Migrate ansible_env to ansible_facts, pause on vault secrets, drop flux wait conditions
- *(ansible)* Update KUBECONFIG default path to use ansible_facts for consistency
- *(bootstrap)* Make one-command cluster bootstrap reliable
## [1.0.0] - 2026-08-31

### 🚀 Features

- Add jsonpatch and kubernetes dependencies and their preflight checks
- *(ansible)* Add k3s installation tasks to the k3s role
- Implement firewall setup script for Kubernetes and Cilium
- Update firewall configuration and apply Cilium network policies
## [0.6.0] - 2026-08-30

### 🚀 Features

- Add initial Ansible configuration and playbook for k3s cluster provisioning, update and regroup python dependencies
- Update Ansible tasks for Vault installation and configuration, including TLS setup and repository adjustments
- Add Ansible tasks for k3s installation and configuration
- Add configuration files for cluster settings and resource sizing, including k3s installation tasks
- Update installation instructions and scripts to include envsubst for Cilium configuration
- Update Flux role to bootstrap GitHub repository and reconcile vault kustomization
- Add Ansible configuration and roles for Vault and k3s integration, including secret management and troubleshooting updates
- Update Cilium Helm values substitution method and enhance preflight checks; remove deprecated bootstrap script

### ♻️ Refactor

- *(vault)* Consolidate Vault deployment and initialization into the bootstrap
- Clean up comments and improve variable descriptions in Terraform configurations

### ⚙️ Miscellaneous Tasks

- Remove notebooks and jupyter tooling to match include_notebooks=false
