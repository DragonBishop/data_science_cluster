# Cluster Operations

* [Development](#development)
* [Bootstrap](#bootstrap)
* [Cluster Lifecycle](#cluster-lifecycle)
* [Database](#database)

Organized to match the justfile's own section layout (`just --list --unsorted` shows every recipe in file order).

## Development

| Command | Operation |
| --- | --- |
| `just setup` | Set up the dev environment (`install`, then `git-setup`) |
| `just install` | Install every dependency group and extra from the lockfile |
| `just update` | Update packages and the lockfile |
| `just git-setup` | Install the pre-commit hooks with `prek` |
| `flux build kustomization <name> --path ./<path> --kustomization-file ./clusters/local/<name>.yaml` | Render a Kustomization the way Flux applies it, with cluster-config values from the running cluster |
| `flux build kustomization <name> --path ./<path> --kustomization-file ./clusters/local/<name>.yaml --dry-run` | Render a Kustomization before the cluster has it, leaving `${VAR}` placeholders in place |

Render manifests with `flux build` before pushing a change. `kubectl kustomize` refuses `apps/databases/objectstore/`, because its generator reads `../cluster/databases-cluster.yaml` ([Troubleshooting](TROUBLESHOOTING.md#gitops)).

## Bootstrap

One-time, first-install setup: see [Installation](INSTALLATION.md) for Requirements and what the script does.

| Command | Operation | When |
| --- | --- | --- |
| `just setup-firewall` | Configure host firewall rules | Before install. Opens what Kubernetes and Cilium need in firewalld (Fedora) or ufw (Ubuntu) |
| `just preflight` | Run host readiness check | Before install. Verifies host tooling, that the Flux CLI matches `gotk-components.yaml`, `gh` auth, firewall rules and the reserved IP range. Prints the shortest install or update commands for missing or mismatched tools, and the fix command for firewall rules |
| `just bootstrap` (accepts flags like `--tags`, `--check`, `-v`) | Run full cluster bootstrap via Ansible | Install k3s, Cilium, cert-manager, trust-manager and OpenBao, apply `terraform/openbao`, then install SPIRE and Flux |

`just bootstrap` prompts for the OpenBao root token, state-encryption passphrase and PostgreSQL superuser password, and asks whether to install the cluster's desktop and OpenBao CAs into the machine's trust store ([Access Policy](ACCESSPOLICY.md#workstation-trust)). See [Access Policy](ACCESSPOLICY.md#provisioning-credentials) for credential handling.

Every `just bootstrap` run, including one limited by `--tags`, ends with a `core-test` PipelineRun and fails when `core-test` fails.

Flux follows `main`. To test a pull request on the workstation, point Flux at its branch with `FLUX_GIT_BRANCH=<branch> just bootstrap --tags flux`. Each commit Flux then applies from that branch starts `core-test-<sha>` through Trigger `pull-request`. Run `just bootstrap --tags flux` without `FLUX_GIT_BRANCH` to return Flux to `main`.

GitHub e2e runs `code-quality` after provisioning. To run it manually with `tkn pipeline start`, use namespace `tekton-pipelines`, service account `code-quality`, the Flux source revision as the `revision` parameter and a PVC-backed workspace named `source`.

## Cluster Lifecycle

Start and stop the cluster each work session, check its health, and inspect or reach into it while it runs.

| Command | Operation | When |
| --- | --- | --- |
| `just start` | Start the cluster | Each work session. Starts k3s, checks that OpenBao unsealed itself, wakes `postgres-cluster` from hibernation, resumes its scheduled backups, and checks the kubectl and cnpg plugin versions |
| `just status` | Summarize cluster health | Any time. Lists Flux Kustomizations that are not Ready, firing alerts from Alertmanager, Prometheus scrape targets that are down, and `kubectl cnpg status` for the database. Reads Alertmanager and Prometheus through the Kubernetes API server's service proxy and uses `jq` for those summaries |
| `just core-test` | Run the core integration test | After a change, or when `just status` shows a problem. Starts a `core-test` PipelineRun at the revision Flux has applied, follows its logs with `tkn`, and fails when the run fails |
| `just stop` (`just stop --force` stops k3s even when hibernation isn't confirmed) | Stop the cluster | Each work session. Gracefully hibernates CNPG PostgreSQL before shutting down k3s |
| `just uninstall` | Uninstall k3s and clear stale local state | Reinstalling from scratch. Runs `k3s-uninstall.sh` and clears `.local/openbao`, orphaned `terraform/openbao` state, Cilium's persistent host files and the cluster's CAs in the system trust store. Reboot before the next `just bootstrap` |
| `just fuzzypods` | Interactively inspect a pod | Ad hoc troubleshooting. Fuzzy-selects a pod from all namespaces and describes it |
| `just hubble` (runs `hubble status`) / `just hubble observe --follow` | Run the Hubble CLI inside the Cilium agent | Hubble status, or real-time network and security flow inspection |
| `just ui <hubble\|tekton\|openbao>` | Open a cluster UI in the browser | Hubble UI (`https://localhost:12000`), the Tekton Dashboard (`https://localhost:12001`) or OpenBao's UI (`https://localhost:8210/ui/`). In VS Code, run "Simple Browser: Show" with the printed URL. Grafana is at `https://grafana.<INTERNAL_DOMAIN>` |
| `just bao-shell` or `just bao-shell --login` | Open an interactive OpenBao shell | Run `bao` inside `openbao-0`. Use `--login` to authenticate before opening the shell |

### Request a temporary OpenBao login

Run `just bao-shell --login` and enter an OpenBao token that can read the credential path you need. The token stays in the shell session and subsequent `bao` commands use it automatically. Then request the login you need.

```sh
bao read database/creds/ds-app-role  # PostgreSQL login
bao read seaweedfs/creds/loki        # S3 key pair scoped to Loki's bucket
```

If your token can list roles, use `bao list database/roles` or `bao list seaweedfs/roles` to find the role you need.

## Database

Restoring from a backup is in [Backups and Restore](BACKUPS_RESTORE.md).

| Command | Operation | When |
| --- | --- | --- |
| `kubectl cnpg psql postgres-cluster -n databases` | Connect via psql (superuser, in-cluster) | Ad hoc direct administrative query access as `postgres` superuser |
| `just backup` | Trigger a manual DB backup | Before schema changes or risky migrations. Writes a backup to SeaweedFS S3 |
| `kubectl get scheduledbackup -n databases -o yaml \| grep -i suspend` | Check scheduled backup status | Confirming automated nightly backups are active (`suspend: false`) |
| `kubectl cnpg status postgres-cluster -n databases` | Verify CNPG cluster state | Detailed PostgreSQL replication, WAL archiving, and instance diagnostics |
