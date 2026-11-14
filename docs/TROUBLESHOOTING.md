# Troubleshooting Guide

Diagnostic procedures and remediation steps for issues across Ansible bootstrap, cluster lifecycle, networking, GitOps controllers, secrets management, and database storage.

## Table of Contents

* [Ansible Provisioning](#ansible-provisioning)
* [Cluster Lifecycle](#cluster-lifecycle)
* [Networking](#networking)
* [GitOps](#gitops)
* [OpenBao Secrets](#openbao-secrets)
* [Database Storage](#database-storage)

---

## Ansible Provisioning

* **Ansible playbook fails with missing collection errors**
  * **What's happening:** The Galaxy collection `cloud.terraform` is missing. It sits outside the `ansible` package and installs separately, as a dependency in the `dragonbishop.cluster` `galaxy.yml`.
  * **How to fix it:** Install the collection's Galaxy dependencies:

    ```bash
    uv run ansible-galaxy collection install --upgrade -p ansible ansible/ansible_collections/dragonbishop/cluster
    ```

* **Playbook fails during k3s installation or times out waiting for `/etc/rancher/k3s/k3s.yaml`**
  * **What's happening:** Leftover state, containerd shims, or stale Cilium BPF mounts from a previous installation are preventing the k3s server from initializing cleanly.
  * **How to fix it:** Run `just uninstall`, reboot, then re-run `just bootstrap`.

* **Every pod's probes time out and nothing reaches the API server after a reinstall**
  * **What's happening:** The previous cluster's Cilium BPF programs are still attached in the kernel. They outlive `k3s-uninstall.sh` and silently drop host↔pod traffic.
  * **How to fix it:** Reboot, then re-run `just bootstrap`.

* **Playbook fails during Flux bootstrap with GitHub authentication errors**
  * **What's happening:** `gh` CLI is either unauthenticated or lacks the required OAuth scopes to manage repository webhooks and deploy keys.
  * **How to fix it:** Run `gh auth login` and select `GitHub.com`, `HTTPS`, and authenticate with your browser or a personal access token with repo privileges. Verify with `gh auth status`.

* **Flux fails with `unable to read private key file: ... no such file or directory`**
  * **What's happening:** The `.pem` at `GITHUB_APP_PRIVATE_KEY_PATH` is gone. GitHub shows a private key once, when it generates it. A deleted, moved or overwritten key is gone for good.
  * **How to fix it:** Generate a new key from the GitHub App's settings page ("Generate a private key"). The App and its installation keep working with the new key. Save the new `.pem` wherever `GITHUB_APP_PRIVATE_KEY_PATH` points and re-run bootstrap.

* **OpenTofu role fails to apply OpenBao configuration**
  * **What's happening:** OpenBao is sealed, its local redirect on 127.0.0.1:8210 is missing, or OpenTofu state encryption passphrase was mistyped.
  * **How to fix it:** Verify the `openbao-0` pod is Running and unsealed (`kubectl exec -n openbao openbao-0 -- bao status`). If it's sealed, see "OpenBao stays sealed after a restart" below. Run OpenTofu manually to inspect verbose output:

    ```bash
    tofu -chdir=terraform/openbao init
    tofu -chdir=terraform/openbao plan
    ```

* **OpenTofu role fails with `Expecting value: line 2 column 1 (char 1)`**
  * **What's happening:** This is a Python `JSONDecodeError` from inside the `cloud.terraform` Ansible module, not a Terraform error. `tofu version -json`, the first command the module runs, prints a "CLI configuration file does not exist" warning to stdout ahead of the actual JSON whenever `TF_CLI_CONFIG_FILE` is unset and `~/.config/terraform/terraformrc` is missing. The module passes that combined output straight to `json.loads()`.
  * **How to fix it:** Create the default config file so `tofu` stops warning about its absence:

    ```bash
    mkdir -p ~/.config/terraform && touch ~/.config/terraform/terraformrc
    ```

* **OpenTofu apply fails to decrypt state, or succeeds with an unfamiliar passphrase**
  * **What's happening:** `terraform/openbao`'s local state is encrypted (`terraform/openbao/encryption.tf`) with whatever passphrase was typed into the "Terraform state encryption passphrase" prompt on the run that created it. Each later run must type the same passphrase. A different passphrase against existing state fails with `decryption failed for all provided methods`.
  * **How to fix it:** If the cluster, and with it OpenBao, has been rebuilt since that state was written, the state is orphaned. `just uninstall` clears it (see [`INSTALLATION.md`'s Clean Host State step](INSTALLATION.md#clean-host-state-if-reinstalling)). Re-apply with a fresh passphrase. The old passphrase matters when the state still describes the running OpenBao instance.

---

## Cluster Lifecycle

* **`start-cluster.sh` refuses to start**
  * **What's happening:** The system's background k3s service (`k3s.service`) is already active. Running two k3s instances against the same data directory will corrupt your cluster.
  * **How to fix it:** Hand lifecycle management over to the scripts. Run `sudo systemctl disable --now k3s`. `systemctl is-enabled k3s` confirms which supervisor owns it.

> [!NOTE]
> `stop-cluster.sh` disables the background `k3s.service` the first time it finds it. The manual command above is a one-time step.

* **`stop-cluster.sh` halts before k3s actually stops**
  * **What's happening:** The script requires the database to hibernate before shutting down the cluster. If k3s stops while PostgreSQL is running, the database is killed ungracefully.
  * **How to fix it:** Read the halt message to see what is holding up the process. To shut down immediately and accept a crash recovery on the next boot, use the `--force` flag.

> [!CAUTION]
> `--force` skips the graceful hibernation wait and kills PostgreSQL mid-shutdown. Use it when you are prepared for crash recovery on the next start.

* **Hibernation shows as "not confirmed" when stopping**
  * **What's happening:** The script could not verify that the database shut down cleanly.
  * **How to check if it actually failed:** On the next start, run `kubectl logs -n databases postgres-cluster-1 -c postgres | grep -i "cluster state"`. `Database cluster state: shut down` with a timestamp means the shutdown was clean and the script did not wait long enough to observe it.
  * **If it genuinely failed, it's usually one of three things:**
    1. **Idle database connections:** `spec.smartShutdownTimeout` in `apps/databases/cluster/databases-cluster.yaml` reads `POSTGRES_SMART_SHUTDOWN_TIMEOUT`, which is 15 seconds (the CNPG default is 180). Postgres waits that long for open connections to close, then switches to a fast shutdown that disconnects them. Check for active connections before stopping: `kubectl cnpg psql postgres-cluster -n databases -- -c "select pid, usename, application_name, state from pg_stat_activity where backend_type='client backend';"`
    2. **The CloudNativePG (CNPG) operator is down:** The shutdown command was sent while the operator was stopped. The stop script usually catches this first and halts with a specific warning.
    3. **The cluster is unhealthy:** A cluster hibernates from a healthy state. A pod in CrashLoop or mid-boot blocks it. Check with `kubectl cnpg status postgres-cluster -n databases`.

* **Port 6443 is still bound/in-use after running `stop-cluster.sh`**
  * **What's happening:** The API server stopped, but containerd shims are still running.
  * **How to fix it:** Run `sudo k3s-killall.sh` by hand. It cleans up leftover processes and unmounts directories.

---

## Networking

* **Pods are stuck in `ContainerCreating` indefinitely**
  * **What's happening:** Cilium may still be initializing. Without the CNI, the container sandbox cannot be created.
  * **How to fix it:** Run `cilium status --wait`. If it persists after Cilium is running, check that the BPF filesystem is mounted (`mount | grep bpf`). A hard shutdown can leave it unmounted.

> [!CAUTION]
> `/var/run/cilium/cgroupv2` is an active mount. Unmount it before running `rm -rf /var/run/cilium`. Otherwise the `rm -rf` fails partway through or tears into a live mount.

* **Pods are running but completely unreachable (Stale Cilium Endpoints)**
  * **What's happening:** After a forced stop or an agent restart, pods can keep stale endpoints that have stopped routing.
  * **How to fix it:** Run `kubectl exec -n kube-system ds/cilium -- cilium endpoint list` to view active endpoints. Delete the affected pods (`kubectl delete pod <pod_name>`). The controller recreates them with new network identities.

* **Hubble Relay stays unready (`Startup probe failed: service unhealthy, responded with "NOT_SERVING"`)**
  * **What's happening:** Hubble Relay is a pod that reaches cilium-agent's Hubble gRPC port on the host's own IP, because cilium-agent runs `hostNetwork: true`. That connection is pod→host traffic. If `ufw` (Ubuntu/Debian) or `firewalld` (Fedora/RHEL) is active without the required forward/port rules from `INSTALLATION.md`'s Requirements, the host firewall drops it silently and Relay times out.
  * **How to fix it:** Confirm it's actually this: `sudo iptables -L INPUT -n -v | head` a large, growing packet count against the final `DROP` policy confirms it. Apply the `ufw` (Ubuntu/Debian) or `firewalld` (Fedora/RHEL) rules in `INSTALLATION.md`'s Requirements.

> [!IMPORTANT]
> A failed HelmRelease keeps its retry lock after the firewall fix. Clear it with the `RetriesExceeded` / `Stalled` entry below.

* **Gateway routing or TLS fails (`*.cluster.internal` domain unreachable)**
  * **What's happening:** The client cannot resolve the domain or route traffic to the Gateway IP.
  * **How to fix it:** Run `just gateway-check` to verify listener routing and TLS termination. Confirm CoreDNS custom zone is responding (`dig @192.0.2.242 <name>.cluster.internal`) and verify that Gateway listeners are programmed (`kubectl get gateway -n gateway internal-gateway`).

* **A `CiliumNetworkPolicy`/`CiliumClusterwideNetworkPolicy` `toPorts` rule drops traffic it should cover**
  * **What's happening:** Cilium enforces `toPorts` against the destination pod's container port. Traffic to a `ClusterIP` is DNATed to its backend port at the client's socket, before a packet reaches the wire. A request to `some-service:80` is policy-checked as traffic to the pod's real listening port, for example `:9090`.
  * **How to fix it:** Check the Service's `spec.ports[].targetPort` (or the pod's own named container port) rather than assuming the Service's `port:` value is what to write into the policy. `kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop -v` shows the real post-DNAT destination port in any `Policy denied` line while reproducing the failing request.

> [!IMPORTANT]
> Write `toPorts` against the pod's real listening port. Cilium enforces policy after the DNAT rewrite, at the client's socket.

---

## GitOps

* **`flux reconcile helmrelease cilium` reports `RetriesExceeded` / `Stalled` and does nothing**
  * **What's happening:** After enough failed upgrade attempts (e.g. from the Hubble issue above), `helm-controller` hits its retry budget and marks the release `Stalled` with a **terminal** error. A plain reconcile re-checks that exhausted state and fails at once, without a new upgrade attempt.
  * **How to fix it:** Clear the retry lock first, then it reconciles normally:

    ```bash
    flux suspend helmrelease cilium -n kube-system
    flux resume helmrelease cilium -n kube-system
    ```

    `flux get helmrelease cilium -n kube-system` should show `Ready: True` after.

> [!NOTE]
> With the underlying cause still in place, this produces a fresh failed attempt. Check `helm history cilium -n kube-system` and pod events for the real error.

* **Flux Kustomization reports `DependencyNotReady`**
  * **What's happening:** A Kustomization's `dependsOn` prerequisite is failing its health checks or still reconciling.
  * **How to fix it:** Check the dependency state with `flux get kustomizations -A` and trace the unready upstream Kustomization with `flux describe kustomization <name> -n flux-system`.

* **A `HelmChart`/`GitRepository` reconcile hangs on `dial tcp ...: i/o timeout` fetching from an external host**
  * **What's happening:** `flux` (`clusters/local/flux-system/flux-networkpolicy.yaml`) lets Flux's controllers reach an explicit FQDN allowlist on 443. A new external Helm/OCI chart source, or an existing one whose CDN backend changes, sends source-controller to a host outside that list. Cilium drops the connection silently. The FQDN to allow is often a different domain from the chart repo's own. Charts from `oci://quay.io/...` can redirect blob downloads through `cdnNN.quay.io`, and GitHub Pages chart indexes (`*.github.io`) serve release assets from `release-assets.githubusercontent.com`.
  * **How to fix it:** Confirm it's this with `kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop -v` while forcing a reconcile (`flux reconcile source chart <name> -n <namespace>`). A `Policy denied` line naming `identity ...->world` confirms it. Add the missing FQDN (`matchName`) or a wildcard (`matchPattern: "*.example.com"`) to `flux`, commit and push it (see the next entry), then reconcile.

* **A `kubectl apply`/patch to a Flux-managed resource works, then silently reverts a few minutes later**
  * **What's happening:** Most Kustomizations in this repo have `prune: true`. Flux treats git as the source of truth for everything it owns. A live edit changes the running object and leaves the git-tracked manifest as it was. The next reconcile restores the committed version.
  * **How to fix it:** Make the same edit in the source file, commit, and push before relying on it. `kubectl apply` is a temporary patch for anything a Kustomization's `path:` covers.

> [!IMPORTANT]
> Commit and push the fix together with any live patch to a `prune: true` Kustomization. The next reconcile reverts an uncommitted patch silently.

* **`kubectl kustomize apps/databases/objectstore` fails with `security; file '.../cluster/databases-cluster.yaml' is not in or below '.../objectstore'`**
  * **What's happening:** `apps/databases/objectstore/kustomization.yaml` generates ConfigMap `postgres-bootstrap-cluster` from `../cluster/databases-cluster.yaml`. `kubectl kustomize` refuses files outside the Kustomization's directory by default. Flux builds the directory without that restriction.
  * **How to fix it:** Render it with `flux build` ([Operations](OPERATIONS.md#development)). With `kubectl kustomize`, add `--load-restrictor LoadRestrictionsNone`.

* **Headlamp shows a stale or failed connection**
  * **What's happening:** Headlamp reads `~/.kube/config`, which k3s rewrites directly (`--write-kubeconfig`) every time `start-cluster.sh` runs. A stale profile means the file predates the current cluster instance.
  * **How to fix it:** Run `start-cluster.sh` to regenerate `~/.kube/config`, then reconnect Headlamp.

---

## OpenBao Secrets

* **OpenBao stays sealed after a restart**
  * **What's happening:** OpenBao unseals itself from the static seal key at `/openbao/userconfig/openbao-seal-key/key`, mounted from Secret `openbao-seal-key`. The pod needs that Secret to start. A Secret holding a different key leaves OpenBao sealed, and its log names the seal error. `bao status` returns `0` for unsealed, `2` for sealed, and another code if the command itself failed.
  * **How to fix it:**
    1. Check the status by its exit code: `kubectl exec -n openbao openbao-0 -- bao status; echo "exit=$?"`.
    2. Check the Secret and the log: `kubectl get secret openbao-seal-key -n openbao` and `kubectl logs openbao-0 -n openbao`.
    3. If the Secret is missing, inject the original seal key from your external store as `OPENBAO_SEAL_KEY` (or `openbao_seal_key`) and run `just bootstrap --tags openbao` to restore it. Then `kubectl delete pod openbao-0 -n openbao` starts OpenBao with it.

* **Bootstrap refuses because the seal key is missing**
  * **What's happening:** Secret `openbao-seal-key` is missing while OpenBao storage or an initialized server exists, and the run lacks an external seal key. Bootstrap refuses to generate a replacement key, which would lock existing Raft data away.
  * **How to fix it:** Retrieve the original key from your external store and inject it as `OPENBAO_SEAL_KEY` or `openbao_seal_key`. It must be 32 bytes, base64-encoded, without a trailing newline. For a fresh installation without OpenBao storage, Ansible generates the key automatically and prints it with the other credentials at the end of the play.

* **The OpenBao snapshot agent's Job fails**
  * **What's happening:** The chart's `openbao-snapshot` CronJob logs in as `openbao-snapshot-role`, saves a Raft snapshot and uploads it with the S3 key from Secret `openbao-snapshot-s3`. The `openbao-snapshot-credentials` holder pod's CSI mount fills that Secret.
  * **How to fix it:** `kubectl logs -n openbao job/<newest openbao-snapshot job>` names the failing step. For a login error, check that `openbao-snapshot-role` exists (`just bootstrap --tags opentofu`). For a missing S3 key, check that `deployment/openbao-snapshot-credentials` is Available. For an upload error, check that the `openbao-snapshots` bucket exists and that SeaweedFS's S3 certificate verifies against ConfigMap `openbao-root-ca`.

* **The OpenBao root token is needed and was lost**
  * **What's happening:** `bao operator init` prints the root token once. The bootstrap play prints it to the terminal at the end of a successful initialization run and keeps it off disk by design.
  * **How to fix it:** Retrieve the recovery key shares from your external store, then generate a new token:

    ```bash
    kubectl exec -i -n openbao openbao-0 -- bao operator generate-root -init   # prints a nonce + OTP
    kubectl exec -i -n openbao openbao-0 -- bao operator generate-root -nonce=<nonce> <key>   # once per key share
    kubectl exec -i -n openbao openbao-0 -- bao operator generate-root -decode=<encoded_token> -otp=<otp>
    ```

    If `-init`/`-status` itself returns `403 permission denied` with nothing explaining why in `kubectl logs -n openbao openbao-0`, and this is a fresh cluster with nothing of value stored in OpenBao yet, the fastest path is to wipe and reinitialize: `kubectl scale statefulset openbao -n openbao --replicas=0`, delete the `data-openbao-0` PVC, scale back to `1`, and re-run `just bootstrap`.

> [!CAUTION]
> Wiping and reinitializing OpenBao destroys everything stored in it. Keep that for an OpenBao that holds test data.

* **OpenBao throws a "permission denied" error**
  * **How to fix it:** Check the policies and roles applied from `terraform/openbao/`. `kubectl exec -n openbao openbao-0 -- bao policy read databases-policy` and `... bao policy read cert-manager-pki-policy` show the paths granted. `... bao read auth/kubernetes/role/databases-role` and `... bao read auth/kubernetes/role/cert-manager-pki-role` show the service accounts and namespaces they are bound to.

* **Secrets or certificates are failing to issue/mount into Kubernetes**
  * **How to fix it:** For a Secret the CSI driver fills, run `kubectl describe pod <name> -n <namespace>` on the pod that mounts it. Its events name the failed mount, usually the OpenBao login or the secret path. `kubectl logs daemonset/openbao-csi-provider -n openbao` shows the provider's side. For certificates, run `kubectl describe certificate <name> -n <namespace>` and check associated `CertificateRequest` objects (`kubectl get certificaterequest -A`). Status conditions report why cert-manager could not mint the resource.

* **Certificate issuance fails with a Name Constraint or permission error from OpenBao PKI**
  * **What's happening:** OpenBao's intermediate CA enforces RFC 5280 Name Constraints (`permitted_dns_domains`) and role-level domain allowlists (`allowed_domains` in `terraform/openbao/pki.tf`).
  * **How to fix it:** Check `kubectl describe certificaterequest -n <namespace>`. If OpenBao rejects the CSR, confirm the requested DNS name or IP SAN is explicitly listed in `permitted_dns_domains` and `allowed_domains` in `terraform/openbao/pki.tf`, and re-apply `tofu -chdir=terraform/openbao apply`. Confirm `openbao-pki-issuer` ClusterIssuer reports `Ready` (`kubectl describe clusterissuer openbao-pki-issuer`).

---

## Database Storage

* **Database pod fails to initialize**
  * **How to fix it:** Run `kubectl describe pod <pod_name> -n databases` and read the Events stream at the bottom. It reports scheduling failures, insufficient resources, and image pull failures.

* **Password authentication fails even though the password is correct**
  * **How to fix it:** Confirm both `enableSuperuserAccess: true` and `superuserSecret` are set in `apps/databases/cluster/databases-cluster.yaml`. Without `enableSuperuserAccess: true`, CNPG nulls the password on every reconciliation. Confirm the `username` field in Secret `postgres-superuser-credentials` is exactly `postgres`. CNPG rejects any other value before applying the password.

> [!IMPORTANT]
> Both failure modes are silent. CNPG nulls the password or rejects a bad `username` without an error or log line. Check both even when the Secret looks correct.

* **A role issued by OpenBao cannot create tables in a schema**
  * **What's happening:** The schema predates the `app_readwrite_new_schema` event trigger, which issues the `CREATE` grant.
  * **How to fix it:** `GRANT USAGE, CREATE ON SCHEMA <name> TO app_readwrite;`. Confirm the event trigger exists with `\dy`. Schemas created after it goes missing have the same problem.

> [!NOTE]
> `pg_read_all_data` and `pg_write_all_data` cover data access. DDL is separate. A role can read and write every table in a schema and still lack `CREATE` on it.

* **Tables created by a lease are unreadable by the next one**
  * **What's happening:** The lease was issued before `ALTER ROLE ... SET role = app_readwrite` was added to `creation_statements`. The lease's role owns its objects.
  * **How to fix it:** Update the role definition in `terraform/openbao/database.tf`, then `bao lease revoke -prefix database/creds/postgres-app-role`. Reassign what already exists as `postgres`: `REASSIGN OWNED BY "<lease-role>" TO app_readwrite;`, then drop the stale role.

> [!IMPORTANT]
> `DROP ROLE` at lease expiry fails with `cannot be dropped because some objects depend on it` until ownership is reassigned. OpenBao leaves the stale role behind on every expiry until then.

* **Application credentials stop working after a password rotation**
  * **What's happening:** Superuser credential refreshes reload automatically. `postgres-superuser-credentials` carries a permanent `cnpg.io/reload=true` label, written by the `opentofu` role's `tasks/secrets.yml`, and CNPG picks up the new Secret.
  * **How to fix it:** For the superuser password, update `database/config/postgres-cluster` in OpenBao (via `terraform/openbao/database.tf`). If a refresh stays unapplied, confirm the `cnpg.io/reload=true` label is present on the Secret (`kubectl get secret postgres-superuser-credentials -n databases --show-labels`) before assuming it needs to be reapplied by hand.

* **Database connections fail with a hostname mismatch when using `sslmode=verify-full`**
  * **What's happening:** The name used to connect is not in the certificate.
  * **How to fix it:** Check `dnsNames` and `ipAddresses` in `apps/databases/security/databases-tls.yaml`. The certificate covers `postgres-cluster-rw`, `-ro` and `-r` in short and fully qualified forms, `localhost`, `127.0.0.1`, `databases.cluster.internal` and the shared Gateway's LAN IP. When you add a name there, cert-manager reissues the certificate through `postgres-ca-issuer`.

* **Barman Cloud Plugin backups start failing**
  * **What's happening:** The database cannot reach or authenticate to the object store, or S3 TLS handshake fails.
  * **How to fix it:** Run `kubectl cnpg status postgres-cluster -n databases` and read the plugin's status block. Confirm the `plugin-barman-cloud` Deployment in `cnpg-system` is running (`kubectl rollout status deployment -n cnpg-system plugin-barman-cloud`). Confirm SeaweedFS S3 is serving TLS (`https://seaweedfs-s3.seaweedfs.svc:9000`) with a valid certificate from `openbao-pki-issuer`. Confirm the `barman-s3-credentials` pod in `databases` is running and Secret `barman-s3-credentials` holds `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`. `kubectl describe pod -l app.kubernetes.io/name=barman-s3-credentials -n databases` shows a failed mount in its events. Confirm the bucket exists:

    ```bash
    kubectl exec -n seaweedfs seaweedfs-master-0 -- sh -c 'echo "fs.ls /buckets" | weed shell -master=localhost:9333'
    # cnpg-backups
    ```

    If it is missing, re-reconcile `apps/seaweedfs/seaweedfs-release.yaml` (`flux reconcile helmrelease seaweedfs -n seaweedfs`). `createBuckets` in that chart's values creates it at install.

> [!CAUTION]
> Each key pair stops working when its 4-day lease ends or its issuing OpenBao token expires, whichever happens first. A Running holder pod and a healthy CNPG Cluster do not prove that WAL archiving is working.

* **Retention fails with `InvalidAccessKeyId` about 10 minutes after startup**
  * **What's happening:** The CSI login token expired and OpenBao revoked its S3 lease, deleting the key from SeaweedFS. A 4-day S3 lease cannot outlive its issuing token. The same deleted key also blocks WAL uploads. Correlate `kubectl logs -n openbao openbao-0` with the `plugin-barman-cloud` container in the primary database pod: token and `seaweedfs/creds/barman` revocations precede failed `ListObjectsV2` and `PutObject` calls.
  * **How to fix it:** Apply the CSI auth-role TTLs in `terraform/openbao/kubernetes-auth.tf` and the provider's `-cache-size=0` setting in `infrastructure/openbao/openbao-values.yaml`. Both CSI roles use 4-day login tokens, and each daily rotation authenticates afresh so a new credential cannot inherit a nearly expired token. Existing tokens and deleted keys are not repaired by changing a role: after applying the changes and waiting for the CSI provider rollout, refresh Barman's holder mount:

    ```bash
    kubectl rollout restart deployment/barman-s3-credentials -n databases
    kubectl rollout status deployment/barman-s3-credentials -n databases
    kubectl logs -n databases postgres-cluster-1 -c plugin-barman-cloud --since=10m
    kubectl cnpg psql postgres-cluster -n databases -- postgres -c \
      'SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_time FROM pg_stat_archiver;'
    ```

    Use the current primary's pod name if it differs from `postgres-cluster-1`. Confirm successful WAL uploads resume and `last_archived_time` advances. The historical `failed_count` keeps its value after recovery. Retention retries automatically every five minutes. Check its next cycle for a new `RetentionPolicyFailed` event or authentication error. A revoked key stays revoked when the retention window changes.
