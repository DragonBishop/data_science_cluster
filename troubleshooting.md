# Troubleshooting Guide

## Startup and Shutdown

* **`start-cluster.sh` refuses to start**
  * **What's happening:** The system's background k3s service (`k3s.service`) is already active. Running two k3s instances against the same data directory will corrupt your cluster.
  * **How to fix it:** Hand lifecycle management over to the scripts. Run `sudo systemctl disable --now k3s`. `systemctl is-enabled k3s` confirms which supervisor owns it. *(Note: `stop-cluster.sh` disables this automatically the first time it finds it).*

* **`stop-cluster.sh` halts before k3s actually stops**
  * **What's happening:** The script requires the database to hibernate before shutting down the cluster. If k3s stops while PostgreSQL is running, the database is killed ungracefully.
  * **How to fix it:** Read the halt message to see what is holding up the process. To shut down immediately and accept a crash recovery on the next boot, use the `--force` flag.

* **Hibernation shows as "not confirmed" when stopping**
  * **What's happening:** The script could not verify that the database shut down cleanly.
  * **How to check if it actually failed:** On the next start, run `kubectl logs -n databases postgis-cluster-1 -c postgres | grep -i "cluster state"`. `Database cluster state: shut down` with a timestamp means the shutdown was clean and the script did not wait long enough to observe it.
  * **If it genuinely failed, it's usually one of three things:**
    1. **Idle database connections:** `spec.smartShutdownTimeout` in `postgis-cluster.yaml` is set to 15 (the CNPG default is 180). Postgres waits that long for existing connections to close before escalating to a fast shutdown, which disconnects them. Check for active connections before stopping: `kubectl exec -n databases postgis-cluster-1 -c postgres -- psql -U postgres -c "select pid, usename, application_name, state from pg_stat_activity where backend_type='client backend';"`
    2. **CloudNativePG (CNPG) operator isn't available:** The shutdown command was sent, but the operator was not running to process it. The stop script usually catches this first and halts with a specific warning.
    3. **The cluster isn't healthy:** A cluster will not hibernate from a broken state, such as a pod in CrashLoop or mid-boot. Check with `kubectl cnpg status postgis-cluster -n databases`.

* **Port 6443 is still bound/in-use after running `stop-cluster.sh`**
  * **What's happening:** The API server stopped, but containerd shims are still running.
  * **How to fix it:** Once hibernation is confirmed, run `sudo k3s-killall.sh`. It cleans up leftover processes and unmounts directories. Run it before restarting if the previous stop was forced.

---

## Vault

* **Vault reports as "sealed" when it isn't (or prompts for a GPG password on every run)**
  * **What's happening:** `vault status` returns `0` for unsealed, `2` for sealed, and another code if the command itself failed. Might be a bad certificate or a dead service. A check that greps the output for "false" treats a failed connection as sealed and goes looking for unseal keys.
  * **How to fix it:** Diagnose using the exit code rather than the text output:

    ```bash
    VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/opt/vault/tls/tls.crt vault status; echo "exit=$?"
    ```

    Confirm the certificate path (`/opt/vault/tls/tls.crt`) is correct and readable (`sudo stat -c "%a %U:%G %n" /opt/vault/tls`). The certificate must include an `IP:127.0.0.1` SAN. If Vault is re-sealing without a reboot, check `systemctl status vault` for a crashing service.

* **GPG decryption fails**
  * **What's happening:** The script cannot read or decrypt the unseal keys.
  * **How to fix it:**
    1. Confirm `~/.vault-keys.gpg` exists and is mode `600` (`ls -l ~/.vault-keys.gpg`).
    2. Confirm the passphrase matches the one set in Step 2.
    3. *Technical note:* `vault operator unseal` does not accept piped input, so the script passes the key via `vault write sys/unseal key=-` instead. To exercise that mechanism without changing the seal state, run `printf 'SENTINEL\n' | vault write -output-curl-string sys/unseal key=-` to get output containing `SENTINEL`.

* **Vault throws a "permission denied" error**
  * **How to fix it:** Check the policy and role from Step 5. `vault policy read postgis-policy` shows the five paths it should grant; `vault read auth/kubernetes/role/postgis-role` shows the service account and namespace it is bound to.

* **Secrets are failing to mount into Kubernetes**
  * **How to fix it:** Run `kubectl describe vaultstaticsecret <name> -n databases` (or `vaultdynamicsecret` for dynamic credentials). The status conditions at the bottom report why VSO could not pull the secret.

* **Dynamic credentials never reach a "Ready" state**
  * **How to fix it:** `kubectl describe vaultdynamicsecret postgis-app-dynamic-secret -n databases` reports Vault's error.

---

## Database

* **Database pod fails to initialize**
  * **How to fix it:** Run `kubectl describe pod <pod_name> -n databases` and read the Events stream at the bottom. It reports scheduling failures, insufficient resources, and image pull failures.

* **Password authentication fails even though the password is correct**
  * **How to fix it:** Confirm both `enableSuperuserAccess: true` and `superuserSecret` are set in `postgis-cluster.yaml`. With the first missing, CNPG nulls the password on every reconciliation. Confirm the `username` field in `secret/postgis` is exactly `postgres`; CNPG rejects any other value before applying the password.

* **A role issued by Vault cannot create tables in a schema**
  * **What's happening:** the schema predates the `app_readwrite_new_schema` event trigger, so no `CREATE` grant was issued on it. `pg_read_all_data` and `pg_write_all_data` cover data access, not DDL.
  * **How to fix it:** `GRANT USAGE, CREATE ON SCHEMA <name> TO app_readwrite;`. Confirm the event trigger exists with `\dy`; without it, schemas created from now on have the same problem.

