# Troubleshooting Guide

Diagnostic procedures and remediation steps for issues across Ansible bootstrap, cluster lifecycle, networking, GitOps controllers, secrets management, and database storage.

## Table of Contents

* [Ansible Provisioning](#ansible-provisioning)
* [Cluster Lifecycle](#cluster-lifecycle)
* [Networking](#networking)
* [GitOps](#gitops)
* [Vault Secrets](#vault-secrets)
* [Database Storage](#database-storage)

---

## Ansible Provisioning

* **Ansible playbook fails with missing collection errors**
  * **What's happening:** The required Ansible Galaxy collections (`kubernetes.core`, `community.general`) are missing from the host environment.
  * **How to fix it:** Install Galaxy dependencies declared in the repository:

    ```bash
    ansible-galaxy collection install -r ansible/requirements.yml
    ```

* **Playbook fails during k3s installation or times out waiting for `/etc/rancher/k3s/k3s.yaml`**
  * **What's happening:** Leftover state, containerd shims, or stale Cilium BPF mounts from a previous installation are preventing the k3s server from initializing cleanly.
  * **How to fix it:** Run `/usr/local/bin/k3s-uninstall.sh`, unmount any lingering BPF filesystems (`mount | grep bpf`), and re-run `just bootstrap`.

* **Playbook fails during Flux bootstrap with GitHub authentication errors**
  * **What's happening:** `gh` CLI is either unauthenticated or lacks the required OAuth scopes to manage repository webhooks and deploy keys.
  * **How to fix it:** Run `gh auth login` and select `GitHub.com`, `HTTPS`, and authenticate with your browser or a personal access token with repo privileges. Verify with `gh auth status`.

* **OpenTofu role fails to apply Vault configuration**
  * **What's happening:** Vault is sealed, port-forwarding failed, or OpenTofu state encryption passphrase was mistyped.
  * **How to fix it:** Verify the `vault-0` pod is Running and unsealed (`kubectl exec -n vault vault-0 -- vault status`). Run OpenTofu manually to inspect verbose output:

    ```bash
    tofu -chdir=terraform/vault init
    tofu -chdir=terraform/vault plan
    ```

---

## Cluster Lifecycle

* **`start-cluster.sh` refuses to start**
  * **What's happening:** The system's background k3s service (`k3s.service`) is already active. Running two k3s instances against the same data directory will corrupt your cluster.
  * **How to fix it:** Hand lifecycle management over to the scripts. Run `sudo systemctl disable --now k3s`. `systemctl is-enabled k3s` confirms which supervisor owns it.

> [!NOTE]
> `stop-cluster.sh` disables the background `k3s.service` automatically the first time it finds it — you only need the manual command above once.

* **`stop-cluster.sh` halts before k3s actually stops**
  * **What's happening:** The script requires the database to hibernate before shutting down the cluster. If k3s stops while PostgreSQL is running, the database is killed ungracefully.
  * **How to fix it:** Read the halt message to see what is holding up the process. To shut down immediately and accept a crash recovery on the next boot, use the `--force` flag.

> [!CAUTION]
> `--force` skips the graceful hibernation wait and kills PostgreSQL mid-shutdown — only use it when you're prepared for crash recovery on the next start.

* **Hibernation shows as "not confirmed" when stopping**
  * **What's happening:** The script could not verify that the database shut down cleanly.
  * **How to check if it actually failed:** On the next start, run `kubectl logs -n databases postgis-cluster-1 -c postgres | grep -i "cluster state"`. `Database cluster state: shut down` with a timestamp means the shutdown was clean and the script did not wait long enough to observe it.
  * **If it genuinely failed, it's usually one of three things:**
    1. **Idle database connections:** `spec.smartShutdownTimeout` in `postgis-cluster.yaml` is set to 15 (the CNPG default is 180). Postgres waits that long for existing connections to close before escalating to a fast shutdown, which disconnects them. Check for active connections before stopping: `kubectl exec -n databases postgis-cluster-1 -c postgres -- psql -U postgres -c "select pid, usename, application_name, state from pg_stat_activity where backend_type='client backend';"`
    2. **CloudNativePG (CNPG) operator isn't available:** The shutdown command was sent, but the operator was not running to process it. The stop script usually catches this first and halts with a specific warning.
    3. **The cluster isn't healthy:** A cluster will not hibernate from a broken state, such as a pod in CrashLoop or mid-boot. Check with `kubectl cnpg status postgis-cluster -n databases`.

* **Port 6443 is still bound/in-use after running `stop-cluster.sh`**
  * **What's happening:** The API server stopped, but containerd shims are still running.
  * **How to fix it:** Run `sudo k3s-killall.sh` manually; it cleans up leftover processes and unmounts directories.

---

## Networking

* **Pods are stuck in `ContainerCreating` indefinitely**
  * **What's happening:** Cilium may still be initializing. Without the CNI, the container sandbox cannot be created.
  * **How to fix it:** Run `cilium status --wait`. If it persists after Cilium is running, check that the BPF filesystem is mounted (`mount | grep bpf`); a hard shutdown can leave it unmounted.

> [!CAUTION]
> `/var/run/cilium/cgroupv2` is an active mount — unmount it before running `rm -rf /var/run/cilium`, or the `rm -rf` will fail partway through or tear into a live mount.

* **Pods are running but completely unreachable (Stale Cilium Endpoints)**
  * **What's happening:** After a forced stop or an agent restart, pods can retain endpoints that no longer route.
  * **How to fix it:** Run `kubectl exec -n kube-system ds/cilium -- cilium endpoint list` to view active endpoints. Delete the affected pods (`kubectl delete pod <pod_name>`); the controller recreates them with new network identities.

* **Hubble Relay never becomes Ready (`Startup probe failed: service unhealthy, responded with "NOT_SERVING"`)**
  * **What's happening:** Hubble Relay is a pod, but it reaches cilium-agent's Hubble gRPC port on the **host's own IP** (cilium-agent runs `hostNetwork: true`), so that connection is pod→host traffic, not pod→pod. If `ufw` (Ubuntu/Debian) or `firewalld` (Fedora/RHEL) is active without the required forward/port rules from `INSTALLATION.md`'s Requirements, the host firewall drops it silently and Relay times out.
  * **How to fix it:** Confirm it's actually this: `sudo iptables -L INPUT -n -v | head` a large, growing packet count against the final `DROP` policy confirms it. Apply the `ufw` (Ubuntu/Debian) or `firewalld` (Fedora/RHEL) rules in `INSTALLATION.md`'s Requirements.

> [!IMPORTANT]
> A firewall fix alone does not retry an already-failed HelmRelease — see the `RetriesExceeded` / `Stalled` entry below to clear the retry lock afterward.

* **Gateway routing or TLS fails (`*.internal` domain unreachable)**
  * **What's happening:** The client cannot resolve the domain or route traffic to the Gateway IP.
  * **How to fix it:** Run `just gateway-check` to verify listener routing and TLS termination. Confirm CoreDNS custom zone is responding (`dig @192.0.2.242 hubble.internal`) and verify that Gateway listeners are programmed (`kubectl get gateway -n gateway internal-gateway`).

* **A `CiliumNetworkPolicy`/`CiliumClusterwideNetworkPolicy` `toPorts` rule doesn't allow traffic it should cover**
  * **What's happening:** Cilium enforces `toPorts` against the destination pod's actual container port, not a Service's externally-exposed `port`. Traffic to a `ClusterIP` gets DNAT'd to its backend port at the client's socket level before a packet exists on the wire, so a request to `some-service:80` is policy-checked as traffic to the pod's real listening port (e.g. `:9090`), not `:80`.
  * **How to fix it:** Check the Service's `spec.ports[].targetPort` (or the pod's own named container port) rather than assuming the Service's `port:` value is what to write into the policy. `kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop -v` shows the real post-DNAT destination port in any `Policy denied` line while reproducing the failing request.

> [!IMPORTANT]
> Write `toPorts` against the pod's real listening port, not the Service's externally-exposed `port:` — Cilium enforces policy after the DNAT rewrite, at the client's socket level.

---

## GitOps

* **`flux reconcile helmrelease cilium` reports `RetriesExceeded` / `Stalled` and does nothing**
  * **What's happening:** After enough failed upgrade attempts (e.g. from the Hubble issue above), `helm-controller` hits its retry budget and marks the release `Stalled` with a **terminal** error. A plain reconcile re-checks that same exhausted state and fails instantly; it does not attempt a new upgrade.
  * **How to fix it:** Clear the retry lock first, then it reconciles normally:

    ```bash
    flux suspend helmrelease cilium -n kube-system
    flux resume helmrelease cilium -n kube-system
    ```

    `flux get helmrelease cilium -n kube-system` should show `Ready: True` after.

> [!NOTE]
> If the underlying cause isn't actually fixed yet, this just produces a fresh failed attempt instead of a stuck one; check `helm history cilium -n kube-system` and pod events for the real error.

* **Flux Kustomization reports `DependencyNotReady`**
  * **What's happening:** A Kustomization's `dependsOn` prerequisite is failing its health checks or still reconciling.
  * **How to fix it:** Check the dependency state with `flux get kustomizations -A` and trace the unready upstream Kustomization with `flux describe kustomization <name> -n flux-system`.

* **A `HelmChart`/`GitRepository` reconcile hangs on `dial tcp ...: i/o timeout` fetching from an external host**
  * **What's happening:** `flux-egress` (`infrastructure/flux-system-policies/flux-networkpolicy.yaml`) only allows `source-controller` to reach an explicit FQDN allowlist. A new external Helm/OCI chart source — or even an existing one, if its CDN backend changes — means source-controller is reaching a host that isn't on that list, and Cilium silently drops the connection instead of returning an error. The FQDN that actually needs allowing is often not the chart repo's own domain: `oci://quay.io/...` charts can redirect blob downloads through `cdnNN.quay.io`, and GitHub Pages chart indexes (`*.github.io`) serve release assets from `release-assets.githubusercontent.com`.
  * **How to fix it:** Confirm it's this with `kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop -v` while forcing a reconcile (`flux reconcile source chart <name> -n <namespace>`) — a `Policy denied` line naming `identity ...->world` confirms it. Add the missing FQDN (`matchName`) or a wildcard (`matchPattern: "*.example.com"`) to `flux-egress`, commit and push it (see the next entry), then reconcile.

* **A `kubectl apply`/patch to a Flux-managed resource works, then silently reverts a few minutes later**
  * **What's happening:** Most Kustomizations in this repo have `prune: true`. Flux treats git as the sole source of truth for anything it owns; a live edit fixes the running object but not the git-tracked manifest, so the next reconcile overwrites the fix back to whatever's committed.
  * **How to fix it:** Make the same edit in the source file, commit, and push before relying on it — `kubectl apply` alone is only a temporary patch for anything a Kustomization's `path:` covers.

> [!IMPORTANT]
> Commit and push the fix in the same breath as any live patch to a `prune: true` Kustomization — otherwise the next reconcile silently reverts it.

* **Headlamp shows a stale or failed connection**
  * **What's happening:** Headlamp reads `~/.kube/config`, which k3s rewrites directly (`--write-kubeconfig`) every time `start-cluster.sh` runs. A stale profile means the file predates the current cluster instance.
  * **How to fix it:** Run `start-cluster.sh` to regenerate `~/.kube/config`, then reconnect Headlamp.

---

## Vault Secrets

* **Vault reports as "sealed" when it isn't (or prompts for a GPG password on every run)**
  * **What's happening:** `vault status` returns `0` for unsealed, `2` for sealed, and another code if the command itself failed. Might be a dead pod. A check that greps the output for "false" treats a failed connection as sealed and goes looking for unseal keys.
  * **How to fix it:** Diagnose using the exit code rather than the text output:

    ```bash
    kubectl exec -n vault vault-0 -- vault status; echo "exit=$?"
    ```

    If Vault is re-sealing without a pod restart, check `kubectl get pods -n vault` for a crashing container.

* **GPG decryption fails**
  * **What's happening:** The script cannot read or decrypt the unseal keys.
  * **How to fix it:**
    1. Confirm `~/.vault-keys.gpg` exists and is mode `600` (`ls -l ~/.vault-keys.gpg`).
    2. Confirm the passphrase matches the one used to create the keyfile.

> [!NOTE]
> `vault operator unseal` does not accept piped input, so the script passes the key via `vault write sys/unseal key=-` instead. To exercise that mechanism without changing the seal state, run `printf 'SENTINEL\n' | kubectl exec -i -n vault vault-0 -- vault write -output-curl-string sys/unseal key=-` to get output containing `SENTINEL`.

* **The Vault root token was never captured and is now needed**
  * **What's happening:** `vault operator init` prints the root token exactly once; this repo's Ansible role prints it to the terminal at that moment (`vault : SAVE THIS NOW`) but nothing persists it to disk, by design.
  * **How to fix it:** If Vault has already been unsealed since, generate a new one from the unseal key shares instead of the lost token:

    ```bash
    gpg --quiet --decrypt ~/.vault-keys.gpg   # prints the 3 unseal key shares
    kubectl exec -i -n vault vault-0 -- vault operator generate-root -init   # prints a nonce + OTP
    kubectl exec -i -n vault vault-0 -- vault operator generate-root -nonce=<nonce> <key>   # once per key share
    kubectl exec -i -n vault vault-0 -- vault operator generate-root -decode=<encoded_token> -otp=<otp>
    ```

    If `-init`/`-status` itself returns `403 permission denied` with nothing explaining why in `kubectl logs -n vault vault-0` (seen once on this project's Vault image, cause never identified), and this is a fresh cluster with nothing of value stored in Vault yet, the fastest path is to wipe and reinitialize: `kubectl scale statefulset vault -n vault --replicas=0`, delete the `data-vault-0` PVC, scale back to `1`, and re-run `just bootstrap`.

> [!CAUTION]
> Never wipe and reinitialize Vault if it holds real secrets — it destroys everything stored in it.

* **Vault throws a "permission denied" error**
  * **How to fix it:** Check the policies and roles applied from `terraform/vault/`. `kubectl exec -n vault vault-0 -- vault policy read postgis-policy` and `... vault policy read cert-manager-pki-policy` show the paths granted; `... vault read auth/kubernetes/role/postgis-role` and `... vault read auth/kubernetes/role/cert-manager-pki-role` show the service accounts and namespaces they are bound to.

* **`vault kv get secret/postgis` or `secret/seaweedfs` returns "No value found at secret/data/..."**
  * **What's happening:** The `vault_kv_secret_v2` resources in `terraform/vault/kv.tf` that write this data have never been applied for this Vault instance.
  * **How to fix it:** Re-run `just bootstrap` (or `tofu -chdir=terraform/vault apply` directly with the usual `TF_VAR_*` exported). If the resources exist in config but values still don't appear after that, see the next entry.

* **A freshly-typed or corrected value (e.g. fixing a mistyped superuser password) doesn't reach Vault after re-running bootstrap**
  * **What's happening:** `postgres_superuser_password`, `s3_access_key`, and `s3_secret_key` all share one write-only version counter (`secrets_wo_version`). Terraform only pushes a new write-only value when its version changes; an ordinary rerun leaves the version unchanged by design, so a differing typed value is silently not written.
  * **How to fix it:** Re-run with `ROTATE_VAULT_SECRETS=true` to bump the version and force all three secrets to be rewritten (this also regenerates the S3 keys as a side effect).

> [!IMPORTANT]
> `ROTATE_VAULT_SECRETS=true` regenerates the S3 keys as a side effect of bumping the shared write-only version — don't set it just to fix one of the three secrets unless you're prepared for all three to rotate.

* **Secrets or certificates are failing to issue/mount into Kubernetes**
  * **How to fix it:** Run `kubectl describe vaultstaticsecret <name> -n databases` (or `vaultdynamicsecret` for dynamic credentials). For certificates, run `kubectl describe certificate <name> -n <namespace>` and check associated `CertificateRequest` objects (`kubectl get certificaterequest -A`). Status conditions report why VSO or cert-manager could not pull or mint the resource.

* **Certificate issuance fails with a Name Constraint or permission error from Vault PKI**
  * **What's happening:** Vault's intermediate CA enforces RFC 5280 Name Constraints (`permitted_dns_domains`) and role-level domain allowlists (`allowed_domains` in `terraform/vault/pki.tf`).
  * **How to fix it:** Check `kubectl describe certificaterequest -n <namespace>`. If Vault rejects the CSR, confirm the requested DNS name or IP SAN is explicitly listed in `permitted_dns_domains` and `allowed_domains` in `terraform/vault/pki.tf`, and re-apply `tofu -chdir=terraform/vault apply`. Confirm `vault-pki-issuer` ClusterIssuer reports `Ready` (`kubectl describe clusterissuer vault-pki-issuer`).

* **Dynamic credentials never reach a "Ready" state**
  * **How to fix it:** `kubectl describe vaultdynamicsecret postgis-app-dynamic-secret -n databases` reports Vault's error.

---

## Database Storage

* **Database pod fails to initialize**
  * **How to fix it:** Run `kubectl describe pod <pod_name> -n databases` and read the Events stream at the bottom. It reports scheduling failures, insufficient resources, and image pull failures.

* **Password authentication fails even though the password is correct**
  * **How to fix it:** Confirm both `enableSuperuserAccess: true` and `superuserSecret` are set in `postgis-cluster.yaml`. With the first missing, CNPG nulls the password on every reconciliation. Confirm the `username` field in `secret/postgis` is exactly `postgres`; CNPG rejects any other value before applying the password.

> [!IMPORTANT]
> Both failure modes are silent — CNPG neither errors nor logs when it nulls the password or rejects a bad `username`, so check them even when the Secret otherwise looks correct.

* **A role issued by Vault cannot create tables in a schema**
  * **What's happening:** The schema predates the `app_readwrite_new_schema` event trigger, so no `CREATE` grant was issued on it.
  * **How to fix it:** `GRANT USAGE, CREATE ON SCHEMA <name> TO app_readwrite;`. Confirm the event trigger exists with `\dy`; without it, schemas created from now on have the same problem.

> [!NOTE]
> `pg_read_all_data` and `pg_write_all_data` cover data access only, not DDL — a role can read and write every table in a schema and still lack `CREATE` on it.

* **Tables created by a lease are unreadable by the next one**
  * **What's happening:** The lease was issued before `ALTER ROLE ... SET role = app_readwrite` was added to `creation_statements`, so it owns its objects.
  * **How to fix it:** Update the role definition in `terraform/vault/database.tf`, then `vault lease revoke -prefix database/creds/postgis-app-role`. Reassign what already exists as `postgres`: `REASSIGN OWNED BY "<lease-role>" TO app_readwrite;`, then drop the stale role.

> [!IMPORTANT]
> `DROP ROLE` at lease expiry fails with `cannot be dropped because some objects depend on it` until ownership is reassigned — Vault will keep leaving the stale role behind on every expiry until you fix this.

* **Application credentials stop working after a password rotation**
  * **What's happening:** App-role rotations (static or dynamic) reload automatically, as `postgis-app-credentials` and `postgis-app-dynamic-credentials` both carry a permanent `cnpg.io/reload=true` label in `postgis-cluster.yaml`, so CNPG picks up the new Secret on its own.
  * **How to fix it:** For the superuser password, update `database/config/postgis-cluster` in Vault (via `terraform/vault/database.tf`). For app-role credentials still not picking up a rotation, confirm the `cnpg.io/reload=true` label is actually present on the Secret (`kubectl get secret postgis-app-credentials -n databases --show-labels`) before assuming it needs to be reapplied by hand.

* **Database connections fail with a hostname mismatch when using `sslmode=verify-full`**
  * **What's happening:** The name used to connect is not in the certificate.
  * **How to fix it:** Check `dnsNames` and `ipAddresses` in `apps/databases/postgis-tls.yaml`. `postgis-cluster-rw`, `-ro`, and `-r` are covered in both short and fully-qualified forms, along with `localhost`, `127.0.0.1`, `postgis.internal`, and the shared Gateway's LAN IP. Adding a name there causes cert-manager to reissue the certificate via `vault-pki-issuer`. If the cluster or Vault PKI root was rebuilt, update your local `root.crt` from `kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt`.

> [!NOTE]
> Any new name added to `postgis-tls.yaml` must also be permitted in `terraform/vault/pki.tf` (`permitted_dns_domains` and `allowed_domains`), or Vault PKI rejects the CSR before cert-manager can reissue.

* **Barman Cloud Plugin backups start failing**
  * **What's happening:** The database cannot reach or authenticate to the object store, or S3 TLS handshake fails.
  * **How to fix it:** Run `kubectl cnpg status postgis-cluster -n databases` and read the plugin's status block. Confirm the `plugin-barman-cloud` Deployment in `cnpg-system` is running (`kubectl rollout status deployment -n cnpg-system plugin-barman-cloud`). Confirm SeaweedFS S3 is serving TLS (`https://seaweedfs-s3.databases.svc:9000`) with a valid certificate from `vault-pki-issuer`. Confirm the `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY` fields in the `seaweedfs-credentials` Secret match the credentials inside its `config` field. Confirm the bucket exists:

    ```bash
    kubectl exec -n databases seaweedfs-master-0 -- sh -c 'echo "fs.ls /buckets" | weed shell -master=localhost:9333'
    # cnpg-backups
    ```

    If it is missing, re-reconcile `apps/databases/seaweedfs-release.yaml` (`flux reconcile helmrelease seaweedfs -n databases`); `createBuckets` in that chart's values creates it at install.

> [!CAUTION]
> A mismatch between the Secret's `ACCESS_KEY_ID`/`ACCESS_SECRET_KEY` fields and its `config` field produces no error until an archive is actually attempted — a "healthy" cluster can still be silently failing every backup.
