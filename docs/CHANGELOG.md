## [2.4.1](https://github.com/DragonBishop/data_science_cluster/compare/v2.4.0...v2.4.1) - 2026-10-31

### 🐛 Bug Fixes

- Prevent CSI token expiry from revoking backup credentials (#76) ([f5b4047](https://github.com/DragonBishop/data_science_cluster/commit/f5b404781d73e3c1b920595f743a3bfba065b236))
- *(cert-manager)* Restrict issuer token requests (#78) ([3debe69](https://github.com/DragonBishop/data_science_cluster/commit/3debe69da1425e09f1bd51b3febd0fa5e215828a))
- *(firewall)* Narrow Fedora host exposure ([cb58a2d](https://github.com/DragonBishop/data_science_cluster/commit/cb58a2d0f2c56f5ed347d7b53656e08b3d12f7c5))
- *(gateway)* Use cluster.internal for shared TLS ([098b9d7](https://github.com/DragonBishop/data_science_cluster/commit/098b9d74962afc847e71825d16d9eb6622ab3b75))
- *(gateway)* Require namespace approval for routes ([77c4076](https://github.com/DragonBishop/data_science_cluster/commit/77c4076068c13e95dc8693d3e1195424bb0003b0))
- *(network)* Require receiver permission for Gateway traffic ([049583d](https://github.com/DragonBishop/data_science_cluster/commit/049583d8617add85e437474316bf0b74d45e48a4))

### ♻️ Refactor

- *(tests)* Simplify cluster integration verification ([4dfd2e4](https://github.com/DragonBishop/data_science_cluster/commit/4dfd2e41d7dafaa51dc215434ec169c4ddf5b96a))

## [2.4.0](https://github.com/DragonBishop/data_science_cluster/compare/v2.3.0...v2.4.0) - 2026-10-30

### 🚀 Features

- *(preflight)* Print install and fix commands for missing tools and rules ([30af5de](https://github.com/DragonBishop/data_science_cluster/commit/30af5de08e6cb4d99701c0c43d83c85ba6422445))
- *(openbao)* Remove the rotate-credentials CronJob ([388a208](https://github.com/DragonBishop/data_science_cluster/commit/388a20813eb9ff0117010b3c33b16d41e23632a6))
- *(openbao)* Run the CSI provider and download the secrets-aws plugin ([d5ea03c](https://github.com/DragonBishop/data_science_cluster/commit/d5ea03c75c3535642599c7aeba972f9bd9f6a10a))
- *(secrets-store-csi-driver)* Install the Secrets Store CSI driver ([9cdf5d6](https://github.com/DragonBishop/data_science_cluster/commit/9cdf5d64704bc0b8c505c356b19d8920b5bbd7de))
- *(openbao)* Manage Barman's SeaweedFS key pairs and the CSI logins ([a26df4a](https://github.com/DragonBishop/data_science_cluster/commit/a26df4a28088fdb9c9a0a8995cfafaabfbd0078d))
- *(barman-cloud)* Read Barman's S3 key pair through the CSI driver ([62dbd3e](https://github.com/DragonBishop/data_science_cluster/commit/62dbd3e7c5548e11b8d9c670eb59709bf4e29855))
- *(tekton)* Read Results' database login through the CSI driver ([0a6ed83](https://github.com/DragonBishop/data_science_cluster/commit/0a6ed83168ab70186bfea372e739d98a7df04b2d))

### 🐛 Bug Fixes

- *(ansible)* Apply the baseline network policy before the workloads installed ahead of Flux ([2672397](https://github.com/DragonBishop/data_science_cluster/commit/2672397415d03055679f02d239ef222d940c64a5))
- *(e2e)* Stabilize OpenBao PKI and Postgres verification ([660d4f6](https://github.com/DragonBishop/data_science_cluster/commit/660d4f6a863a3fdfabbf66fc91fd8cd8f98c3a7b))

### 📚 Documentation

- Document the in-agent Hubble CLI, preflight's install commands and GitHub App setup ([e8964cd](https://github.com/DragonBishop/data_science_cluster/commit/e8964cd49ecb130c693b681822241d6bacc5785f))
- Describe login delivery through the Secrets Store CSI driver ([f81d08d](https://github.com/DragonBishop/data_science_cluster/commit/f81d08d298d1237f957487cc71aa1ee47d1d4dfe))

### ♻️ Refactor

- *(hubble)* Run the Hubble CLI inside the Cilium agent ([480f58d](https://github.com/DragonBishop/data_science_cluster/commit/480f58d43d6e563b8500b5d0e808fbcd280bc26f))

## [2.3.0](https://github.com/DragonBishop/data_science_cluster/compare/v2.2.0...v2.3.0) - 2026-10-29

### 🚀 Features

- *(seaweedfs)* Serve HTTPS between master, filer, volume and S3 ([4435fc5](https://github.com/DragonBishop/data_science_cluster/commit/4435fc59dd16a2fcb2732a072ff70c27c79cd5aa))

### 🧪 Testing

- *(opentofu)* Check the cert auth roles and the SPIRE server role ([ac1e54a](https://github.com/DragonBishop/data_science_cluster/commit/ac1e54a92e5b4a42908ee298e61394ee9ff00447))

### ⚙️ Miscellaneous Tasks

- *(renovate)* Update README versions alongside their cluster-config pins (#72) ([e443a09](https://github.com/DragonBishop/data_science_cluster/commit/e443a09de9599c029f555d37ca6c10bab42dcd10))

## [2.2.0](https://github.com/DragonBishop/data_science_cluster/compare/v2.1.0...v2.2.0) - 2026-10-28

### 🚀 Features

- *(trust-manager)* Publish the OpenBao CA bundles through trust-manager Bundles ([1602475](https://github.com/DragonBishop/data_science_cluster/commit/1602475b1c991cfc61bd0663a40352955adc7521))
- *(postgres)* Sign the Postgres server certificate with its own CA ([9428441](https://github.com/DragonBishop/data_science_cluster/commit/942844111b0109690532916587bbce586373b879))
- *(tekton)* Add the core-test Pipeline with the ca-bundles Task ([3747917](https://github.com/DragonBishop/data_science_cluster/commit/3747917e0bc3b12fe197453239870a1e3ec0bb81))
- *(ansible)* Install cert-manager, trust-manager and OpenBao before Flux ([a033afa](https://github.com/DragonBishop/data_science_cluster/commit/a033afa0d33ffd42d6adeece61d6ab3d2e626918))
- *(spire)* Install SPIRE before Flux with its CA signed by OpenBao's root ([d949ec1](https://github.com/DragonBishop/data_science_cluster/commit/d949ec1f6d344fc4a21a3aad7ba546a9bba54b6e))
- *(flux)* Require SPIFFE mTLS between the Flux controllers ([26bf0cc](https://github.com/DragonBishop/data_science_cluster/commit/26bf0cc3798659f2058abc4827bde1311dbf2902))
- *(seaweedfs)* Require mTLS on gRPC between master, filer, volume and S3 ([c606e13](https://github.com/DragonBishop/data_science_cluster/commit/c606e1336bd59f89f4ea8ed97cea30abea1bf57e))
- *(postgres)* Let core_test log in with its SVID ([1fe6166](https://github.com/DragonBishop/data_science_cluster/commit/1fe61665b66edc7867219dcf3910da9d4f26da6a))
- *(spire)* Give core-test and rotate-credentials SVIDs ([b1a6f55](https://github.com/DragonBishop/data_science_cluster/commit/b1a6f55368a3f81dc752e2c29a36e8afefe2e4ec))
- *(openbao)* Replace ESO with SVID logins and a daily rotate-credentials CronJob ([ad2e98b](https://github.com/DragonBishop/data_science_cluster/commit/ad2e98b85bb98120aa2a42d67877b8c18ef8b6d6))
- *(spire)* Close the server's metrics port and drop Prometheus's SPIFFE ID ([0db0397](https://github.com/DragonBishop/data_science_cluster/commit/0db0397d81f3dbb190fda9eca1f68cb5edb697dd))

### 🐛 Bug Fixes

- *(renovate)* Track cluster-config pins through timestamped datasources ([b594de2](https://github.com/DragonBishop/data_science_cluster/commit/b594de2f2a0bb2d61e1b9fa8ce1ee74753b4c2e5))

### 📚 Documentation

- Naming conventions and the new policy, file and namespace layout ([7791fa8](https://github.com/DragonBishop/data_science_cluster/commit/7791fa83e090406f2bb4c6f25700023eca2aeadc))
- Document the trust-base-first bootstrap and rotate-credentials in place of ESO ([de6bdeb](https://github.com/DragonBishop/data_science_cluster/commit/de6bdeb8fc22ebcf186ba90f5804eb61d4b81c7b))

### ♻️ Refactor

- Standardize PostgreSQL names and reorganize Tekton resources ([471e532](https://github.com/DragonBishop/data_science_cluster/commit/471e532b470b538b97b56a21e5f7d61ed3bcf2d3))
- *(cluster-config)* Drop GATEWAY_API_VERSION ([9b64c8a](https://github.com/DragonBishop/data_science_cluster/commit/9b64c8ac9711466996ef065c2ce02f51cb82e144))
- *(flux)* One policy file per namespace and role-based file names ([4a2fa3e](https://github.com/DragonBishop/data_science_cluster/commit/4a2fa3e95ba24289744e6823a37b0a514fb93b54))
- *(tekton)* Split Tekton into the tekton, tekton-triggers and tekton-pipelines namespaces ([519d5d2](https://github.com/DragonBishop/data_science_cluster/commit/519d5d2dba961a149d4a48cb15de64dac5a77052))
- *(seaweedfs)* Move SeaweedFS into its own namespace with its own OpenBao login ([973bee3](https://github.com/DragonBishop/data_science_cluster/commit/973bee38620f27535c692ab3a287695b3f0d1ae4))
- *(eso)* Refresh the Tekton Results database login daily and drop the app login ([10e40bb](https://github.com/DragonBishop/data_science_cluster/commit/10e40bb6d29098a945d02b949681c05b90033181))
- *(ansible)* Substitute values with flux envsubst and parse OpenBao output once ([fefd895](https://github.com/DragonBishop/data_science_cluster/commit/fefd89531d7411dbf360b1b9d00a0127fc848d59))

### 🧪 Testing

- *(molecule)* Check cluster-config drift on the live full-playbook install ([b41f210](https://github.com/DragonBishop/data_science_cluster/commit/b41f2105a5cf8fed81d8f7c140e120cce538f0cc))
- *(molecule)* Template the trust base charts and check SPIRE's CA and Flux adoption ([932f017](https://github.com/DragonBishop/data_science_cluster/commit/932f017c04d1c3addcb1483dcd259492c2c6ba40))

### ⚙️ Miscellaneous Tasks

- *(bash)* Run the host scripts with env bash ([dfc2981](https://github.com/DragonBishop/data_science_cluster/commit/dfc2981e0724b34cbbab2544f21a6ec69174fc9c))
- *(flux)* Upgrade Flux from v2.9.6 to v2.10.0 ([910b447](https://github.com/DragonBishop/data_science_cluster/commit/910b44772aa64140fab690ecc99bdf92fec7514b))

## [2.1.0](https://github.com/DragonBishop/data_science_cluster/compare/v2.0.0...v2.1.0) - 2026-10-23

### 🚀 Features

- *(cilium)* Receivers name every caller, from their own namespace too ([f9de257](https://github.com/DragonBishop/data_science_cluster/commit/f9de257696844ddb1ea5479d172d829aecb7ce60))
- *(devcontainer)* Clone the repository from origin and pin the host tools ([0b62e23](https://github.com/DragonBishop/data_science_cluster/commit/0b62e2393d7a5b1643f7ea8425bcbab7de008549))

### 🐛 Bug Fixes

- Set SeaweedFS resources and raise Cilium and OpenBao requests ([fb3d5e9](https://github.com/DragonBishop/data_science_cluster/commit/fb3d5e943e393774eab5679fc341ae41de93e6dd))
- *(ansible-lint)* Lint the collection offline from the repository root ([e5c8f9e](https://github.com/DragonBishop/data_science_cluster/commit/e5c8f9ebcee48004594171a59d562e15ebfa9de7))
- *(cilium)* Keep the API port in cluster-default a string ([3af4df8](https://github.com/DragonBishop/data_science_cluster/commit/3af4df8cd8981541c79a428b3e906129ffc6dbcd))
- *(start-cluster)* Wait for OpenBao to answer before unsealing ([e70170a](https://github.com/DragonBishop/data_science_cluster/commit/e70170a21810b7fcb944502b4fc7c405a425589f))

### 📚 Documentation

- *(ansible)* Ready the collection for Galaxy ([a6978aa](https://github.com/DragonBishop/data_science_cluster/commit/a6978aae698ad03c2c75dab1745a8fce18e5035a))
- *(cilium)* Document the baseline and one policy per namespace ([e4c24fe](https://github.com/DragonBishop/data_science_cluster/commit/e4c24fef67b92779e92fcc7f565eb771d76b71b2))
- *(readme)* Rewrite and restructure README.md for clarity and organization ([dca690b](https://github.com/DragonBishop/data_science_cluster/commit/dca690bd7abb2ccf5bc3a680e2fddc8b0a52d7e9))
- *(backups-restore)* Split off documentation for backups and restoration process ([8309ce9](https://github.com/DragonBishop/data_science_cluster/commit/8309ce9440b4bd7427d3a3b6e9492efa1b01447a))
- *(installation)* Update installation guide to match recent repo updates, split verification off into separate doc. ([3d22f2b](https://github.com/DragonBishop/data_science_cluster/commit/3d22f2b6ba736dac95387fad035af6d42c4d2aff))
- *(troubleshooting)* Update external source policy references to reflect flux-system changes and clarify TLS mismatch resolution steps ([45d9fa8](https://github.com/DragonBishop/data_science_cluster/commit/45d9fa88988416cf8800343ef9f8347903b1b77c))
- *(repository-structure)* Update file descriptions and repository tree. ([e60f973](https://github.com/DragonBishop/data_science_cluster/commit/e60f973a92d755f9d3b30d97ef8ff8f9b68d9549))
- *(operations)* Split off comprehensive operations guide for cluster management ([4aa9eb1](https://github.com/DragonBishop/data_science_cluster/commit/4aa9eb1ba9f932975adb2c9f2ef8cbb59614561e))

### ♻️ Refactor

- *(ansible)* Rename the collection to dragonbishop.cluster ([1347deb](https://github.com/DragonBishop/data_science_cluster/commit/1347debee2438f7f1a56e6a85047899b5626b8c1))
- *(ansible)* Move the playbook, its variables and the full-playbook scenario into the collection ([c710331](https://github.com/DragonBishop/data_science_cluster/commit/c710331e4648d1bcdd4ae642c3165cd3c1cf5956))
- *(cilium)* Name each policy after its workload ([bac6d31](https://github.com/DragonBishop/data_science_cluster/commit/bac6d31c4c7dbc1ad46f7589c2275183ed8da8ce))
- *(just)* Open db-connect through kubectl cnpg psql ([f1e4249](https://github.com/DragonBishop/data_science_cluster/commit/f1e4249ed2833c89adb5a5d9d52168b41ec0fbd4))

### 🧪 Testing

- *(opentofu)* Add mocked plan tests for terraform/openbao ([7da2412](https://github.com/DragonBishop/data_science_cluster/commit/7da2412a612256b13601fcd928c4491b833a30d0))

### ⚙️ Miscellaneous Tasks

- Update copier template to v2.0.0 ([728d200](https://github.com/DragonBishop/data_science_cluster/commit/728d2004bb89430fab84e58dd21de8372a68e9ff))
- Sync copier template to rebuilt v2.0.0 ([ab28fc2](https://github.com/DragonBishop/data_science_cluster/commit/ab28fc202235efc71f695ab31ac2b1b43e976773))
- Skip tests and e2e on release-only PRs ([c3c1a59](https://github.com/DragonBishop/data_science_cluster/commit/c3c1a59de5fc272bbf698e7940d7c56824c54766))
- Pin every GitHub Action to a commit SHA ([0897a79](https://github.com/DragonBishop/data_science_cluster/commit/0897a79cd648fe3f9842164bb85ad594d2dedec1))
- Gate e2e on cluster changes so bootstrap can be required ([25c1a98](https://github.com/DragonBishop/data_science_cluster/commit/25c1a98c3332c3c311489ab6701c5125f0b4fbaa))
- *(renovate)* Track cluster-config versions ([412a74a](https://github.com/DragonBishop/data_science_cluster/commit/412a74a1f340d3019047de35ce38133526d6c7ee))
- *(renovate)* Record the copier template's full git URL ([7f59de0](https://github.com/DragonBishop/data_science_cluster/commit/7f59de034d88bac9eb1dfc581ec214339802edc5))
- Update copier template to v2.1.0 ([3a054b5](https://github.com/DragonBishop/data_science_cluster/commit/3a054b5d0a147dadc2eaec16b15e3ad8668aff65))
- Remove gateway_api_version from cluster_config ([fb191c1](https://github.com/DragonBishop/data_science_cluster/commit/fb191c19bf62b17699d8a6fe64948e4917b52b3e))
- *(opentofu)* Update the host version to 1.13.1 ([d96ba7e](https://github.com/DragonBishop/data_science_cluster/commit/d96ba7efa7cf08ecc2266b23461ec4f22c0da38f))
- *(release)* Generate the collection's CHANGELOG.md with git-cliff ([4a250b8](https://github.com/DragonBishop/data_science_cluster/commit/4a250b8907a94ad6dfd8c760fcf3f1b79c8bfbe5))
- *(tekton)* Drop the network-checks Pipeline scaffold ([781a5ad](https://github.com/DragonBishop/data_science_cluster/commit/781a5ad00700b8e149b06f87c44d89e7157dc234))
- *(uv)* Add a notebook dependency group for the Jupyter kernel ([b1f8612](https://github.com/DragonBishop/data_science_cluster/commit/b1f8612868e9b3799f0068136a7c7d62ecf50eb2))
- *(git-cliff)* Link commit hashes and versions in changelogs ([55f74a1](https://github.com/DragonBishop/data_science_cluster/commit/55f74a1b9e34488d396cb13b3a0af3f1c3704173))

## [2.0.0](https://github.com/DragonBishop/data_science_cluster/compare/v1.2.0...v2.0.0) - 2026-10-12

### 🚀 Features

- Add CILIUM_HELM_RETRIES configuration for Helm installation retries ([0400fed](https://github.com/DragonBishop/data_science_cluster/commit/0400fed664f9cfa0ef42c6681c3f0277737e16c3))
- [**breaking**] Replace Vault with OpenBao ([f44929d](https://github.com/DragonBishop/data_science_cluster/commit/f44929df60fdcc0fb428f5bc27f710fbe64725e1))
- [**breaking**] Replace Vault Secrets Operator with External Secrets Operator ([75b4f43](https://github.com/DragonBishop/data_science_cluster/commit/75b4f432ea23d467c0b0973bac784655b56b6003))
- *(network)* [**breaking**] Apply a default-deny baseline with named additional policies ([c8d65c3](https://github.com/DragonBishop/data_science_cluster/commit/c8d65c345c88c838e17afc73ee29fe5d000e4615))
- *(preflight)* Enhance kubectl checks and version validation in preflight script ([c9bd523](https://github.com/DragonBishop/data_science_cluster/commit/c9bd523d22015e204651f3d4045921b07b98c43b))
- *(tekton)* Add Tekton results database and update kustomization ([684815a](https://github.com/DragonBishop/data_science_cluster/commit/684815aa366c10092e150c51192604a91be68658))
- *(tofu)* Add Tekton results role and policy for database access ([60d8766](https://github.com/DragonBishop/data_science_cluster/commit/60d876626f085aa5d8e5e51304424a3a807474c7))
- *(tekton)* Add Tekton Results secrets and configuration for OpenBao integration ([21df48b](https://github.com/DragonBishop/data_science_cluster/commit/21df48bc5a2e2bb25e462f635af75fd3d61e6027))
- *(tekton)* Add TLS certificate configuration for Tekton Results API ([1dbf99e](https://github.com/DragonBishop/data_science_cluster/commit/1dbf99e9bda64923936cc5fc572df227564fa6dd))
- *(tekton)* Update Tekton Results configuration and network policy for database access ([f4f10de](https://github.com/DragonBishop/data_science_cluster/commit/f4f10ded42cd7b6253c4f5736effd9b4f5de3587))
- *(tekton)* Mint new Tekton Results database credentials on every pod start ([e35fd39](https://github.com/DragonBishop/data_science_cluster/commit/e35fd395966b6e2ae6fb3a3b2f87f718f574378c))
- *(ansible)* Ask for the OpenBao root token up front, only when OpenBao is already initialized ([19fe99b](https://github.com/DragonBishop/data_science_cluster/commit/19fe99b5f4c41c6f2509d9585b70fea3d89e9e4e))
- *(ansible)* Verify what terraform/openbao configured after each apply ([7739979](https://github.com/DragonBishop/data_science_cluster/commit/7739979284344bad718fca176943e56cebd51ae1))
- *(tekton)* Allow run egress to GitHub and PyPI, set run defaults ([ecb438a](https://github.com/DragonBishop/data_science_cluster/commit/ecb438a9ba684ebddf54c0d892acfb27096bb314))

### 🐛 Bug Fixes

- *(uninstall)* Leave bpffs mounted and require a reboot before reinstalling ([79c38c5](https://github.com/DragonBishop/data_science_cluster/commit/79c38c5caa4fcd13ff61431668fd8f7f3df51e45))
- *(flux)* Apply ESO secrets and Cilium Helm values before their consumers ([d93a401](https://github.com/DragonBishop/data_science_cluster/commit/d93a4012b283b0c5594347292958ee190a0cabdf))
- *(seaweedfs)* Keep master and filer data under SEAWEEDFS_HOST_PATH ([222086d](https://github.com/DragonBishop/data_science_cluster/commit/222086daf222f790310f561805bfbe8ec727ce9f))
- *(cilium)* Audit network policy and add LocalDirectPolicy for bao ([e2c8107](https://github.com/DragonBishop/data_science_cluster/commit/e2c8107d4ef28f39ac267ca2fc47a4e2ebb17cd7))
- *(just)* Keep the PostgreSQL root certificate under ~/.config/postgresql ([7738fc3](https://github.com/DragonBishop/data_science_cluster/commit/7738fc3e759dce10bc846aaf32a536f7e3e89e69))
- *(ansible)* Prompt for the OpenBao root token when none is available ([0a74cd0](https://github.com/DragonBishop/data_science_cluster/commit/0a74cd029034c1ebd5b377d4530c0a2fe93303cb))
- *(flux)* Reconcile SeaweedFS before databases so the backup bucket exists first ([7ef7be1](https://github.com/DragonBishop/data_science_cluster/commit/7ef7be1e90cc5d514a31cbf9a07b78bcbb6cd1f6))
- *(ansible)* Stop reporting changes on every bootstrap re-run ([a5130c1](https://github.com/DragonBishop/data_science_cluster/commit/a5130c14727f9b6cd0e5d62ff3408ce0d2200344))
- *(flux)* Deploy the dynamic PostGIS credentials with postgis-cluster ([05ea96f](https://github.com/DragonBishop/data_science_cluster/commit/05ea96f75b1da256f322c9a2d6f1543f9911f57d))
- *(bash)* Read cluster-config values from the ConfigMap kustomize builds ([5184d78](https://github.com/DragonBishop/data_science_cluster/commit/5184d7838bd7ee25862166bd7398cb06a295e16f))
- *(k3s)* Give the bootstrap user write access to the kubeconfig ([78aa602](https://github.com/DragonBishop/data_science_cluster/commit/78aa602cbeec71d5870c149bc356a87b7581fcac))
- Update dependencies and versions. ([47c3cfa](https://github.com/DragonBishop/data_science_cluster/commit/47c3cfa2ffb21a811901d30b8a3b88517a0db67e))
- *(just)* Install Ansible collections before bootstrap ([6b050f3](https://github.com/DragonBishop/data_science_cluster/commit/6b050f3792f2cd6210282e409c4c454327b27a6b))
- Update e2e workflow and sync tasks to use FLUX_GIT_BRANCH for dynamic branch handling ([b13358f](https://github.com/DragonBishop/data_science_cluster/commit/b13358fce158e06de6687e10305bd4db7fc58b74))

### 📚 Documentation

- Document OpenBao and External Secrets Operator ([207f441](https://github.com/DragonBishop/data_science_cluster/commit/207f4413a6d0f3de21bfbc7e18955373724bb8ae))
- *(tekton)* Describe the Tekton Results database ([32505a3](https://github.com/DragonBishop/data_science_cluster/commit/32505a330af036abca6d7d7ad3f981a2edf7eed5))
- Describe the cluster-config patch files, group_vars/all/ and Galaxy collections ([c7da54e](https://github.com/DragonBishop/data_science_cluster/commit/c7da54e62e506c62ed4ed67c75a3849da8c0aa52))
- Bring the README tree and file descriptions up to date ([8b14b3f](https://github.com/DragonBishop/data_science_cluster/commit/8b14b3fae295b22c1f5f2d1747653b8118eca0f0))
- Move the docs into docs/ and update them for 2.0 ([020d711](https://github.com/DragonBishop/data_science_cluster/commit/020d71142edfd51cb055c46da7da91ef2cfc8f88))

### ♻️ Refactor

- *(cluster-config)* Split the ConfigMap into one patch file per kind of value ([1e0a89b](https://github.com/DragonBishop/data_science_cluster/commit/1e0a89b7defc6e1aa0961b8e1ea45ad064316837))
- *(ansible)* Build cluster_config from the patch files listed in kustomization.yaml ([b03f4bf](https://github.com/DragonBishop/data_science_cluster/commit/b03f4bf128f99733a91af83a58174def3643972b))
- *(ansible)* Split each role's tasks into named task files ([ebefa04](https://github.com/DragonBishop/data_science_cluster/commit/ebefa04f7f410111324b545299b25f49a67e92d1))
- *(ansible)* Move the roles into the collection data_science.cluster ([2c02fef](https://github.com/DragonBishop/data_science_cluster/commit/2c02fef4a87657037dce331ca1909204fc171260))

### ⚙️ Miscellaneous Tasks

- *(flux)* Pin flux-system to the openbao branch to test the cluster rollout ([7d984e9](https://github.com/DragonBishop/data_science_cluster/commit/7d984e96bf6f1ecbbd3beab297e5135169af5077))
- *(tekton)* Remove Tekton Chains ([f89f548](https://github.com/DragonBishop/data_science_cluster/commit/f89f5485a01462ac5c86bb59aa297e46b49e3c86))
- *(molecule)* Start Molecule testing of the bootstrap playbook ([47b4a4b](https://github.com/DragonBishop/data_science_cluster/commit/47b4a4b2242431e1678851c231e47551f1e9ee4a))
- *(tests)* Check cluster-config drift by running flux build and Ansible instead of parsing files ([2f697b9](https://github.com/DragonBishop/data_science_cluster/commit/2f697b906fdce738d62cf55d4c6d59bfddfe21b5))
- *(molecule)* Run role scenarios against one shared podman container ([66e3236](https://github.com/DragonBishop/data_science_cluster/commit/66e32367074815aa887afb2c8eadce0091c823c1))
- *(molecule)* Run the bootstrap playbook as the default scenario ([61f1052](https://github.com/DragonBishop/data_science_cluster/commit/61f10527f326d7ecad7cc899ff7d10cdc47d31b2))
- *(ansible)* Take collections from the ansible package and lint from the project ([c72ceed](https://github.com/DragonBishop/data_science_cluster/commit/c72ceedee65cdb25d023ecec95a46514bbcd712c))
- *(molecule)* Add unit-k3s-config, the first role unit scenario ([3c8894a](https://github.com/DragonBishop/data_science_cluster/commit/3c8894ad3cc33fa9db5ab25849a581e5160fa07b))
- *(molecule)* Add unit-k3s-stale-cilium-dir ([4a4509b](https://github.com/DragonBishop/data_science_cluster/commit/4a4509bf5b3587533ca5737bcb971ca101f41c7f))
- *(molecule)* Add unit-openbao-keyfile ([30018b5](https://github.com/DragonBishop/data_science_cluster/commit/30018b59662226fe9037b1c1171c21525dfc5391))
- *(molecule)* Add unit-openbao-no-passphrase ([c63540c](https://github.com/DragonBishop/data_science_cluster/commit/c63540cdebde2523d70035ddf0fc6a1f06df6f93))
- *(molecule)* Add unit-k3s-stale-cilium-interface ([efe08ea](https://github.com/DragonBishop/data_science_cluster/commit/efe08ea2122aacb629411804ca4ea3939b9cbe4a))
- *(molecule)* Add unit-opentofu ([4da5306](https://github.com/DragonBishop/data_science_cluster/commit/4da53060d39318f62ae4ec3dc7ea40a30ab2e380))
- Run ansible-lint and the Molecule unit scenarios on pull requests ([60f1cd5](https://github.com/DragonBishop/data_science_cluster/commit/60f1cd507241054ab34477e580583e68cf932d52))
- *(e2e)* Bootstrap a cluster from the integration scenario on pull requests ([ce9977b](https://github.com/DragonBishop/data_science_cluster/commit/ce9977bff2110a5cb04b9807f3f7e6721d9aab05))
- *(release)* Keep the ansible collection version in step with the cluster ([91cb374](https://github.com/DragonBishop/data_science_cluster/commit/91cb374fb5e5764884cf1a769202031f2d9f7547))
- *(flux)* Upgrade the controllers to v2.9.6 ([b3539d0](https://github.com/DragonBishop/data_science_cluster/commit/b3539d06b4032faf744fc3ad991c2e69418aaf36))
- *(devcontainer)* List only installed extensions ([ca2f96b](https://github.com/DragonBishop/data_science_cluster/commit/ca2f96bb0fa875d982909f131fd255ac6a08de96))

### ◀️ Revert

- *(flux)* Unpin flux-system from the openbao branch ([14b22f9](https://github.com/DragonBishop/data_science_cluster/commit/14b22f99221e80a4b250612a73f11f8e5c4c8f1a))

## [1.2.0](https://github.com/DragonBishop/data_science_cluster/compare/v1.1.0...v1.2.0) - 2026-10-01

### 🚀 Features

- Add Tekton operator configuration and resource definitions ([5d582e9](https://github.com/DragonBishop/data_science_cluster/commit/5d582e9541bf05975cbcee1ac3e3317f1340c52d))
- Update egress rules in CiliumNetworkPolicy for improved FQDN matching ([998cd6a](https://github.com/DragonBishop/data_science_cluster/commit/998cd6a437be85edfeaa867bab5d1c9de6701bd4))
- Add TektonConfig with Pipelines, Triggers, and Chains ([0ec16b8](https://github.com/DragonBishop/data_science_cluster/commit/0ec16b8643bdee5425a5c92708aa5104b7c4449f))
- Sign Tekton Chains artifacts with Vault Transit ([fa071c3](https://github.com/DragonBishop/data_science_cluster/commit/fa071c30088908ee87f311a5ef42b365f82e89d1))
- Add tests for Flux-substituted manifests and cluster-config validation ([e0492d0](https://github.com/DragonBishop/data_science_cluster/commit/e0492d06d98c6b276fac4b4150c035a0c8f6ea53))

### ♻️ Refactor

- Centralize secret prompts in vars_prompt, allow seaweedfs.github.io egress ([7ef5bd2](https://github.com/DragonBishop/data_science_cluster/commit/7ef5bd2536d9400a7ccf28faa31a1b3389720953))
- Move environment-specific values into cluster-config ([fdf9304](https://github.com/DragonBishop/data_science_cluster/commit/fdf930413b19522742f0b7d9e810aceca4a9db4a))

### ⚙️ Miscellaneous Tasks

- Rename package to pgiscluster and prune unused dependencies ([10578fd](https://github.com/DragonBishop/data_science_cluster/commit/10578fde3412c148ed19fe7408cd43d5228afbee))
- Remove unused modules and update test descriptions ([4705c0c](https://github.com/DragonBishop/data_science_cluster/commit/4705c0c5bf5b316e0e977a8781649e8e9c3ddb03))
- Update project configuration and dependencies for data_science_cluster ([9ddfb3c](https://github.com/DragonBishop/data_science_cluster/commit/9ddfb3cbb7980b5f329dde8d9f2d03538988f604))
- Bump cluster resource versions, use GitHub App token for release workflow ([c568b83](https://github.com/DragonBishop/data_science_cluster/commit/c568b832fd1f25bf8e6ef813cf327214cc7f04bb))
- Sync project metadata and tooling with copier template ([0370335](https://github.com/DragonBishop/data_science_cluster/commit/03703350b0f7ad74bb5c8d279b8cb239462be1e8))
- Adopt copier template v1.7.0 and generate changelog in release PR ([6b695ba](https://github.com/DragonBishop/data_science_cluster/commit/6b695badc2de02e0c4881265087bf6e5e8d2936c))
- Update Copier version to v1.7.2 ([8160da7](https://github.com/DragonBishop/data_science_cluster/commit/8160da7d14940ba5ce0837d6deb7efdf1e82be59))

## [1.1.0](https://github.com/DragonBishop/data_science_cluster/compare/v1.0.1...v1.1.0) - 2026-09-07

### 🚀 Features

- Add GitHub workflows for linting, testing, and release management ([7028e15](https://github.com/DragonBishop/data_science_cluster/commit/7028e1591f1aafef5ec8266684e229af62a4b9e9))
- Implement k3s Data Science Cluster provisioning and update Flux tasks for GitHub App integration ([b5f39b9](https://github.com/DragonBishop/data_science_cluster/commit/b5f39b9b7d17eb8a2ca390f4f8a27a27e834dabd))
- *(uninstall)* Add 'just uninstall' command and script to tear down k3s and clear local state ([de6c423](https://github.com/DragonBishop/data_science_cluster/commit/de6c4233d918c0addcc70fa09cd6bd7310a056ef))

### 🐛 Bug Fixes

- *(ansible)* Migrate ansible_env to ansible_facts, pause on vault secrets, drop flux wait conditions ([0b4db0e](https://github.com/DragonBishop/data_science_cluster/commit/0b4db0eb1b7b0dccf5cde13eeed700b883a62b9d))
- *(ansible)* Update KUBECONFIG default path to use ansible_facts for consistency ([cef26d5](https://github.com/DragonBishop/data_science_cluster/commit/cef26d575898787ffb4fe1425d317e18a2863bfa))
- *(bootstrap)* Make one-command cluster bootstrap reliable ([370cde9](https://github.com/DragonBishop/data_science_cluster/commit/370cde91a15dc62eeb9064fda1f2d54d91aecacc))

### 📚 Documentation

- Update the GitHub authentication instructions, add a GitHub App preflight check ([523caf3](https://github.com/DragonBishop/data_science_cluster/commit/523caf31175b9f435420ce6eb54cde18963cbf3a))

## [1.0.1](https://github.com/DragonBishop/data_science_cluster/compare/v1.0.0...v1.0.1) - 2026-08-31

### ⚙️ Miscellaneous Tasks

- Use dedicated PAT for release-please instead of repo Actions permission ([a2839a3](https://github.com/DragonBishop/data_science_cluster/commit/a2839a32b7fe236c9ce956092428af5e1a37fc91))

## [1.0.0](https://github.com/DragonBishop/data_science_cluster/compare/v0.6.0...v1.0.0) - 2026-08-31

### 🚀 Features

- Add jsonpatch and kubernetes dependencies and their preflight checks ([58876ab](https://github.com/DragonBishop/data_science_cluster/commit/58876ab5cfe281d5ced8a44439e9c1173f583afc))
- *(ansible)* Add k3s installation tasks to the k3s role ([7173d93](https://github.com/DragonBishop/data_science_cluster/commit/7173d93f1be74cd6d29f8072714d2fb59a7334af))
- Implement firewall setup script for Kubernetes and Cilium ([5173724](https://github.com/DragonBishop/data_science_cluster/commit/5173724ac3c02b20c379b5e61c45bb1a04abc2d3))
- Update firewall configuration and apply Cilium network policies ([7cecc7a](https://github.com/DragonBishop/data_science_cluster/commit/7cecc7a8337f839b32ef981d5cac047c3ff9b08c))
- Add release-please workflow and configuration files ([a95e17a](https://github.com/DragonBishop/data_science_cluster/commit/a95e17a292a2bb6ff23b585bc4f05081108d280a))

### ⚙️ Miscellaneous Tasks

- *(flux)* Upgrade Flux to v2.9.4 ([346d36f](https://github.com/DragonBishop/data_science_cluster/commit/346d36f3af0927008c1d4168d829d466244cd7d4))

## [0.6.0](https://github.com/DragonBishop/data_science_cluster/compare/v0.5.0...v0.6.0) - 2026-08-30

### 🚀 Features

- Add bootstrap scripts for cluster and Transit Vault setup ([ad10f19](https://github.com/DragonBishop/data_science_cluster/commit/ad10f19790c0f4eaec7ce8bc565b791bef8088ff))
- Improve firewall and Vault handling in the bootstrap scripts, remove the notebooks ([e6a4024](https://github.com/DragonBishop/data_science_cluster/commit/e6a4024c70a42b702d4fb9a2f715689e290851ea))
- Improve firewall and Vault handling in the bootstrap scripts ([9f82263](https://github.com/DragonBishop/data_science_cluster/commit/9f8226353d849d378c63f6fd8524f96caa06303e))
- Add preflight readiness checks for host setup ([0683694](https://github.com/DragonBishop/data_science_cluster/commit/06836942b2a067811211c3a64c7ff23d39260894))
- Add initial Ansible configuration and playbook for k3s cluster provisioning, update and regroup python dependencies ([e60bacd](https://github.com/DragonBishop/data_science_cluster/commit/e60bacd65a59addc952a5adeb7f9968288122238))
- Update Ansible tasks for Vault installation and configuration, including TLS setup and repository adjustments ([9916f92](https://github.com/DragonBishop/data_science_cluster/commit/9916f92371f288ff1214554d8527e397554c2ca8))
- Add Ansible tasks for k3s installation and configuration ([05e7809](https://github.com/DragonBishop/data_science_cluster/commit/05e7809ff0aeccb8213a43adc4a34770bf66d39f))
- Update configuration files to use environment variables for resource sizing and versions ([0a32140](https://github.com/DragonBishop/data_science_cluster/commit/0a32140731ad5b908f25a2742d4712ef70b68e34))
- Add configuration files for cluster settings and resource sizing, including k3s installation tasks ([ba39421](https://github.com/DragonBishop/data_science_cluster/commit/ba39421f48c6ad04509fb289d1fc5cb49347c84a))
- Update installation instructions and scripts to include envsubst for Cilium configuration ([ec8a1bf](https://github.com/DragonBishop/data_science_cluster/commit/ec8a1bf1cfdfa44e95499f407dd9c05ff74ecd59))
- Update Flux role to bootstrap GitHub repository and reconcile vault kustomization ([7788158](https://github.com/DragonBishop/data_science_cluster/commit/778815863ac55790738ae5f083c9beb768045b06))
- Add Ansible configuration and roles for Vault and k3s integration, including secret management and troubleshooting updates ([f814d81](https://github.com/DragonBishop/data_science_cluster/commit/f814d81f966ae664d40dc7c75f07f77604870e27))
- Update devcontainer and preflight scripts with environment configuration and tooling checks ([c7a71de](https://github.com/DragonBishop/data_science_cluster/commit/c7a71de97272ab90fa3bc80a79698d8bbae01386))
- Enhance preflight checks and improve cluster startup scripts for better error handling and pod readiness ([e3c013e](https://github.com/DragonBishop/data_science_cluster/commit/e3c013eaa8005a6db780a034559d09ffeda558b0))
- Update Cilium Helm values substitution method and enhance preflight checks; remove deprecated bootstrap script ([4e4805b](https://github.com/DragonBishop/data_science_cluster/commit/4e4805ba2fb2adff97dcda899d9d5e2206539a39))

### 📚 Documentation

- Refactor setup and troubleshooting guides, fix rumdl config ([b0ff484](https://github.com/DragonBishop/data_science_cluster/commit/b0ff484264ddc78fd6ff8838e9229ed50531154f))
- Enhance README for clarity and detail on cluster architecture and components ([9099088](https://github.com/DragonBishop/data_science_cluster/commit/90990885b52fe274e2e5450a8c9e2cc234191aff))

### ♻️ Refactor

- Give cluster-config its own Flux Kustomization and update the install scripts ([3b913d8](https://github.com/DragonBishop/data_science_cluster/commit/3b913d8058c1d2f7e7073f1009768332c079b3ea))
- *(vault)* Consolidate Vault deployment and initialization into the bootstrap ([07288c7](https://github.com/DragonBishop/data_science_cluster/commit/07288c7d98f119ec1ee1320844c5d361fcaea14f))
- Clean up comments and improve variable descriptions in Terraform configurations ([a0e571c](https://github.com/DragonBishop/data_science_cluster/commit/a0e571c3a8719d34be15a706149fa22947988ada))
- Rework the start and stop cluster scripts for k3s management and backups ([2530ba0](https://github.com/DragonBishop/data_science_cluster/commit/2530ba08935cffff27537647b031210d5ebfe50f))
- Improve error handling and process management in the start and stop cluster scripts ([45f351a](https://github.com/DragonBishop/data_science_cluster/commit/45f351a179d34afb7cae21138d6937b662e008b9))

### ⚙️ Miscellaneous Tasks

- Add cluster naming support and reorganize install docs ([c34ea69](https://github.com/DragonBishop/data_science_cluster/commit/c34ea699528911bfc1d6d517bf0c9af5e99049d3))
- Restructure devcontainer setup with new host and cluster configurations ([9d1e250](https://github.com/DragonBishop/data_science_cluster/commit/9d1e250b9507c51c28412f3b4b4f7e36eca79d1b))
- Bump PostGIS, SeaweedFS, Flux, Vault, VSO, Cilium and Terraform provider versions ([d591794](https://github.com/DragonBishop/data_science_cluster/commit/d5917948c79f8fd805a7d82d6fc459508051e0a1))
- *(dev)* Reorder justfile recipes, add prek hook setup, and sync dependencies ([9812829](https://github.com/DragonBishop/data_science_cluster/commit/9812829d65d201172fb513477134e183e0591b29))
- Ignore rumdl cache and virtualenv directory variants in gitignore ([1b73cb8](https://github.com/DragonBishop/data_science_cluster/commit/1b73cb824220e7de778641a80b237267b7ef4473))
- Remove notebooks and jupyter tooling to match include_notebooks=false ([abb0dec](https://github.com/DragonBishop/data_science_cluster/commit/abb0decbf9bc52fb9a9872529725b9969f9410b6))

## [0.5.0](https://github.com/DragonBishop/data_science_cluster/compare/v0.4.0...v0.5.0) - 2026-08-21

### 🚀 Features

- Add postgis CiliumNetworkPolicy ([2e47617](https://github.com/DragonBishop/data_science_cluster/commit/2e47617bf6ccd941ce34ec8062d88c4b367deb37))
- Add vault CiliumNetworkPolicy ([660b09b](https://github.com/DragonBishop/data_science_cluster/commit/660b09b991881eadf8aa2728e2ea69a198dc81bc))
- Add vault-secrets-operator CiliumNetworkPolicy ([24e3784](https://github.com/DragonBishop/data_science_cluster/commit/24e3784fa8282d3bf7caf4cf6a0954f57b50269f))
- Add cnpg-operator CiliumNetworkPolicy ([055b44b](https://github.com/DragonBishop/data_science_cluster/commit/055b44b6f0996ccd53080c3e0f5a4032c97d831f))
- Add clusterwide CiliumNetworkPolicy, rename flux-system allow-kubelet-probes to flux-networkpolicy ([b05880e](https://github.com/DragonBishop/data_science_cluster/commit/b05880e118213031fabae1d54221f2a0ec632f0d))
- Add Vault 2-tier PKI engine (root/intermediate CA, internal-server role) ([dbab245](https://github.com/DragonBishop/data_science_cluster/commit/dbab24592c84fa2eb10f2d27bebf6d3f53190978))
- Add/extend CiliumNetworkPolicies for cert-manager, cnpg-operator, vault ([52213a3](https://github.com/DragonBishop/data_science_cluster/commit/52213a324a76e7577104d1d4820cc00356969f05))
- Add CNPG-managed localhost Service for postgis-cluster ([7839f33](https://github.com/DragonBishop/data_science_cluster/commit/7839f332de7c9367f9eb56d6a86ee0b685904273))
- Enable Cilium localRedirectPolicy for node-local Service redirection ([0801f26](https://github.com/DragonBishop/data_science_cluster/commit/0801f26f0b8c41e463bcf5e09343ce4c020e90da))
- Expose postgis-cluster primary on localhost:5432 ([e03f28f](https://github.com/DragonBishop/data_science_cluster/commit/e03f28f98f3901bbbc28d78d53499bd884cb9107))
- Add db-connect, vault-pf, and thin start/stop wrappers to justfile ([d900a7d](https://github.com/DragonBishop/data_science_cluster/commit/d900a7ddf637319860c00c717708087a3c634593))
- Add just status, a read-only cluster health check ([8480f2a](https://github.com/DragonBishop/data_science_cluster/commit/8480f2a33b241de317fd2776af711cc84af765fa))
- Add bootstrap recipes for k3s config, cluster network, Cilium, and Vault setup ([82e55cc](https://github.com/DragonBishop/data_science_cluster/commit/82e55cc0ebd7d2bec25df74bd3898fb2f332daf0))

### 🐛 Bug Fixes

- Grant NetworkPolicy baseline egress for apiserver, cluster, CoreDNS upstream ([934aee5](https://github.com/DragonBishop/data_science_cluster/commit/934aee5f6eefdfa018366060ebfac5de41fb68f3))
- S3/Barman TLS via Vault PKI (endpointCA, seaweedfs-s3-tls, HTTPS probes) ([61471ac](https://github.com/DragonBishop/data_science_cluster/commit/61471ac01cbcaf6452c1ac48b1ccf8215debfc3a))
- Flux Kustomization dependsOn wiring for vault/cert-manager rollout ([db96bb2](https://github.com/DragonBishop/data_science_cluster/commit/db96bb2d4d311660dad743009537386a4d1d4d03))
- Allow world-entity ingress to postgis on 5432 ([ba5a0e6](https://github.com/DragonBishop/data_science_cluster/commit/ba5a0e6f1825dd49d9549dbd15fbc10b3c6b7719))
- Hubble.internal TLS verification (wrong SAN, wrong CA) ([1961bcb](https://github.com/DragonBishop/data_science_cluster/commit/1961bcb936df849a4faeed039554092474986d83))

### 📚 Documentation

- Update README/INSTALLATION for NetworkPolicy and secrets refactor ([2e4a262](https://github.com/DragonBishop/data_science_cluster/commit/2e4a262c3ad9751233aea0135553d11e48c19822))
- Update INSTALLATION, README, and troubleshooting for Vault PKI rollout ([f9803f9](https://github.com/DragonBishop/data_science_cluster/commit/f9803f9fd48a23374e728ee17847cb63b8fdd627))
- Document postgis-localhost.yaml and localRedirectPolicy ([a333a0c](https://github.com/DragonBishop/data_science_cluster/commit/a333a0cccf9f23b87347e39da2b9c204f9a3dcbe))
- Reference new justfile recipes in INSTALLATION.md and README.md ([58b99b9](https://github.com/DragonBishop/data_science_cluster/commit/58b99b94fbac2ed43b775fa73380ec471e00f514))
- Reference new bootstrap recipes, reorganize Cluster Operations table ([9947d0e](https://github.com/DragonBishop/data_science_cluster/commit/9947d0ed96120e677e132d4828175990e2974a4d))
- Reorganize install steps into 7a/7b, add table of contents ([9cdc460](https://github.com/DragonBishop/data_science_cluster/commit/9cdc4601d11c590c13409f656827c95a0cf6fcf3))

### ♻️ Refactor

- Move cluster-config from Kubernetes ConfigMap to Terraform-managed secret ([16c4205](https://github.com/DragonBishop/data_science_cluster/commit/16c4205bbf5082e9e7384ace1f18c6882722a4a9))
- Consolidate vault-bootstrap and vault-database terraform into terraform/vault ([cf1d783](https://github.com/DragonBishop/data_science_cluster/commit/cf1d7831e0d875602e5d3dda2f39224f29f2aebe))
- Consolidate gateway and hubble TLS issuance onto vault-pki-issuer ([4d25ce8](https://github.com/DragonBishop/data_science_cluster/commit/4d25ce848bb52e0395e66d78f70e082526b3ca34))

### ⚙️ Miscellaneous Tasks

- Prune unused packages from uv.lock ([2f3cc09](https://github.com/DragonBishop/data_science_cluster/commit/2f3cc09b218e62904a05a13b3c3d426dd05251a0))
- Trim comments in Kubernetes manifests and devcontainer config ([48d6a31](https://github.com/DragonBishop/data_science_cluster/commit/48d6a316ce914334d216b718bad717afedbbe004))
- Trim comments in cluster scripts ([18abb76](https://github.com/DragonBishop/data_science_cluster/commit/18abb76e42e4dec9395352dbd6938ad6156d4ee1))
- Remove unused postgres-proxy deployment from postgis-cluster.yaml ([67eb503](https://github.com/DragonBishop/data_science_cluster/commit/67eb5033400d7caeabc7e16b72bc2bf8c02e76cd))
- Refresh uv.lock ([069e18a](https://github.com/DragonBishop/data_science_cluster/commit/069e18a479de750ae4fd8c28e6d5c1ed96db1004))

### ◀️ Revert

- Drop loopback externalIPs Service (rejected by Kubernetes API) ([ad2db0a](https://github.com/DragonBishop/data_science_cluster/commit/ad2db0a9b1a7aff757fe5f7c2438bda0024ee91d))

## [0.4.0](https://github.com/DragonBishop/data_science_cluster/compare/v0.3.0...v0.4.0) - 2026-08-13

### 🚀 Features

- Add kustomize configuration files for Cilium and Vault; update vault-values.yaml for environment variable handling ([5be7723](https://github.com/DragonBishop/data_science_cluster/commit/5be7723c4b2c6dc1f5a2dee84db50af925293620))
- Add cluster-config.yaml single source of truth, wire manifests via Flux postBuild substitution ([faf333d](https://github.com/DragonBishop/data_science_cluster/commit/faf333dd5f10db25580210f3432aa5d06382696a))
- Add Terraform vault-transit-bootstrap module ([b8643c1](https://github.com/DragonBishop/data_science_cluster/commit/b8643c1caa93b11742c18dea8f00a67de5260e5c))
- Enhance resource management across components, add Cilium NetworkPolicies for health checks ([41fb1f9](https://github.com/DragonBishop/data_science_cluster/commit/41fb1f93a7f5114fa167108503ed80157913f8c1))
- Update retention policy for backups to 4 days and enhance Cilium network policies for SeaweedFS ([e62366c](https://github.com/DragonBishop/data_science_cluster/commit/e62366c6760b4690fa4293592ce4cca4213a30cc))

### 📚 Documentation

- Remove ROADMAP.md, shift to GitHub Issues for planning and tracking ([bea44dd](https://github.com/DragonBishop/data_science_cluster/commit/bea44dd050de89df54fd97ab50fd77b0c6f17e04))
- Update installation and troubleshooting guides; enhance clarity and modularity of cluster services ([4bf442a](https://github.com/DragonBishop/data_science_cluster/commit/4bf442af8d9c5e6c3e4cb0b3b1c323f99c237987))
- Update troubleshooting and installation docs for DNS/cert changes ([0e6a5a4](https://github.com/DragonBishop/data_science_cluster/commit/0e6a5a4204d98d0b2ee61131af8eb6a9ec0b0dbf))
- Update installation and troubleshooting documentation; clarify steps for k3s reinstallation and Vault setup ([f585bd2](https://github.com/DragonBishop/data_science_cluster/commit/f585bd2ca241cde99b3afb340d5c4eb4c540f43b))
- Update justfile description for clarity on setup commands ([de9f554](https://github.com/DragonBishop/data_science_cluster/commit/de9f554c0947808b196170db9f4ab1611fc5a0f0))
- Update troubleshooting docs for kubeconfig and cluster shutdown changes ([b760b22](https://github.com/DragonBishop/data_science_cluster/commit/b760b22654db3822d65b5902a87796335d35dde1))
- Update component descriptions and organization in README.md for clarity ([65522c4](https://github.com/DragonBishop/data_science_cluster/commit/65522c46dc53980e9b5eb9ab981903b10a6e69f5))
- Update installation instructions and README for clarity; refine Terraform configurations and comments ([97d973a](https://github.com/DragonBishop/data_science_cluster/commit/97d973ad8eac1d076f7775175644dccfb8fad8f1))

### ♻️ Refactor

- Replace infrastructure/dns with coredns-custom internal DNS zone ([a9287f3](https://github.com/DragonBishop/data_science_cluster/commit/a9287f3bbd514ea69dbc9e5a226b982722fbe3a3))
- Consolidate DNS/gateway L2-LB policies into single LAN policy, enable gatewayAPI/egressGateway ([da6c30e](https://github.com/DragonBishop/data_science_cluster/commit/da6c30eb5eab28a1f6e6b7310f687fc9e8bba16b))
- Clarify comments in postgis, gateway, hubble, namespace manifests ([ba8d56a](https://github.com/DragonBishop/data_science_cluster/commit/ba8d56a224626abec830542bb7d1cfbd5e5afcfc))
- Update TLS configurations and enhance Vault integration across cluster services ([eaeb0c0](https://github.com/DragonBishop/data_science_cluster/commit/eaeb0c0fec3669d158f7e97b39e5f8ff5dc3a094))
- Remove sync-kubeconfig.sh, kubeconfig now managed directly by k3s ([b124471](https://github.com/DragonBishop/data_science_cluster/commit/b12447105ff3455c03414bbc8172085eed4cc46e))

### ⚙️ Miscellaneous Tasks

- Add ML orchestration dependencies ([2551e58](https://github.com/DragonBishop/data_science_cluster/commit/2551e58959be9962fb6f3459e9c1b5a152d62c5e))

## [0.3.0](https://github.com/DragonBishop/data_science_cluster/compare/v0.2.0...v0.3.0) - 2026-08-05

### 🚀 Features

- *(flux)* Add Flux v2.9.3 component manifests ([ad789f1](https://github.com/DragonBishop/data_science_cluster/commit/ad789f12cd0446a7c6b1d1152ec46f0a0db4490f))
- *(flux)* Add Flux sync manifests ([bd9383c](https://github.com/DragonBishop/data_science_cluster/commit/bd9383c486659499395afe5c484b1f9c05b63d38))
- Add Gateway API CRDs Flux Kustomization ([086dc21](https://github.com/DragonBishop/data_science_cluster/commit/086dc21d827d5954278ea4615282badd47ff3f2b))
- Add namespaces Flux Kustomization ([42c99d1](https://github.com/DragonBishop/data_science_cluster/commit/42c99d151773316927245769b9f0c702a37b64a1))
- Add cert-manager Flux Kustomization ([df9324b](https://github.com/DragonBishop/data_science_cluster/commit/df9324b4acef5259f0d7801beb3e8e6b8465b4c2))
- Update seaweedfs backups manifest and cluster scripts for Flux migration ([3f9dedd](https://github.com/DragonBishop/data_science_cluster/commit/3f9dedd4462f8d6b1afc08bcbb324555e9f76b6c))
- Add Cilium Flux Kustomization and HelmRelease ([8f3ee50](https://github.com/DragonBishop/data_science_cluster/commit/8f3ee50db901ede6a9ddea16cc8fed4a9ad92ab9))
- Replace vendored cert-manager CRD dump with Helm-based HelmRelease ([960779e](https://github.com/DragonBishop/data_science_cluster/commit/960779e724907a829c97eea4d704b7ff1371474c))
- Add cert-manager namespace to infrastructure configuration ([f9491b7](https://github.com/DragonBishop/data_science_cluster/commit/f9491b712f983e11612fa9a1b03e163bd2646e2f))
- Add Vault Flux Kustomization and HelmRelease ([86f7afd](https://github.com/DragonBishop/data_science_cluster/commit/86f7afd44aa595014be9ed4bf6aaa88e9729a876))
- Add Terraform vault-bootstrap module (auth, kv, encryption) ([d5f5072](https://github.com/DragonBishop/data_science_cluster/commit/d5f50722a2062c0ec6f53a4c794586daedaa11aa))
- Add CNPG operator and Vault Secrets Operator Flux Kustomizations and HelmReleases ([1ee70d8](https://github.com/DragonBishop/data_science_cluster/commit/1ee70d8db09056ebacded0792bf7477e3e5401b9))
- Add Barman Cloud Flux Kustomization and HelmRelease ([8fea3d5](https://github.com/DragonBishop/data_science_cluster/commit/8fea3d5529da29d6e7a6d12496f6077c31f9db86))
- Add SeaweedFS Flux Kustomization and HelmRelease ([da16281](https://github.com/DragonBishop/data_science_cluster/commit/da162810f06987f55536fe5c564c5037aea0ab67))
- Add postgis-database Database CRD, simplify postgis-cluster.yaml Kustomization ([b85def1](https://github.com/DragonBishop/data_science_cluster/commit/b85def1f0d6366b07d8e79a4665619b02dac585c))
- Add SeaweedFS NetworkPolicy restricting master/filer to databases namespace ([ed78c41](https://github.com/DragonBishop/data_science_cluster/commit/ed78c411966fb9bb6f66dfb19ac3e9937a311e33))
- Add Terraform vault-database module ([c086aa3](https://github.com/DragonBishop/data_science_cluster/commit/c086aa38f15d48ec1ad5ae2184bf69c7bb976da8))
- Add external LoadBalancer service for postgis, Cilium L2 announcement policy and LB IP pool ([4b41c67](https://github.com/DragonBishop/data_science_cluster/commit/4b41c67b17a449450f2ded0f0abd26dc1ea24b1f))
- Add shared Gateway component with dedicated Cilium L2/LB policies ([544dbfd](https://github.com/DragonBishop/data_science_cluster/commit/544dbfd4727ba9e531d6957d63f70ef71657ed86))
- Add dedicated DNS component with Cilium L2/LB policies ([d04948c](https://github.com/DragonBishop/data_science_cluster/commit/d04948ccc51959908bd0acbae2d066a3d3427db8))
- Add dedicated Hubble component ([7b92ff9](https://github.com/DragonBishop/data_science_cluster/commit/7b92ff951b9909907a894c3beb2987f822b636de))
- Add Hubble Relay/UI configuration, integrate with Cilium HelmRelease ([5f27692](https://github.com/DragonBishop/data_science_cluster/commit/5f27692cc78d88de4b836305706797aa366d72b5))
- Add Hubble Relay configuration and troubleshooting guidance for firewall settings ([0603a8f](https://github.com/DragonBishop/data_science_cluster/commit/0603a8fdd0c84cf50b0ec81b339e3162b3b32eaa))
- Add the Vault CLI to the devcontainer and justfile ([96957ee](https://github.com/DragonBishop/data_science_cluster/commit/96957ee88686a74add6823851cdf0f6d0737a577))

### 🐛 Bug Fixes

- Add schemas to postgis-database.yaml Database CRD ([feb31ce](https://github.com/DragonBishop/data_science_cluster/commit/feb31ce3e43551e6817fdcae6b49db06afe9fa10))
- Hubble health check in Cilium release ([e180166](https://github.com/DragonBishop/data_science_cluster/commit/e1801667a75982f57bc3509ed6fef3dc50c0e1ab))
- Enable BPF masquerade in Cilium to prevent pod-to-host timeouts ([b8be929](https://github.com/DragonBishop/data_science_cluster/commit/b8be929bdec4d9cb1b4f7a1c4acd73c9a68b5c53))

### 📚 Documentation

- Split docs into README/INSTALLATION/troubleshooting ([9f0403f](https://github.com/DragonBishop/data_science_cluster/commit/9f0403ff0623aead9631bfc279021b8ba0791511))
- Add README table of contents, rename devcontainers/ to .devcontainer/ ([8d7b471](https://github.com/DragonBishop/data_science_cluster/commit/8d7b471eff3d720ab599c13fa38803fd4625def0))

### ♻️ Refactor

- *(flux)* Move Cilium values into infrastructure/cilium/ ([8adad57](https://github.com/DragonBishop/data_science_cluster/commit/8adad57c677c80c83ba23b175d9efebc175d1629))
- *(flux)* Move Vault values into infrastructure/vault/, drop the old NetworkPolicy manifest ([ba80f6b](https://github.com/DragonBishop/data_science_cluster/commit/ba80f6bd19c13e5f5a0c7333ce14beb96d149b61))
- *(flux)* Move postgis-cluster, postgres-tls and vso-setup into apps/databases/ ([8af2a2c](https://github.com/DragonBishop/data_science_cluster/commit/8af2a2c73410d9d3a1d3a0128322e59617347632))
- Simplify operator availability check in stop-cluster.sh ([e56ffb0](https://github.com/DragonBishop/data_science_cluster/commit/e56ffb047cc70ecd2862745ee0861d41b4543a13))
- Replace postgis-external-service with postgis-tcproute ([923c196](https://github.com/DragonBishop/data_science_cluster/commit/923c196dfeb421385628d7b39a6caf50c8133619))
- Move cluster scripts to src/bash/ ([a309e1a](https://github.com/DragonBishop/data_science_cluster/commit/a309e1a6bdd9e45c72183b8c612d9b67295e02d8))
- Clean up justfile, drop unnecessary settings file, use dynamic Cilium versioning ([3dab44a](https://github.com/DragonBishop/data_science_cluster/commit/3dab44a3e230e6462fa4cbdc719267194dc49ad5))

### ⚙️ Miscellaneous Tasks

- Convert GitHub issue templates from Markdown to YAML forms ([8704e75](https://github.com/DragonBishop/data_science_cluster/commit/8704e756d4a632e15e8efc5805bade3bb4cff276))
- Remove old Markdown issue templates, superseded by YAML forms ([846dc27](https://github.com/DragonBishop/data_science_cluster/commit/846dc27ad5666bd604ad72dcc6b3013abdcca7fc))
- Remove .archive/, legacy pre-Flux manifests no longer needed ([a1ecbae](https://github.com/DragonBishop/data_science_cluster/commit/a1ecbae38ce87cd2618ea945dd6a4c96338559da))
- Initialize the project from the copier template ([1e054a6](https://github.com/DragonBishop/data_science_cluster/commit/1e054a634c4ded7ae38dd9cc3bf7c4e19fe7c158))
- Add ETL/ML Python dependencies, remove placeholder report stubs ([b99fe27](https://github.com/DragonBishop/data_science_cluster/commit/b99fe27f2f5bfb23118dbdd663a5cd5cf74db104))
- Remove personal contact links from issue template config ([6d10183](https://github.com/DragonBishop/data_science_cluster/commit/6d101832713ad36fe26da9c80511964c39b5fe82))
- Sync copier template to v1.0.4 ([c686226](https://github.com/DragonBishop/data_science_cluster/commit/c68622625962735a873901562e779342946ef36a))

## [0.2.0](https://github.com/DragonBishop/data_science_cluster/compare/v0.1.0...v0.2.0) - 2026-08-02

### 🚀 Features

- Switch postgis-cluster to dynamic Vault secrets, add Barman/SeaweedFS backups ([113957d](https://github.com/DragonBishop/data_science_cluster/commit/113957d0d4dcd1dd2f4d09610c30cef4fc62c9e6))
- Add SeaweedFS backup restoration and pre-flight validation to README ([fdd5de5](https://github.com/DragonBishop/data_science_cluster/commit/fdd5de50a808c0d0e4d201f2b6dc8153cd20aefd))
- Add Cilium configuration ([41e9bcb](https://github.com/DragonBishop/data_science_cluster/commit/41e9bcb77474076e7fee2bdb9ab2dc253ba019f3))
- Enhance cluster startup/shutdown scripts ([621d6de](https://github.com/DragonBishop/data_science_cluster/commit/621d6de0fcd4b0a5b698ec44fc351fd95b9ad056))

### 🐛 Bug Fixes

- Restore trimmed devcontainer.json content ([2a1534b](https://github.com/DragonBishop/data_science_cluster/commit/2a1534b8f9ffc9fd73bafeced860c1eae2a57292))
- Correct bug report issue form title/name fields ([679049b](https://github.com/DragonBishop/data_science_cluster/commit/679049b61d3119c6870b578b7dd33a0970b47ced))
- Remove GitHub bug report YAML form (schema issue), consolidate gitignore into .gitignore ([1d1a4e8](https://github.com/DragonBishop/data_science_cluster/commit/1d1a4e8c5bea513644b293b839a98090db4f2f8f))

### 📚 Documentation

- Update README with project roadmap, refine devcontainer and cluster scripts ([4c1eded](https://github.com/DragonBishop/data_science_cluster/commit/4c1ededba40d69592c6d42d62808445ef0ccd04e))
- Update README and ROADMAP for clarity in Vault and k3s configurations ([1ea173d](https://github.com/DragonBishop/data_science_cluster/commit/1ea173d28ebfc69488adbb77702282bc5f2aa880))
- Clarify systemd-to-script handover in README and cluster scripts ([4675294](https://github.com/DragonBishop/data_science_cluster/commit/4675294318570f6913c82e59e47d03a0e1faf398))
- Add SeaweedFS backup restore instructions, pre-flight validation, backup gitignore patterns ([27df2c2](https://github.com/DragonBishop/data_science_cluster/commit/27df2c25b59abf5c43dce4225e5fc98b07dff9c4))
- Add first-time setup instructions, optional Headlamp installation ([06440a2](https://github.com/DragonBishop/data_science_cluster/commit/06440a2c04e08242a0e1ee5c7c1151e04676b8dd))

### ⚙️ Miscellaneous Tasks

- Rename k3s_archive/.vscode/tasks.json to .archive/, simplify devcontainer Dockerfile ([8644e93](https://github.com/DragonBishop/data_science_cluster/commit/8644e93c4e42c72d7cd8b70880435a8410ccaff6))
- Archive superseded MinIO backups manifest ([aba2a6f](https://github.com/DragonBishop/data_science_cluster/commit/aba2a6f9c0977622f736d5a14d62000e5798b16b))
- Add GitHub issue form templates ([2bad7ae](https://github.com/DragonBishop/data_science_cluster/commit/2bad7ae5e58df25cdb287cc60911996a36e36c10))
- Remove misplaced issue templates from .vscode/ ([d4b736b](https://github.com/DragonBishop/data_science_cluster/commit/d4b736b32841e3e605ecfd0e740d6a8c945c5977))
- Add a GitHub bug report issue form ([6fc578d](https://github.com/DragonBishop/data_science_cluster/commit/6fc578dbe98c40944e5f7881fa6ccceab116b776))
- Add GitHub issue templates in Markdown format ([74d92f7](https://github.com/DragonBishop/data_science_cluster/commit/74d92f7122df6ee9a18685062178e7ac92110a25))

## [0.1.0](https://github.com/DragonBishop/data_science_cluster/releases/tag/v0.1.0) - 2026-07-24

### 🚀 Features

- Create the repository with the PostgreSQL/PostGIS stack and setup README ([c8d0be0](https://github.com/DragonBishop/data_science_cluster/commit/c8d0be0c3d52a8be7ca65ed743206a0ace8e961d))
- Add Falco runtime security scanning, initialize uv python project ([de9b003](https://github.com/DragonBishop/data_science_cluster/commit/de9b00359c3c58b8e0a66fb46c7f9a61f5e23cd8))
- Add CNPG postgis-cluster manifest, add MinIO backups manifest, retire postgis-k3s.yaml ([6b81045](https://github.com/DragonBishop/data_science_cluster/commit/6b81045a5d769d0e1074bd56f290f2e272b3a9c9))
- Add transit-vault secrets (vault-values, vso_setup), retire vault-manifest.yaml ([681921c](https://github.com/DragonBishop/data_science_cluster/commit/681921ce29a438b6f642d74f6134169bc42effd6))
- Add start-cluster.sh, stop-cluster.sh, sync-kubeconfig.sh scripts ([4e09d13](https://github.com/DragonBishop/data_science_cluster/commit/4e09d13a23352d37667a51b96f5ffff8e08ed605))
- Improve start-cluster.sh error handling and reporting ([5335472](https://github.com/DragonBishop/data_science_cluster/commit/533547275691a905abfd11b185da813cb21aa088))
- Add CiliumNetworkPolicy for Vault ingress, dynamic host IP support ([1773e2d](https://github.com/DragonBishop/data_science_cluster/commit/1773e2d2fc673b4208bcf5a33ae929ab0f1681ff))
- Add VS Code task for Headlamp startup, update README/ROADMAP ([dc3ec5e](https://github.com/DragonBishop/data_science_cluster/commit/dc3ec5ee5094a3a13693773f9e8717566ec9e081))
- Add devcontainer Dockerfile and devcontainer.json, rename README_cluster.md to README.md ([c7340dd](https://github.com/DragonBishop/data_science_cluster/commit/c7340dd66574540bf9d3fb152a64225da6e5de6f))

### 🐛 Bug Fixes

- Insert env vars in vault-values.yaml, remove WSL-side extra copy in sync-kubeconfig.sh ([122d20c](https://github.com/DragonBishop/data_science_cluster/commit/122d20cac194159e4a8d956fc19d2379226de9af))

### 📚 Documentation

- Document kubeconfig sync workflow for Headlamp/Lens/VS Code access ([bcfa6f0](https://github.com/DragonBishop/data_science_cluster/commit/bcfa6f00a51b518f263bd80171a80a9c5dc76f4e))
- Rewrite README for CNPG/vault/script changes, add pipeline planning doc, remove main.py stub ([f7e6169](https://github.com/DragonBishop/data_science_cluster/commit/f7e6169183220f36041d37a94e1876045867d021))
- Add ROADMAP.md, remove pipeline.md, update README for new layout ([5e460c4](https://github.com/DragonBishop/data_science_cluster/commit/5e460c43cd4475bb636655f19f562ded4dd46259))
- Clarify Cilium installation prerequisites and commands ([1060fa9](https://github.com/DragonBishop/data_science_cluster/commit/1060fa9782cefc309c33b9caefa854ac13370c73))
- Expand ROADMAP foundational/ETL/ML sections, add notes on alternatives ([42d6054](https://github.com/DragonBishop/data_science_cluster/commit/42d6054eba47ea3d12135c6b9baaa50622a75181))

### ♻️ Refactor

- Reorganize into manifests/ and scripts/ directories, expand start/stop-cluster.sh and postgis-cluster.yaml ([d33c6b9](https://github.com/DragonBishop/data_science_cluster/commit/d33c6b9b9a7777576997775089cdb2a014517885))
- Improve sync-kubeconfig.sh clarity and validation checks ([fa816f5](https://github.com/DragonBishop/data_science_cluster/commit/fa816f5774fd2b99b28f647c85e103010812f2fb))
- Simplify sync-kubeconfig.sh, deploy Headlamp in-cluster instead of Windows client ([4261f80](https://github.com/DragonBishop/data_science_cluster/commit/4261f80a105f07932a491c98601cd694f4104d06))

### ⚙️ Miscellaneous Tasks

- Rename vso_setup.yaml to vso-setup.yaml ([1e6a214](https://github.com/DragonBishop/data_science_cluster/commit/1e6a214fc09a57aa31dbb67173cafdc9cdc8e35c))
- Add .gitignore ([0b3797b](https://github.com/DragonBishop/data_science_cluster/commit/0b3797bd8e88879ebf890adf701cf5e8b2f4fb9d))
- Archive legacy k3s manifests into k3s_archive/ ([65c9cca](https://github.com/DragonBishop/data_science_cluster/commit/65c9cca9a4881539ee52842023a778336834b74b))

