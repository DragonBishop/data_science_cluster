# First-Time Setup Instructions

These detailed instructions are the product of repeated experimentation with cluster design, shell scripting, and best practices for cluster security. This process was produced with the assistance of artificial intelligence.

This setup workflow is designed to be completed sequentially. Deviating from this order may result in initialization failures.

## Prerequisites

**Host tooling:** All tools available as open source software, recommend install in runtime environment for the cluster: Flux CLI, OpenTofu, `postgresql-client`, and GitHub access to the repo, and for `flux bootstrap`.

```bash
sudo apt install -y postgresql-client-common postgresql-client
curl -s https://fluxcd.io/install.sh | sudo bash
flux check --pre
gh auth status

curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh
sudo ./install-opentofu.sh --install-method standalone
rm install-opentofu.sh
tofu version
```

**Host firewall (`ufw`):** If `ufw` is active, its default-deny `INPUT`/`FORWARD` policies block Cilium outright, no CNI misconfiguration involved, the packets are just dropped by the host firewall before Cilium ever sees them. This surfaces later as pod-to-host timeouts, or Hubble Relay's startup probe failing with `NOT_SERVING`, which looks like a Cilium/TLS problem but isn't. Fix this now rather than debugging Cilium later:

```bash
sudo ufw allow in on cilium_host
sudo ufw allow in on cilium_net
sudo ufw allow in on cilium_vxlan
sudo ufw allow in on lxc+
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw reload
```

These interfaces don't exist yet at this point in the install; the rules sit inactive until Cilium creates them in Step 3. `ufw`'s SSH/host-perimeter rules are untouched, this only opens traffic on Cilium's own virtual interfaces.

**Check:**

```bash
sudo ufw status verbose
# Default: ... allow (routed)
# cilium_host, cilium_net, cilium_vxlan, lxc+ all ALLOW IN
```

---

## 1. Clone repo and install k3s

* **Clone the repo to your remote branch:**

```bash
git clone https://github.com/DragonBishop/data_science_cluster.git
cd data_science_cluster
```

* **Confirm the network-specific values fit this rollout.**

*Reinstalling on a host that already has k3s installed? See the appendix first.*

The IP and DNS structure for this cluster assumes generic IP routing on a Linux OS. These are the only files that hardcode network values:

| File | Hardcoded |
| --- | --- |
| `infrastructure/cilium/gateway-lb-pool.yaml` | `192.0.2.240` — shared Gateway's LAN IP |
| `infrastructure/cilium/dns-lb-pool.yaml` | `192.168.1.241` — DNS resolver's LAN IP |
| `infrastructure/dns/dns-release.yaml` | Both of the above, plus `192.168.1.1` (LAN router, used as the upstream DNS forwarder) |
| `apps/databases/postgres-tls.yaml` | `192.0.2.240` again, as a cert SAN |

Confirm your router's DHCP scope excludes whatever addresses you pick:

```bash
ping -c 2 -W 1 192.0.2.240
ping -c 2 -W 1 192.168.1.241
```

No response means the address is likely free, not that the router will never hand it out. DHCP exclusion is what guarantees that.

**Install k3s.** Cilium replaces kube-proxy, Traefik, servicelb, and the default CNI, so the flags below disable all of them at install time:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable traefik --disable servicelb --disable-kube-proxy --disable-network-policy --flannel-backend=none" sh -

mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
kubectl get nodes
```

* **Check:** node shows up, status `NotReady`. Don't panic! This is expected because until Cilium is operational, there is no CNI for the container.

---

## 2. Deploy the Host-Level Transit Vault

This Vault instance runs directly on the host and unseals the cluster's Main Vault.

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update && sudo apt install -y vault
```

Generate the TLS certificate the in-cluster Vault verifies:

```bash
sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout /opt/vault/tls/tls.key \
  -out /opt/vault/tls/tls.crt \
  -subj "/CN=vault.local" \
  -addext "subjectAltName=DNS:vault.local,DNS:localhost,IP:127.0.0.1"
sudo chown vault:vault /opt/vault/tls/tls.key /opt/vault/tls/tls.crt
sudo chmod 640 /opt/vault/tls/tls.key
sudo chmod 644 /opt/vault/tls/tls.crt
sudo chmod o+x /opt/vault/tls
```

