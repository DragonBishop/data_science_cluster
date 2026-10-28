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

## Bootstrap

One-time, first-install setup: see [Installation](INSTALLATION.md) for Requirements and what the script does.

| Command | Operation | When |
| --- | --- | --- |
| `just setup-firewall` | Configure host firewall rules | Before install; opens what Kubernetes and Cilium need in firewalld (Fedora) or ufw (Ubuntu) |
| `just preflight` | Run host readiness check | Verify host tooling, `gh` auth, firewall rules, and reserved IP range before install |
| `just bootstrap` (accepts flags like `--tags`, `--check`, `-v`) | Run full cluster bootstrap via Ansible | Install k3s, Cilium, cert-manager, trust-manager and OpenBao, apply `terraform/openbao`, then install SPIRE and Flux |

## Cluster Lifecycle

Start and stop the cluster each work session, check its health, and inspect or reach into it while it runs.

| Command | Operation | When |
| --- | --- | --- |
| `just start` | Start the cluster | Each work session; starts k3s, unseals OpenBao, wakes `postgres-cluster` from hibernation and resumes its scheduled backups |
| `just status` | Check overall cluster health | Post-install verification or periodic health check across Flux, Gateway/DNS, cert-manager, database, backups, SeaweedFS, and Hubble |
| `just stop` (`just stop --force` if a stuck stop needs it) | Stop the cluster | Each work session; gracefully hibernates CNPG PostgreSQL before shutting down k3s |
| `just uninstall` | Uninstall k3s and clear stale local state | Reinstalling from scratch; runs `k3s-uninstall.sh` and clears `.local/openbao`, the local Hubble cache, orphaned `terraform/openbao` state, and Cilium's persistent host files; reboot before the next `just bootstrap` |
| `just fuzzypods` | Interactively inspect a pod | Ad hoc troubleshooting; fuzzy-select a pod from all namespaces and describe it |
| `just gateway-check` (`just gateway-check <DOMAIN> [HOST]`) | Verify Gateway routing | Post-install verification or testing Gateway HTTPRoute and TLS edge certificates |
| `just hubble` (runs `hubble status`) / `just hubble observe --follow` | Run the Hubble CLI against Hubble Relay | Relay status, or real-time network and security flow inspection over mTLS |
| `just bao-ca` | Export OpenBao CA and print its address | OpenBao API and UI are at `https://127.0.0.1:8210` through a local redirect; exports the internal CA to `.local/openbao/certs/` |
| `just bao-shell` | Open interactive OpenBao shell | Direct `bao` CLI access inside `openbao-0` pod with a sanitized environment |

## Database

Restoring from a backup is in [Backups and Restore](BACKUPS_RESTORE.md).

| Command | Operation | When |
| --- | --- | --- |
| `kubectl cnpg psql postgres-cluster -n databases` | Connect via psql (superuser, in-cluster) | Ad hoc direct administrative query access as `postgres` superuser |
| `just backup` | Trigger a manual DB backup | Before schema changes or risky migrations; writes backup to SeaweedFS S3 |
| `kubectl get scheduledbackup -n databases -o yaml \| grep -i suspend` | Check scheduled backup status | Confirming automated nightly backups are active (`suspend: false`) |
| `kubectl cnpg status postgres-cluster -n databases` | Verify CNPG cluster state | Detailed PostgreSQL replication, WAL archiving, and instance diagnostics |
