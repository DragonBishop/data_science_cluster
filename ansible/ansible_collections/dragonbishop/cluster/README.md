# dragonbishop.cluster

The playbook and roles that bootstrap the [data science cluster](https://github.com/DragonBishop/data_science_cluster): a single-node k3s cluster with Cilium, cert-manager, trust-manager, OpenBao, SPIRE and Flux. The playbook brings the host from nothing to a running Flux, then hands the cluster to Flux, which adopts each release the playbook installed. Flux reconciles everything else from the repository.

## Table of Contents

* [Roles](#roles)
* [Requirements](#requirements)
* [Installation](#installation)
* [Usage](#usage)
* [Variables](#variables)
* [State on the Host](#state-on-the-host)
* [Testing](#testing)
* [License](#license)

## Roles

The playbook runs them in this order.

| Role | What it does |
| --- | --- |
| `k3s` | Installs k3s without its bundled Traefik, ServiceLB, Gateway API CRDs, network policy, kube-proxy and flannel, ready for Cilium and Flux. Refuses to install over a previous cluster's Cilium state. |
| `cilium` | Applies the cluster's Namespaces, then installs Cilium with Helm, from the same values Flux later manages, before Flux exists. Applies the cluster's baseline network policy and `kube-system`'s policies. |
| `cert_manager` | Installs cert-manager from `cert-manager-values.yaml`, the values Flux later manages. |
| `trust_manager` | Installs trust-manager from `trust-manager-values.yaml`, the values Flux later manages. |
| `openbao` | Installs OpenBao with its certificates, Bundles, network policy and local redirect, gives it a static seal key in Secret `openbao-seal-key` so it unseals itself, initializes it, and keeps its recovery keys and a copy of the seal key in GPG-encrypted keyfiles. |
| `opentofu` | Writes the Postgres superuser Secret, SeaweedFS's admin identity for OpenBao, then applies `terraform/openbao`, which sets up OpenBao's secrets engines, PKI and Kubernetes authentication. A changed credential gets a new write-only version, so OpenTofu sends it to OpenBao on the same run. |
| `spire` | Installs SPIRE, whose CA OpenBao's PKI root signs, so the Flux controllers have identities when they start. |
| `flux` | Installs Flux, its Git credentials and the network policy Flux needs to fetch its first source. |

## Requirements

* `ansible-core` 2.19 or later, tested with 2.21.5
* The `kubernetes.core` (6.5.0 or later) and `cloud.terraform` (4.0.0 or later) collections, and the `kubernetes` Python package
* A checkout of the data science cluster repository. The roles read its manifests, its cluster-config and `terraform/openbao` through `repo_root`.
* On the host: `flux`, `gpg`, `helm` 4, `kubectl`, `tofu`, and `gh` when no GitHub App is configured
* `sudo` for the k3s install and `/etc/rancher/k3s/`

The repository's [Installation](https://github.com/DragonBishop/data_science_cluster/blob/main/docs/INSTALLATION.md) guide covers installing each tool.

## Installation

From the repository root, whose `ansible.cfg` adds `ansible/` to the collections path:

```bash
uv run ansible-galaxy collection install --upgrade -p ansible ansible/ansible_collections/dragonbishop/cluster
```

`-p ansible` names the path where the collection already counts as installed, so it stays in place, and `--upgrade` resolves its `galaxy.yml` dependencies and installs them beside it. Without `-p`, the install treats the collection as new and deletes the directory it installs from.

## Usage

```bash
uv run ansible-playbook dragonbishop.cluster.data_cluster --ask-become-pass
```

`just bootstrap` runs the install and the playbook, and passes on any extra flags. The playbook is idempotent, and a second run changes nothing.

Each role has its own tag. `opentofu` also carries `openbao`:

```bash
just bootstrap --tags opentofu
```

The playbook asks for three secrets. A run that initializes OpenBao needs the GPG passphrase, and with it empty the `openbao` role refuses and writes no keyfile. On a cluster where OpenBao is already initialized, the playbook also asks for the root token.

| Input | Source | Used for |
| --- | --- | --- |
| `openbao_gpg_passphrase` | prompt | Encrypting OpenBao's recovery and seal keyfiles, and decrypting the seal keyfile to restore its Secret |
| `opentofu_state_encryption_passphrase` | prompt | Encrypting the `terraform/openbao` state |
| `opentofu_postgres_superuser_password` | prompt | The Postgres superuser password OpenTofu writes to OpenBao |
| `openbao_root_token` | prompt, or `OPENBAO_ROOT_TOKEN` | Logging in to an initialized OpenBao |
| `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY_PATH` | environment | Flux's Git credentials from a GitHub App. Without them, the `flux` role uses `gh auth token`. |
| `FLUX_GIT_BRANCH` | environment | Points the `flux-system` GitRepository at another branch |
| `target_host` | extra var | The host to provision, `localhost` by default |

## Variables

`playbooks/group_vars/all/` holds the variables Ansible loads beside the playbook:

* `ansible.yml`: `repo_root`, `kubeconfig_path`, the OpenBao namespace and pod, and `cluster_config`, which merges every fragment of the repository's `infrastructure/cluster-config/`
* `certificates.yml`, `cpu_memory.yml`, `networking.yml`, `replicas.yml`, `storage.yml` and `versions.yml`: the cluster-config keys the roles use, one file per cluster-config category, routed to lowercase variables such as `k3s_version` and `cilium_version`. Flux reads the same keys, so Ansible and Flux install the same versions and values.

The role defaults:

| Variable | Default | Role |
| --- | --- | --- |
| `k3s_install_script_url` | `https://get.k3s.io` | `k3s` |
| `openbao_recovery_keyfile` | `{{ openbao_local_dir }}/recovery-keys.gpg` | `openbao` |
| `openbao_seal_keyfile` | `{{ openbao_local_dir }}/seal-key.gpg` | `openbao` |
| `opentofu_binary` | `/usr/local/bin/tofu` | `opentofu` |
| `opentofu_secrets_dir` | `~/.config/data_science_cluster` | `opentofu` |
| `opentofu_secrets_wo_version_file` | `{{ opentofu_secrets_dir }}/openbao-secrets-wo-version` | `opentofu` |
| `opentofu_rotate_secrets_marker` | `{{ opentofu_secrets_dir }}/rotate-openbao-secrets` | `opentofu` |

## State on the Host

* `/etc/rancher/k3s/config.yaml`: the k3s config
* `.local/openbao/recovery-keys.gpg` in the repository: the recovery keys `generate-root` needs, mode 0600, written once when OpenBao is initialized.
* `.local/openbao/seal-key.gpg` in the repository: a copy of the static seal key in Secret `openbao-seal-key`, mode 0600. When the Secret is missing, the `openbao` role restores it from this file.
* `terraform/openbao/terraform.tfstate`: the encrypted OpenTofu state
* `~/.config/data_science_cluster/openbao-secrets-wo-version`: the version of the secrets OpenTofu writes. A run that changes the Postgres password or SeaweedFS's admin key pair records a new version. Create `rotate-openbao-secrets` beside it, and the next run gives OpenBao a new SeaweedFS admin key pair and removes the marker.

The run that initializes OpenBao prints the root token and the recovery keys once. Store them in a password manager.

## Testing

`extensions/molecule/` holds a Molecule unit scenario for each decision a role makes, and one scenario for the whole playbook.

| Scenario | Proves |
| --- | --- |
| `unit-cert-manager-values` | The pinned cert-manager chart renders with the values the role renders, and its schema accepts them |
| `unit-k3s-config` | `config.yaml` disables flannel, kube-proxy, network policy, Traefik, ServiceLB and the bundled Gateway API CRDs, enables secrets encryption, and sets `write-kubeconfig` |
| `unit-k3s-newer-version` | With a k3s newer than `K3S_VERSION` installed, the install refuses the downgrade and leaves that k3s in place |
| `unit-k3s-stale-cilium-dir` | With `/run/cilium` present and no k3s installed, the install refuses, naming `/run/cilium` |
| `unit-k3s-stale-cilium-interface` | With a `cilium_host` interface and no `/run/cilium`, the install refuses, naming `/sys/class/net/cilium_host` |
| `unit-openbao-keyfile` | The recovery keys are written once to a mode-0600 GPG file that decrypts to exactly those keys, and a second run skips the write |
| `unit-openbao-no-passphrase` | With an empty GPG passphrase, the role refuses and writes no keyfile |
| `unit-openbao-values` | The pinned OpenBao chart renders with the values the role renders, and its schema accepts them |
| `unit-opentofu` | With the rotation marker present, OpenTofu gets a new secrets version, the file holds it, and the marker is gone |
| `unit-trust-manager-values` | The pinned trust-manager chart renders with the values the role renders, and its schema accepts them |
| `full-playbook` | The whole playbook on a fresh host: converge, idempotence, then the seal key Secret is deleted, the `openbao` role restores it from its keyfile, and a replaced OpenBao pod unseals itself on the static seal and Raft |

The unit scenarios share one podman container, which `default` creates and destroys. From the collection's directory:

```bash
molecule test --all --exclude full-playbook
```

`full-playbook` provisions the machine it runs on, and the repository's `e2e.yml` runs it on a throwaway GitHub runner. Lint the collection from the repository root:

```bash
uv run ansible-lint --offline ansible/ansible_collections/dragonbishop/cluster
```

## License

MIT. See [LICENSE](LICENSE).