The certificate carries `vault.local` rather than the host's IP. Add `127.0.0.1 vault.local` to `/etc/hosts`. The in-cluster Main Vault connects to Transit by IP. `vault-values.yaml`'s seal `address`, substituted from the Downward API at every pod start, verifies the certificate against the `vault.local` name through `tls_server_name`, so an IP change requires no cert or config update.

Modify `/etc/vault.d/vault.hcl`. Bind the listener to `0.0.0.0:8200` so the cluster can reach it, and define `api_addr`:

```hcl
api_addr = "https://vault.local:8200"

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/opt/vault/tls/tls.crt"
  tls_key_file  = "/opt/vault/tls/tls.key"
}
```

Enable the service, initialize Vault, and configure the transit secrets engine:

```bash
sudo systemctl enable --now vault

export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"
vault operator init
```

CRITICAL: Store the generated 5 Unseal Keys and 1 Initial Root Token in a secure password manager immediately. If lost, data is irrecoverable.

Unseal the Transit Vault by providing three different unseal keys:

`vault operator unseal`

Then use the initial root token given to you by the vault to login:

`vault login`

Configure the auto-unseal policy and generate the authentication token:

```bash
vault secrets enable transit
vault write -f transit/keys/autounseal

vault policy write autounseal-policy - <<EOF
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
EOF

vault token create -policy=autounseal-policy -period=768h -orphan
```

Store this token. The in-cluster Vault's transit seal client renews it on use (`disable_renewal` defaults to `"false"`). The 768h period is 32 days, so it expires only if the cluster stays down longer than that; reissue with the same command and update `vault-transit-secret` if it does.

**Automating future unseals (one-time setup):**

The Transit Vault re-seals on every host reboot, which would otherwise mean re-running the three `vault operator unseal` calls by hand each time. `src/bash/start-cluster.sh` decrypts the three keys from a GPG-encrypted keyfile behind a single passphrase.

Generate the keyfile once, from a RAM-backed tmpfs so the plaintext keys never touch disk:

```bash
mkdir -p /dev/shm/vault-setup && cd /dev/shm/vault-setup

# There's a few ways to paste the same 3 keys used above into keys.txt
# But Nano allows double checking your work:
sudo nano keys.txt

gpg --batch --yes --cipher-algo AES256 --symmetric keys.txt
mv keys.txt.gpg ~/.vault-keys.gpg
chmod 600 ~/.vault-keys.gpg
cd / && rm -rf /dev/shm/vault-setup
```

Set the GPG passphrase cache to expire immediately, so it does not persist past the unseal:

```bash
cat >> ~/.gnupg/gpg-agent.conf <<'EOF'
default-cache-ttl 0
max-cache-ttl 0
EOF
gpgconf --reload gpg-agent
```

From this point on, `src/bash/start-cluster.sh` checks whether the Transit Vault is sealed and prompts for this passphrase when it is.

## 3. Cilium

The Gateway API Controller Resource Definitions (CRDs) must be installed before Cilium. Carefully review the compatibility of both resources before deploying. A mismatch leaves the GatewayClass in an `ACCEPTED: Unknown` state rather than reporting an error. This deployment uses the standard (GA) release channel. Use Flux to roll out upgrades to Cilium once the cluster is fully assembled.

```bash
kubectl apply --server-side -f infrastructure/gateway-api-crds/standard-install.yaml
```

`--server-side` records field ownership under a named manager, so Flux can reconcile these CRDs later without a conflict.

```bash
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium --version 1.20.0 \
  --namespace kube-system --create-namespace \
  -f infrastructure/cilium/cilium-values.yaml \
  --atomic --timeout 5m
```

`--atomic` rolls the release back automatically if it fails to become ready within the timeout.

**Check:**

```bash
kubectl get nodes                          # Ready
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
# KubeProxyReplacement: True

kubectl -n kube-system get cm cilium-config -o yaml | grep enable-l2-announcements
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -A2 l2-responder
# enable-l2-announcements: "true", l2-responder [OK] Running
```

---

## 4. Bootstrap Flux

```bash
flux bootstrap github \
  --owner=DragonBishop \
  --repository=data_science_cluster \
  --branch=main \
  --path=clusters/local \
  --personal
```

This writes `clusters/local/flux-system/` and pushes its own commit. Every other `Kustomization` under `clusters/local/` already exists in the repo, so once Flux's first sync completes it starts walking the full dependency graph:

```text
cilium ← cert-manager ← gateway ← hubble
       ← dns
vault ← vault-secrets-operator ← cnpg-operator ← barman-cloud ← seaweedfs
                                  (cnpg-operator also needs cert-manager
                                   via barman-cloud's own dependsOn)
                                  ← databases (also needs gateway, for
                                    its TCPRoute to attach to)
```