* **Tables created by a lease are unreadable by the next one**
  * **What's happening:** the lease was issued before `ALTER ROLE ... SET role = app_readwrite` was added to `creation_statements`, so it owns its objects. `DROP ROLE` at lease expiry also fails with `cannot be dropped because some objects depend on it`.
  * **How to fix it:** update the role definition in Step 8, then `vault lease revoke -prefix database/creds/postgis-app-role`. Reassign what already exists as `postgres`: `REASSIGN OWNED BY "<lease-role>" TO app_readwrite;`, then drop the stale role.
* **Application credentials stop working after a password rotation**
  * **What's happening:** VSO updated the Secret, but CNPG did not reload it.
  * **How to fix it:** Re-apply the reload label to trigger a reconciliation: `kubectl label secret postgis-app-credentials -n databases cnpg.io/reload=true --overwrite` (use `postgis-app-dynamic-credentials` for the dynamic credential). If the rotation was of the superuser password, also update `database/config/postgis-cluster` in Vault see Step 8.

* **Database connections fail with a hostname mismatch when using `sslmode=verify-full`**
  * **What's happening:** The name used to connect is not in the certificate.
  * **How to fix it:** Check `dnsNames` and `ipAddresses` in `apps/databases/postgres-tls.yaml`. `postgis-cluster-rw`, `-ro`, and `-r` are covered in both short and fully-qualified forms, along with `localhost`, `127.0.0.1`, `postgres.internal`, and the shared Gateway's LAN IP. Adding a name there causes cert-manager to reissue the certificate. If the cluster was rebuilt, the CA also changed, re-run the `root.crt` command in Step 7.

* **Barman Cloud Plugin backups start failing**
  * **What's happening:** The database cannot reach or authenticate to the object store.
  * **How to fix it:** Run `kubectl cnpg status postgis-cluster -n databases` and read the plugin's status block. Confirm the `plugin-barman-cloud` Deployment in `cnpg-system` is running (`kubectl rollout status deployment -n cnpg-system plugin-barman-cloud`). Confirm the `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY` fields in the `seaweedfs-credentials` Secret match the credentials inside its `config` field; a mismatch between the two produces no error until an archive is attempted. Confirm the bucket exists:

    ```bash
    kubectl exec -n databases seaweedfs-master-0 -- sh -c 'echo "fs.ls /buckets" | weed shell -master=localhost:9333'
    # cnpg-backups
    ```

    If it is missing, re-reconcile `apps/databases/seaweedfs-release.yaml` (`flux reconcile helmrelease seaweedfs -n databases`); `createBuckets` in that chart's values creates it at install.

---

## Tooling

* **Pods are stuck in `ContainerCreating` indefinitely**
  * **What's happening:** Cilium may still initializing. Without the CNI, the container sandbox cannot be created.
  * **How to fix it:** Run `cilium status --wait`. If it persists after Cilium is running, check that the BPF filesystem is mounted (`mount | grep bpf`); a hard shutdown can leave it unmounted. *(Note: `/var/run/cilium/cgroupv2` is an active mount and must be unmounted before running `rm -rf /var/run/cilium`)*.

* **Pods are running but completely unreachable (Stale Cilium Endpoints)**
  * **What's happening:** After a forced stop or an agent restart, pods can retain endpoints that no longer route.
  * **How to fix it:** Run `kubectl exec -n kube-system ds/cilium -- cilium endpoint list` to view active endpoints. Delete the affected pods (`kubectl delete pod <pod_name>`); the controller recreates them with new network identities.

* **Headlamp shows a stale or failed connection**
  * **What's happening:** Headlamp reads `~/.kube/config` as written by `sync-kubeconfig.sh`. Running that script while the cluster was down produces a profile that does not connect.
  * **How to fix it:** Start the cluster, run `sync-kubeconfig.sh` again, and reconnect Headlamp.

* **Hubble Relay never becomes Ready (`Startup probe failed: service unhealthy, responded with "NOT_SERVING"`)**
  * **What's happening:** Hubble Relay is a pod, but it reaches cilium-agent's Hubble gRPC port on the **host's own IP** (cilium-agent runs `hostNetwork: true`), so that connection is pod→host traffic, not pod→pod. If `ufw` is active without the rules from `INSTALLATION.md`'s Prerequisites, its default-deny `INPUT` policy drops it silently, Relay just times out with no useful error on either side.
  * **How to fix it:** Confirm it's actually this: `sudo iptables -L INPUT -n -v | head` a large, growing packet count against the final `DROP` policy confirms it. Apply the `ufw` rules in `INSTALLATION.md`'s Prerequisites, then see the next entry, a firewall fix alone does not retry an already-failed HelmRelease.

* **`flux reconcile helmrelease cilium` reports `RetriesExceeded` / `Stalled` and does nothing**
  * **What's happening:** After enough failed upgrade attempts (e.g. from the Hubble issue above), `helm-controller` hits its retry budget and marks the release `Stalled` with a **terminal** error. A plain reconcile re-checks that same exhausted state and fails instantly; it does not attempt a new upgrade.
  * **How to fix it:** Clear the retry lock first, then it reconciles normally:

    ```bash
    flux suspend helmrelease cilium -n kube-system
    flux resume helmrelease cilium -n kube-system
    ```

    `flux get helmrelease cilium -n kube-system` should show `Ready: True` after. If the underlying cause isn't actually fixed yet, this just produces a fresh failed attempt instead of a stuck one; check `helm history cilium -n kube-system` and pod events for the real error.
    