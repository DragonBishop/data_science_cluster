## [2.4.1](https://github.com/DragonBishop/data_science_cluster/compare/v2.4.0...v2.4.1) - 2026-11-01

### 🐛 Bug Fixes

- *(cert-manager)* Restrict issuer token requests (#78) ([3debe69](https://github.com/DragonBishop/data_science_cluster/commit/3debe69da1425e09f1bd51b3febd0fa5e215828a))
- *(gateway)* Use cluster.internal for shared TLS ([098b9d7](https://github.com/DragonBishop/data_science_cluster/commit/098b9d74962afc847e71825d16d9eb6622ab3b75))
- *(gateway)* Require namespace approval for routes ([77c4076](https://github.com/DragonBishop/data_science_cluster/commit/77c4076068c13e95dc8693d3e1195424bb0003b0))
- *(pki)* Constrain the shared certificate signing profile ([d0ba4ac](https://github.com/DragonBishop/data_science_cluster/commit/d0ba4acacabd5c750f2c33df8c51c6b17eee8b50))
- *(security)* Remove cached OpenBao login and consolidate access policy ([2ffc29d](https://github.com/DragonBishop/data_science_cluster/commit/2ffc29df795e3138cc5f5255d13376c344459221))
- *(csi)* Use kubelet tokens for OpenBao mounts ([d4cc242](https://github.com/DragonBishop/data_science_cluster/commit/d4cc242e353eeed0413d645a3bdd5cc77c438594))

### ♻️ Refactor

- *(tests)* Simplify cluster integration verification ([4dfd2e4](https://github.com/DragonBishop/data_science_cluster/commit/4dfd2e41d7dafaa51dc215434ec169c4ddf5b96a))

## [2.4.0](https://github.com/DragonBishop/data_science_cluster/compare/v2.3.0...v2.4.0) - 2026-10-30

### 🚀 Features

- *(openbao)* Remove the rotate-credentials CronJob ([388a208](https://github.com/DragonBishop/data_science_cluster/commit/388a20813eb9ff0117010b3c33b16d41e23632a6))
- *(openbao)* Run the CSI provider and download the secrets-aws plugin ([d5ea03c](https://github.com/DragonBishop/data_science_cluster/commit/d5ea03c75c3535642599c7aeba972f9bd9f6a10a))
- *(openbao)* Manage Barman's SeaweedFS key pairs and the CSI logins ([a26df4a](https://github.com/DragonBishop/data_science_cluster/commit/a26df4a28088fdb9c9a0a8995cfafaabfbd0078d))

### 🐛 Bug Fixes

- *(ansible)* Apply the baseline network policy before the workloads installed ahead of Flux ([2672397](https://github.com/DragonBishop/data_science_cluster/commit/2672397415d03055679f02d239ef222d940c64a5))
- *(e2e)* Stabilize OpenBao PKI and Postgres verification ([660d4f6](https://github.com/DragonBishop/data_science_cluster/commit/660d4f6a863a3fdfabbf66fc91fd8cd8f98c3a7b))

### 📚 Documentation

- Describe login delivery through the Secrets Store CSI driver ([f81d08d](https://github.com/DragonBishop/data_science_cluster/commit/f81d08d298d1237f957487cc71aa1ee47d1d4dfe))

## [2.3.0](https://github.com/DragonBishop/data_science_cluster/compare/v2.2.0...v2.3.0) - 2026-10-29

### 🚀 Features

- *(seaweedfs)* Serve HTTPS between master, filer, volume and S3 ([4435fc5](https://github.com/DragonBishop/data_science_cluster/commit/4435fc59dd16a2fcb2732a072ff70c27c79cd5aa))

### 🧪 Testing

- *(opentofu)* Check the cert auth roles and the SPIRE server role ([ac1e54a](https://github.com/DragonBishop/data_science_cluster/commit/ac1e54a92e5b4a42908ee298e61394ee9ff00447))

## [2.2.0](https://github.com/DragonBishop/data_science_cluster/compare/v2.1.0...v2.2.0) - 2026-10-28

### 🚀 Features

- *(ansible)* Install cert-manager, trust-manager and OpenBao before Flux ([a033afa](https://github.com/DragonBishop/data_science_cluster/commit/a033afa0d33ffd42d6adeece61d6ab3d2e626918))
- *(spire)* Install SPIRE before Flux with its CA signed by OpenBao's root ([d949ec1](https://github.com/DragonBishop/data_science_cluster/commit/d949ec1f6d344fc4a21a3aad7ba546a9bba54b6e))
- *(flux)* Require SPIFFE mTLS between the Flux controllers ([26bf0cc](https://github.com/DragonBishop/data_science_cluster/commit/26bf0cc3798659f2058abc4827bde1311dbf2902))
- *(openbao)* Replace ESO with SVID logins and a daily rotate-credentials CronJob ([ad2e98b](https://github.com/DragonBishop/data_science_cluster/commit/ad2e98b85bb98120aa2a42d67877b8c18ef8b6d6))

### ♻️ Refactor

- Standardize PostgreSQL names and reorganize Tekton resources ([471e532](https://github.com/DragonBishop/data_science_cluster/commit/471e532b470b538b97b56a21e5f7d61ed3bcf2d3))
- *(flux)* One policy file per namespace and role-based file names ([4a2fa3e](https://github.com/DragonBishop/data_science_cluster/commit/4a2fa3e95ba24289744e6823a37b0a514fb93b54))
- *(tekton)* Split Tekton into the tekton, tekton-triggers and tekton-pipelines namespaces ([519d5d2](https://github.com/DragonBishop/data_science_cluster/commit/519d5d2dba961a149d4a48cb15de64dac5a77052))
- *(ansible)* Substitute values with flux envsubst and parse OpenBao output once ([fefd895](https://github.com/DragonBishop/data_science_cluster/commit/fefd89531d7411dbf360b1b9d00a0127fc848d59))

### 🧪 Testing

- *(molecule)* Check cluster-config drift on the live full-playbook install ([b41f210](https://github.com/DragonBishop/data_science_cluster/commit/b41f2105a5cf8fed81d8f7c140e120cce538f0cc))
- *(molecule)* Template the trust base charts and check SPIRE's CA and Flux adoption ([932f017](https://github.com/DragonBishop/data_science_cluster/commit/932f017c04d1c3addcb1483dcd259492c2c6ba40))

## [2.1.0](https://github.com/DragonBishop/data_science_cluster/compare/v2.0.0...v2.1.0) - 2026-10-23

### 🚀 Features

- *(cilium)* Receivers name every caller, from their own namespace too ([f9de257](https://github.com/DragonBishop/data_science_cluster/commit/f9de257696844ddb1ea5479d172d829aecb7ce60))

### 🐛 Bug Fixes

- *(ansible-lint)* Lint the collection offline from the repository root ([e5c8f9e](https://github.com/DragonBishop/data_science_cluster/commit/e5c8f9ebcee48004594171a59d562e15ebfa9de7))
- *(cilium)* Keep the API port in cluster-default a string ([3af4df8](https://github.com/DragonBishop/data_science_cluster/commit/3af4df8cd8981541c79a428b3e906129ffc6dbcd))

### 📚 Documentation

- *(ansible)* Ready the collection for Galaxy ([a6978aa](https://github.com/DragonBishop/data_science_cluster/commit/a6978aae698ad03c2c75dab1745a8fce18e5035a))

### ♻️ Refactor

- *(ansible)* Rename the collection to dragonbishop.cluster ([1347deb](https://github.com/DragonBishop/data_science_cluster/commit/1347debee2438f7f1a56e6a85047899b5626b8c1))
- *(ansible)* Move the playbook, its variables and the full-playbook scenario into the collection ([c710331](https://github.com/DragonBishop/data_science_cluster/commit/c710331e4648d1bcdd4ae642c3165cd3c1cf5956))
- *(cilium)* Name each policy after its workload ([bac6d31](https://github.com/DragonBishop/data_science_cluster/commit/bac6d31c4c7dbc1ad46f7589c2275183ed8da8ce))

### ⚙️ Miscellaneous Tasks

- Remove gateway_api_version from cluster_config ([fb191c1](https://github.com/DragonBishop/data_science_cluster/commit/fb191c19bf62b17699d8a6fe64948e4917b52b3e))
- *(release)* Generate the collection's CHANGELOG.md with git-cliff ([4a250b8](https://github.com/DragonBishop/data_science_cluster/commit/4a250b8907a94ad6dfd8c760fcf3f1b79c8bfbe5))

## [2.0.0](https://github.com/DragonBishop/data_science_cluster/compare/v1.2.0...v2.0.0) - 2026-10-12

### 🚀 Features

- Add CILIUM_HELM_RETRIES configuration for Helm installation retries ([0400fed](https://github.com/DragonBishop/data_science_cluster/commit/0400fed664f9cfa0ef42c6681c3f0277737e16c3))
- [**breaking**] Replace Vault with OpenBao ([f44929d](https://github.com/DragonBishop/data_science_cluster/commit/f44929df60fdcc0fb428f5bc27f710fbe64725e1))
- [**breaking**] Replace Vault Secrets Operator with External Secrets Operator ([75b4f43](https://github.com/DragonBishop/data_science_cluster/commit/75b4f432ea23d467c0b0973bac784655b56b6003))
- *(network)* [**breaking**] Apply a default-deny baseline with named additional policies ([c8d65c3](https://github.com/DragonBishop/data_science_cluster/commit/c8d65c345c88c838e17afc73ee29fe5d000e4615))
- *(ansible)* Ask for the OpenBao root token up front, only when OpenBao is already initialized ([19fe99b](https://github.com/DragonBishop/data_science_cluster/commit/19fe99b5f4c41c6f2509d9585b70fea3d89e9e4e))
- *(ansible)* Verify what terraform/openbao configured after each apply ([7739979](https://github.com/DragonBishop/data_science_cluster/commit/7739979284344bad718fca176943e56cebd51ae1))

### 🐛 Bug Fixes

- *(uninstall)* Leave bpffs mounted and require a reboot before reinstalling ([79c38c5](https://github.com/DragonBishop/data_science_cluster/commit/79c38c5caa4fcd13ff61431668fd8f7f3df51e45))
- *(cilium)* Audit network policy and add LocalDirectPolicy for bao ([e2c8107](https://github.com/DragonBishop/data_science_cluster/commit/e2c8107d4ef28f39ac267ca2fc47a4e2ebb17cd7))
- *(ansible)* Prompt for the OpenBao root token when none is available ([0a74cd0](https://github.com/DragonBishop/data_science_cluster/commit/0a74cd029034c1ebd5b377d4530c0a2fe93303cb))
- *(ansible)* Stop reporting changes on every bootstrap re-run ([a5130c1](https://github.com/DragonBishop/data_science_cluster/commit/a5130c14727f9b6cd0e5d62ff3408ce0d2200344))
- *(k3s)* Give the bootstrap user write access to the kubeconfig ([78aa602](https://github.com/DragonBishop/data_science_cluster/commit/78aa602cbeec71d5870c149bc356a87b7581fcac))
- Update e2e workflow and sync tasks to use FLUX_GIT_BRANCH for dynamic branch handling ([b13358f](https://github.com/DragonBishop/data_science_cluster/commit/b13358fce158e06de6687e10305bd4db7fc58b74))

### ♻️ Refactor

- *(ansible)* Build cluster_config from the patch files listed in kustomization.yaml ([b03f4bf](https://github.com/DragonBishop/data_science_cluster/commit/b03f4bf128f99733a91af83a58174def3643972b))
- *(ansible)* Split each role's tasks into named task files ([ebefa04](https://github.com/DragonBishop/data_science_cluster/commit/ebefa04f7f410111324b545299b25f49a67e92d1))
- *(ansible)* Move the roles into the collection data_science.cluster ([2c02fef](https://github.com/DragonBishop/data_science_cluster/commit/2c02fef4a87657037dce331ca1909204fc171260))

### ⚙️ Miscellaneous Tasks

- *(molecule)* Start Molecule testing of the bootstrap playbook ([47b4a4b](https://github.com/DragonBishop/data_science_cluster/commit/47b4a4b2242431e1678851c231e47551f1e9ee4a))
- *(molecule)* Run role scenarios against one shared podman container ([66e3236](https://github.com/DragonBishop/data_science_cluster/commit/66e32367074815aa887afb2c8eadce0091c823c1))
- *(molecule)* Run the bootstrap playbook as the default scenario ([61f1052](https://github.com/DragonBishop/data_science_cluster/commit/61f10527f326d7ecad7cc899ff7d10cdc47d31b2))
- *(ansible)* Take collections from the ansible package and lint from the project ([c72ceed](https://github.com/DragonBishop/data_science_cluster/commit/c72ceedee65cdb25d023ecec95a46514bbcd712c))
- *(molecule)* Add unit-k3s-config, the first role unit scenario ([3c8894a](https://github.com/DragonBishop/data_science_cluster/commit/3c8894ad3cc33fa9db5ab25849a581e5160fa07b))
- *(molecule)* Add unit-k3s-stale-cilium-dir ([4a4509b](https://github.com/DragonBishop/data_science_cluster/commit/4a4509bf5b3587533ca5737bcb971ca101f41c7f))
- *(molecule)* Add unit-openbao-keyfile ([30018b5](https://github.com/DragonBishop/data_science_cluster/commit/30018b59662226fe9037b1c1171c21525dfc5391))
- *(molecule)* Add unit-openbao-no-passphrase ([c63540c](https://github.com/DragonBishop/data_science_cluster/commit/c63540cdebde2523d70035ddf0fc6a1f06df6f93))
- *(molecule)* Add unit-k3s-stale-cilium-interface ([efe08ea](https://github.com/DragonBishop/data_science_cluster/commit/efe08ea2122aacb629411804ca4ea3939b9cbe4a))
- *(molecule)* Add unit-opentofu ([4da5306](https://github.com/DragonBishop/data_science_cluster/commit/4da53060d39318f62ae4ec3dc7ea40a30ab2e380))
- *(e2e)* Bootstrap a cluster from the integration scenario on pull requests ([ce9977b](https://github.com/DragonBishop/data_science_cluster/commit/ce9977bff2110a5cb04b9807f3f7e6721d9aab05))
- *(release)* Keep the ansible collection version in step with the cluster ([91cb374](https://github.com/DragonBishop/data_science_cluster/commit/91cb374fb5e5764884cf1a769202031f2d9f7547))

## [1.2.0](https://github.com/DragonBishop/data_science_cluster/compare/v1.1.0...v1.2.0) - 2026-10-01

### ♻️ Refactor

- Centralize secret prompts in vars_prompt, allow seaweedfs.github.io egress ([7ef5bd2](https://github.com/DragonBishop/data_science_cluster/commit/7ef5bd2536d9400a7ccf28faa31a1b3389720953))
- Move environment-specific values into cluster-config ([fdf9304](https://github.com/DragonBishop/data_science_cluster/commit/fdf930413b19522742f0b7d9e810aceca4a9db4a))

## [1.1.0](https://github.com/DragonBishop/data_science_cluster/compare/v1.0.1...v1.1.0) - 2026-09-07

### 🚀 Features

- Implement k3s Data Science Cluster provisioning and update Flux tasks for GitHub App integration ([b5f39b9](https://github.com/DragonBishop/data_science_cluster/commit/b5f39b9b7d17eb8a2ca390f4f8a27a27e834dabd))

### 🐛 Bug Fixes

- *(ansible)* Migrate ansible_env to ansible_facts, pause on vault secrets, drop flux wait conditions ([0b4db0e](https://github.com/DragonBishop/data_science_cluster/commit/0b4db0eb1b7b0dccf5cde13eeed700b883a62b9d))
- *(ansible)* Update KUBECONFIG default path to use ansible_facts for consistency ([cef26d5](https://github.com/DragonBishop/data_science_cluster/commit/cef26d575898787ffb4fe1425d317e18a2863bfa))
- *(bootstrap)* Make one-command cluster bootstrap reliable ([370cde9](https://github.com/DragonBishop/data_science_cluster/commit/370cde91a15dc62eeb9064fda1f2d54d91aecacc))

## [1.0.0](https://github.com/DragonBishop/data_science_cluster/compare/v0.6.0...v1.0.0) - 2026-08-31

### 🚀 Features

- Add jsonpatch and kubernetes dependencies and their preflight checks ([58876ab](https://github.com/DragonBishop/data_science_cluster/commit/58876ab5cfe281d5ced8a44439e9c1173f583afc))
- *(ansible)* Add k3s installation tasks to the k3s role ([7173d93](https://github.com/DragonBishop/data_science_cluster/commit/7173d93f1be74cd6d29f8072714d2fb59a7334af))
- Implement firewall setup script for Kubernetes and Cilium ([5173724](https://github.com/DragonBishop/data_science_cluster/commit/5173724ac3c02b20c379b5e61c45bb1a04abc2d3))
- Update firewall configuration and apply Cilium network policies ([7cecc7a](https://github.com/DragonBishop/data_science_cluster/commit/7cecc7a8337f839b32ef981d5cac047c3ff9b08c))

## [0.6.0](https://github.com/DragonBishop/data_science_cluster/compare/v0.5.0...v0.6.0) - 2026-08-30

### 🚀 Features

- Add initial Ansible configuration and playbook for k3s cluster provisioning, update and regroup python dependencies ([e60bacd](https://github.com/DragonBishop/data_science_cluster/commit/e60bacd65a59addc952a5adeb7f9968288122238))
- Update Ansible tasks for Vault installation and configuration, including TLS setup and repository adjustments ([9916f92](https://github.com/DragonBishop/data_science_cluster/commit/9916f92371f288ff1214554d8527e397554c2ca8))
- Add Ansible tasks for k3s installation and configuration ([05e7809](https://github.com/DragonBishop/data_science_cluster/commit/05e7809ff0aeccb8213a43adc4a34770bf66d39f))
- Add configuration files for cluster settings and resource sizing, including k3s installation tasks ([ba39421](https://github.com/DragonBishop/data_science_cluster/commit/ba39421f48c6ad04509fb289d1fc5cb49347c84a))
- Update installation instructions and scripts to include envsubst for Cilium configuration ([ec8a1bf](https://github.com/DragonBishop/data_science_cluster/commit/ec8a1bf1cfdfa44e95499f407dd9c05ff74ecd59))
- Update Flux role to bootstrap GitHub repository and reconcile vault kustomization ([7788158](https://github.com/DragonBishop/data_science_cluster/commit/778815863ac55790738ae5f083c9beb768045b06))
- Add Ansible configuration and roles for Vault and k3s integration, including secret management and troubleshooting updates ([f814d81](https://github.com/DragonBishop/data_science_cluster/commit/f814d81f966ae664d40dc7c75f07f77604870e27))
- Update Cilium Helm values substitution method and enhance preflight checks; remove deprecated bootstrap script ([4e4805b](https://github.com/DragonBishop/data_science_cluster/commit/4e4805ba2fb2adff97dcda899d9d5e2206539a39))

### ♻️ Refactor

- *(vault)* Consolidate Vault deployment and initialization into the bootstrap ([07288c7](https://github.com/DragonBishop/data_science_cluster/commit/07288c7d98f119ec1ee1320844c5d361fcaea14f))
- Clean up comments and improve variable descriptions in Terraform configurations ([a0e571c](https://github.com/DragonBishop/data_science_cluster/commit/a0e571c3a8719d34be15a706149fa22947988ada))

### ⚙️ Miscellaneous Tasks

- Remove notebooks and jupyter tooling to match include_notebooks=false ([abb0dec](https://github.com/DragonBishop/data_science_cluster/commit/abb0decbf9bc52fb9a9872529725b9969f9410b6))