**Check:**

```bash
flux get kustomizations
kubectl get pods -n flux-system   # all Running
kubectl get ns
# vault, vault-secrets-operator-system, cnpg-system, databases,
# cert-manager, gateway, dns
```

---

## 5. Deploy k3s Hashicorp Vault

**What `vault-values.yaml` references**, before Flux reconciles Vault's `Kustomization`. These commands talk to the **host** Transit Vault, so `VAULT_ADDR`/`VAULT_CACERT` must point at it, not the in-cluster one:

```bash
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="/opt/vault/tls/tls.crt"
vault status   # Sealed: true means unseal it first
```

If sealed, decrypt three of the five Shamir keys from the GPG keyfile (the same mechanism `src/bash/start-cluster.sh` uses). This needs your GPG passphrase at an interactive `pinentry` prompt. Run it in your own terminal:

```bash
gpg --quiet --decrypt "$HOME/.vault-keys.gpg" | while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\n' "$key" | vault write sys/unseal key=-
done
vault status   # expect Sealed: false
```

Capture the token into a variable and check it succeeded before creating the Secret. Piping the two commands together can hide a failed token creation and silently create a Secret with an empty token.

```bash
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

TOKEN=$(vault token create -policy=autounseal-policy -period=768h -orphan -field=token) || exit 1
kubectl create secret generic vault-transit-secret --from-file=token=/dev/stdin -n vault <<< "$TOKEN"
unset TOKEN

kubectl create configmap vault-transit-ca \
  --from-file=ca.crt=/opt/vault/tls/tls.crt -n vault
```

**Reconcile Vault:**

```bash
flux reconcile kustomization vault
kubectl get pods -n vault -w
```

**Check:** `vault-0` reaches `Running` on the first attempt.

Initialize this instance. Because the seal is transit, this returns **recovery keys** and a **root token**, not unseal keys. Store both immediately:

```bash
kubectl exec -n vault vault-0 -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 vault operator init"
```

**Configure it completely:** KV secrets, the Kubernetes auth backend, policies via the OpenTofu module at `terraform/vault-bootstrap/`. Flux never reconciles this directory; state is local, gitignored, and encrypted at rest via OpenTofu's `encryption` block. Generate the state-encryption passphrase once and store it alongside the recovery keys.

Generate a passphrase using the bash terminal:

```bash
openssl rand -base64 32
```

Forward to a local port other than 8200. The host Transit Vault owns `0.0.0.0:8200` permanently, so `VAULT_ADDR=http://127.0.0.1:8200` here would land on the host Vault instead of the tunnel:

```bash
kubectl port-forward -n vault vault-0 8210:8200 &
export VAULT_ADDR=http://127.0.0.1:8210

read -rs -p "Vault root token (above): " VAULT_TOKEN; echo
read -rs -p "State encryption passphrase: " TF_VAR_state_encryption_passphrase; echo
export VAULT_TOKEN TF_VAR_state_encryption_passphrase

export TF_VAR_postgres_superuser_password=$(openssl rand -base64 24)
export TF_VAR_s3_access_key=$(openssl rand -hex 10)
export TF_VAR_s3_secret_key=$(openssl rand -hex 20)

cd terraform/vault-bootstrap
tofu init
tofu apply
cd ../..
```

Try to avoid passing secrets at any point in this project as plain-text. This bash script reads the secrets from the vault as environment variables, the ones it needs from the user it will prompt you for while hiding from the terminal.

`tofu apply` without `-auto-approve` pauses for an interactive `yes`. If that prompt scrolls out of view, check for a live `terraform-provider-vault` subprocess (`ps -ef | grep terraform-provider-vault`) before assuming it's hung. No such process, plus the parent `tofu` idling in `futex_do_wait`, means it's waiting on your `yes`.

**Check before unsetting anything:**

```bash
vault kv get secret/postgis
vault kv get secret/seaweedfs
head -c 200 terraform/vault-bootstrap/terraform.tfstate
```

The first two return what you just wrote. The third should be opaque/binary. Readable plaintext means the `encryption` block isn't taking effect; stop and report back.

```bash
unset VAULT_TOKEN TF_VAR_state_encryption_passphrase TF_VAR_postgres_superuser_password TF_VAR_s3_access_key TF_VAR_s3_secret_key
```

**Vault is done:** fully initialized, fully configured, `secret/postgis` and `secret/seaweedfs` both populated.

---

## 6. Flux Kustomization Rollout

Thanks to flux's `dependsOn` feature, we can roll out the bulk of the cluster in one fell swoop:

```bash
flux reconcile kustomization flux-system --with-source
```

**Check:**

```bash
flux get kustomizations
# everything Ready, `hubble`  depends on `cert-manager` and `gateway`,
# so it may finish a little after the rest of this wave. If it's
# still Reconciling, give it a minute and re-run.
```

```bash
helm list -n kube-system  

 # release "cilium" shows REVISION 2 adopted, not reinstalled. A brand-new
 # release instead means releaseName/namespace didn't match and two Cilium
 # installs are fighting over the same CNI. Uninstall cilium completely, then
 # reinstall fresh.

kubectl get ciliumloadbalancerippool
# gateway-lb-pool and dns-lb-pool both show 0 IPs available. Each pool's
# one address is already claimed by its Service.

kubectl get gateway -n gateway internal-gateway -o wide
# ADDRESS matches Phase 1, PROGRAMMED True

kubectl get svc -n dns
# EXTERNAL-IP matches Phase 1, not <pending>

dig +short @192.168.1.241 google.com          # forwards correctly
dig +short @192.168.1.241 hubble.internal      # answers with the Gateway IP

kubectl wait --for=condition=Available --timeout=120s -n cert-manager deployment --all

kubectl get clusterissuer gateway-ca-issuer   # Ready

kubectl rollout status deployment -n cnpg-system plugin-barman-cloud

kubectl get svc,pods -n databases -l app.kubernetes.io/instance=seaweedfs --show-labels
```

**Confirm the SeaweedFS Service name and pod labels against the real output** before trusting `apps/databases/postgis-cluster.yaml`'s `ObjectStore.endpointURL` or `apps/seaweedfs/seaweedfs-networkpolicy.yaml`. Both assume `seaweedfs-s3` and `app.kubernetes.io/name: seaweedfs`, per the chart's naming convention. If either differs, edit the relevant file.

```bash
kubectl cnpg status postgis-cluster -n databases
```

The Cluster should be healthy, `1/1` ready, with WAL archiving working on the first attempt.

```bash
kubectl get clusterissuer hubble-ca-issuer   # Ready

helm get values cilium -n kube-system   # hubble: block present
kubectl get pods -n kube-system -l 'k8s-app in (hubble-relay,hubble-ui)'
# both Running, 1/1 and 2/2

kubectl get httproute -n kube-system hubble-ui -o jsonpath='{.status.parents[*].conditions[*].message}'
# "Accepted" and "Service reference is valid"
```

If the Hubble block hasn't shown up in `helm get values` yet, the watch can take a few seconds to catch the new ConfigMap. Force it rather than wait:

```bash
flux reconcile helmrelease cilium -n kube-system --timeout 5m
```

This does not restart the Cilium agent DaemonSet. only Relay/UI get created and Hubble's certs issued via cert-manager. If this instead reports `RetriesExceeded`/`Stalled` and returns immediately, a plain reconcile won't retry it, see `troubleshooting.md`.

**Direct CLI/UI access, independent of DNS:** `just hubble-ui` port-forwards straight to `localhost:12000` and opens a browser, useful before `hubble.internal` resolves anywhere. `just hubble status` / `just hubble observe --follow` talk to Relay directly over its mTLS port (4245), separate from the HTTPRoute above: the Gateway carries the web UI's HTTP(S) traffic, not Relay's own gRPC port. See the `justfile`.

---

## 7. Deploy CloudNativePostgreSQL database server with postGIS extension

The Cluster came up as part of Phase 5. This phase is verification and, where applicable, the dump restore.

**Check, in order. Stop and debug on failures:**

```bash
kubectl cnpg status postgis-cluster -n databases
# Cluster in healthy state, 1/1 ready, WAL archiving OK

kubectl get database -n databases
# postgis-cluster/data-science, status.applied: true

kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d data_science -c '\dx'
# postgis, postgis_topology, postgis_tiger_geocoder, fuzzystrmatch

kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d postgres -c \
  "SELECT datname, pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='data_science';"
# owner is app_readwrite, not postgres

kubectl get tcproute -n databases postgis-external -o jsonpath='{.status.parents[*].conditions[*].message}'
# "Service reference is valid"
```

A valid `TCPRoute` reference confirms Kubernetes-level wiring, not LAN reachability, which needs an actual connection test using Phase 7's lease credentials:

```bash
LEASE_USER=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
LEASE_PASS=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
mkdir -p ~/.postgresql
kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt
PGPASSWORD="$LEASE_PASS" psql \
  "host=192.0.2.240 port=5432 dbname=data_science user=$LEASE_USER sslmode=verify-full" \
  -c 'SELECT current_user, session_user;'
unset LEASE_USER LEASE_PASS
```

If ARP doesn't resolve (`no route to host`, or `arping 192.0.2.240` from another LAN device gets nothing back), the likely cause on a consumer/office router is ARP or DHCP-snooping filtering unsolicited replies from an IP it never leased, not a Cilium misconfiguration.

**If you have a backup to restore** see the Appendix for more information; skip if starting empty):

```bash
kubectl exec -i postgis-cluster-1 -n databases -- pg_restore -U postgres -d data_science --no-owner --no-privileges \
  < /mnt/your/mount/path/data_science_backup_*.dump
```

`--no-owner --no-privileges`: the dump's objects were owned by `postgres` in the old cluster; here they should be owned by `app_readwrite`, per the existing grant/ownership model.

**Check:**

```bash
kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d data_science -c '\dn'
# gda_capstone_a_raw, google_data_analytics, public, statistics_with_python, tiger, topology
```

---

## 8. OpenTofu Role Configuration

`vault_database_secret_backend_connection` defaults `verify_connection = true`, so OpenTofu opens a connection to `postgis-cluster-rw.databases.svc.cluster.local:5432` at apply time. Which only resolves once Phase 6's Cluster is Ready. Module at `terraform/vault-database/`, with its own `.tfstate` and encryption:

```bash
kubectl port-forward -n vault vault-0 8210:8200 &
export VAULT_ADDR=http://127.0.0.1:8210

read -rs -p "Vault root token (Phase 4): " VAULT_TOKEN; echo
read -rs -p "State encryption passphrase: " TF_VAR_state_encryption_passphrase; echo
export VAULT_TOKEN TF_VAR_state_encryption_passphrase
export TF_VAR_postgres_superuser_password=$(VAULT_TOKEN="$VAULT_TOKEN" vault kv get -field=password secret/postgis)

cd terraform/vault-database
tofu init
tofu apply
cd ../..
```

`postgres_superuser_password` must be the exact value Phase 4 wrote into `secret/postgis`. Read it back from Vault rather than retype it.

```bash
unset VAULT_TOKEN TF_VAR_state_encryption_passphrase TF_VAR_postgres_superuser_password
```

**Check:**

```bash
head -c 200 terraform/vault-database/terraform.tfstate   # opaque/binary

kubectl get vaultdynamicsecret postgis-app-dynamic-secret -n databases
kubectl exec -i postgis-cluster-1 -n databases -- psql -U postgres -d postgres -c '\du'
# the issued role shows Member of: app_readwrite

LEASE_USER=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
LEASE_PASS=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
PGPASSWORD="$LEASE_PASS" psql \
  "host=192.0.2.240 port=5432 dbname=data_science user=$LEASE_USER sslmode=verify-full" \
  -c 'SELECT current_user, session_user;'
unset LEASE_USER LEASE_PASS
```

Run this from the host, not `kubectl exec` as the `postgres` OS user inside the container has no `~/.postgresql/root.crt`, so `verify-full` fails there with a misleading "root certificate file ... does not exist" error.

---

## 9. Full end-to-end verification

```bash
kubectl cnpg status postgis-cluster -n databases        # healthy, WAL archiving OK
kubectl get scheduledbackup -n databases                 # suspend: false
kubectl cnpg backup postgis-cluster -n databases          # take one manually
kubectl cnpg status postgis-cluster -n databases          # Last Successful Backup updates
flux get kustomizations                                   # everything Ready
```

Rehearse a restore once, per the README's restore section. A restore path untested on the new build is unverified.

```bash
dig +short @192.168.1.241 hubble.internal      # 192.0.2.240
dig +short @192.168.1.241 postgres.internal    # 192.0.2.240
```

Hubble UI needs either a device pointed at `192.168.1.241` as its DNS server, or `curl --resolve hubble.internal:443:192.0.2.240 https://hubble.internal/ -k` as a no-DNS-config workaround (ignoring cert trust for this one-off check). A resolving hostname and valid Route backend are necessary but not sufficient. Confirm the page loads.
