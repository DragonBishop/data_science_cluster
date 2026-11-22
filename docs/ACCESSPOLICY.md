# Access Policy

## The Rules

1. Each caller's access matches its job.
2. Verify the expected identity before granting access or trusting a connection.
3. A grant names the resources and operations the caller may use. Cluster-wide access requires a cluster-wide job.
4. Deliver credentials privately to authorized consumers. Limit provisioning credentials to the operation that needs them.
5. Limit certificate signing to the required names, uses and lifetimes. Trust bundles hold public CA certificates. Private keys stay with their issuers.
6. Deliver usable replacement credentials before expiry. Distribute replacement CA trust before switching issuers.

This single-node cluster trusts its human administrator and the configured Flux, cert-manager and credential-delivery controllers. Workloads authenticate through their named identities. Receiving services enforce their permissions. [Network Policy](NETWORKPOLICY.md) governs connection reachability.

## Permissions

Access to namespaced Kubernetes resources uses a Role and RoleBinding in the resource's namespace. RBAC permissions add together: a narrow grant does not cancel access provided by another grant.

### Pipeline Access

A Pipeline's ServiceAccount reads cluster state through the built-in `view` ClusterRole, bound once cluster-wide. A Pipeline that changes something gets one Role in `tekton-pipelines` listing those changes. `core-test` has ClusterRoleBinding `core-test-view` and Role `core-test-role`, which creates and deletes probe pods and issues a token for `core-test`. A test that needs an application login gets that Role in the application's namespace. Role `core-test-role` in `databases` lets `core-test` issue a token for ServiceAccount `databases-openbao-auth`, so `client-login` can log in to OpenBao as the data-science client. ClusterRole `code-quality-view` grants ServiceAccount `code-quality` `get` on GitRepositories and `get` and `list` on CustomResourceDefinitions.

Tekton runs a PipelineRun as the named ServiceAccount without checking the creator's permissions. ValidatingAdmissionPolicy `run-serviceaccounts` ([`infrastructure/tekton/pipelines/tekton-pipelines-admission.yaml`](../infrastructure/tekton/pipelines/tekton-pipelines-admission.yaml)) restricts runs naming `core-test` or `code-quality` to `system:admin`, EventListener `el-flux-events` and the Tekton Pipelines controller.

Credentials travel in Secrets or CSI mounts. A Pipeline that can create pods in `tekton-pipelines` can mount that namespace's Secrets. `tekton-pipelines` holds only the Secrets its Pipelines use. Pipelines and Tasks come from `main` through Flux, and a run tests a branch's revision with them.

### PostgreSQL Administration

The `postgres` superuser password is supplied during bootstrap and managed in Secret `postgres-superuser-credentials`. OpenBao uses it to create temporary database users.

Workload logins use the stable `NOLOGIN` owner role `app_readwrite`. CNPG initializes the data-science database with default table and sequence privileges for it before installing PostGIS. OpenBao's temporary logins switch to this owner role by default, so objects they create keep a stable owner after the login expires.

Grafana's database `grafana` follows the same pattern with its own `NOLOGIN` owner role, `grafana_readwrite`, declared in [`apps/databases/cluster/databases-cluster.yaml`](../apps/databases/cluster/databases-cluster.yaml). Its logins come from OpenBao role `grafana-app-role` and switch to `grafana_readwrite`.

PostgreSQL requires TLS on every connection. The `hostnossl all all all reject` rule in `pg_hba` rejects any connection before a password check. Desktop clients need `sslmode=verify-full` and the `postgres-ca` certificate.

### Issuer Authentication

cert-manager authenticates `openbao-pki-issuer` to OpenBao using a short-lived Kubernetes token for ServiceAccount `cert-manager` in namespace `cert-manager`.

The issuer and its grant live together in [`infrastructure/openbao/server/openbao-issuers.yaml`](../infrastructure/openbao/server/openbao-issuers.yaml). The `cert-manager-tokenrequest` Role allows `create` on `serviceaccounts/token` for `resourceNames: [cert-manager]`, following [cert-manager's named-account authentication pattern](https://cert-manager.io/docs/configuration/vault/).

A token-request grant names the target ServiceAccount. A new issuer using another account needs a matching grant in its namespace. Kubernetes permissions also control who may create Certificate resources or edit issuers, and the signing profile sets what a certificate may contain.

Flux's `openbao-server` Kustomization applies the issuer manifest after cert-manager is available and prunes managed objects removed from that source. Ansible uses the same manifest during a fresh bootstrap.

## Provisioning Credentials

`just bootstrap` collects provisioning inputs through private prompts. The Ansible OpenTofu role supplies them to the apply process through environment variables, with task logging suppressed. OpenTofu uses OpenBao's root token to configure policies, authentication methods and secret engines. The state-encryption passphrase protects local OpenTofu state and plans.

The OpenTofu role verifies OpenBao's listener certificate using the public CA in ConfigMap `openbao-ca-bundle`, writing it to `.local/openbao/certs/openbao-internal-ca.crt` with owner-only permissions.

Ansible installs trust-manager and OpenBao's listener certificates and Bundle before OpenTofu and Flux. The listener CA is independent of the service PKI managed by OpenTofu.

OpenBao unseals itself with the `static` seal from Secret `openbao-seal-key`. Keep an external copy of that key, the recovery shares and the root token. Bootstrap generates a random key on a fresh installation, prints it at the end, and preserves an existing Secret. When the Secret is missing while storage exists, supply the original key through `openbao_seal_key` or `OPENBAO_SEAL_KEY`.

## Workload Credentials

| Consumer | Delivery | Lifetime and refresh |
| --- | --- | --- |
| CNPG Barman Cloud | OpenBao CSI provider, using the named Barman ServiceAccount and S3 role | Four-day S3 lease. The issuing token covers that lease. Daily refresh and reload |
| Data-science database clients | OpenBao's named database authentication role | Three-hour default database lease, up to 24 hours. The client refreshes before expiry |
| Grafana's database login | OpenBao CSI provider in the Grafana pod, as ServiceAccount `grafana` through `grafana-role` (`database/creds/grafana-app-role`) | Four-day database lease. The issuing token covers that lease. Its `credential-watch` sidecar restarts the pod's containers in place when the login changes |
| Grafana's admin login | The same CSI mount, from `secret/grafana/admin`, which OpenTofu generates and writes once | Static. Grafana stores it at first start; changing it goes through Grafana's account API |
| Zot S3 key pair and push htpasswd | OpenBao CSI provider, as ServiceAccount `zot` through `zot-role` (`seaweedfs/creds/zot` for the key pair and `secret/data/zot-push` for the htpasswd) | Four-day S3 lease. The issuing token covers that lease. A `credential-watch` sidecar restarts the pod when the S3 key pair rotates |
| Prometheus's OpenBao metrics scrape | OpenBao's metrics listener on 8204, restricted to Prometheus by policy `openbao`, serves `/v1/sys/metrics` over TLS. The metrics contain counts, timings, mount paths and policy names | Nothing to expire |

A CSI issuing token must cover its credential's lease. Keep `cache-size=0`, token lifetimes and child leases aligned.

OpenBao connects to `postgres-cluster-rw.databases.svc.cluster.local` with `sslmode=verify-full`, verifying the server's CA and hostname against the public `postgres-ca` Bundle mounted at `/openbao/userconfig/postgres-ca`. Provisioning registers the connection before PostgreSQL exists. Flux supplies the database and its CA before OpenBao issues credentials.

Keep secret values out of Git, task output, command arguments and reports. Secret-bearing Ansible tasks suppress their results.

## Certificate Trust

Trust a certificate that identifies the service or workload you expected, is valid for the connection, and verifies against the intended CA.

| Consumer | Trust source |
| --- | --- |
| OpenTofu, cert-manager and SPIRE connecting to OpenBao | `openbao-local-ca-secret`, distributed as `openbao-ca-bundle` |
| SeaweedFS S3 and Hubble clients | OpenBao's service-PKI root, distributed as `openbao-root-ca` or carried in their TLS Secret |
| Browsers and VS Code on the workstation (Gateway hostnames, Hubble UI, Tekton Dashboard), and `core-test`'s `gateway-tls` | The desktop CA, an intermediate: the workstation's trust anchor when the bootstrap's prompt is answered yes. In the cluster, `openbao-root-ca`, which it chains to |
| Browsers and VS Code on the workstation reaching OpenBao's UI | `openbao-local-ca`, installed beside the desktop CA by the same prompt |
| OpenBao and application clients verifying PostgreSQL, Prometheus scraping PostgreSQL's metrics, and PostgreSQL replication | Dedicated `postgres-ca` |
| PostgreSQL replication client certificates | `postgres-client-ca`, containing the PostgreSQL CA |
| Flux controller mTLS and workload identity consumers | SPIRE's workload API trust bundle |
| Prometheus scraping a Ghostunnel metrics sidecar or kube-state-metrics | SPIRE's trust bundle, written to file by Prometheus's spiffe-helper sidecar. Prometheus checks the DNS name `<namespace>.metrics.spiffe` that ClusterSPIFFEID `metrics-targets` puts in the target's SVID, and the sidecar (or kube-state-metrics' own web config) admits only Prometheus's SPIFFE ID |
| Prometheus scraping the SPIRE server and agent | Prometheus presents its SVID and uses `insecureSkipVerify`; SPIRE validates Prometheus's SPIFFE ID. TLS certificate verification by SPIFFE ID awaits [prometheus/common#840](https://github.com/prometheus/common/pull/840) |
| Prometheus scraping native-TLS metrics, Grafana's datasources, and the Gateway's backend connection to Grafana | `openbao-root-ca` |
| Prometheus scraping the kubelet | `kube-root-ca.crt`, the k3s cluster CA |
| SeaweedFS internal HTTPS/gRPC | SeaweedFS's chart-owned CA |

Keep the listener CA, service PKI, PostgreSQL CA and SeaweedFS CA distinct, and the desktop intermediate apart from the service intermediate.

## Workstation Trust

A workstation trusts only CAs whose signing power cannot reach beyond the cluster's own names. The internal PKI root never goes into a desktop trust store: SPIRE holds an intermediate with no name constraints under it, and trusting that root would let a compromised SPIRE impersonate any website.

The two CAs a workstation may trust are public certificates. Their keys stay in the cluster:

* **The desktop CA** is OpenBao mount `pki_desktop`, an intermediate signed by the cluster's PKI root. It carries name constraints for `INTERNAL_DOMAIN` and `localhost`. The `openbao-desktop-issuer` Issuers in `gateway`, `kube-system` and `tekton-pipelines` request certificates from it.
* **`openbao-local-ca`** is the cert-manager CA behind OpenBao's own listener, with name constraints limited to the names in `openbao-server-cert` and `127.0.0.1/32`. A name added to `openbao-server-cert` must also be added to the constraint.

`just bootstrap` asks every run whether to install both into the machine's trust store (`opentofu_desktop_trust`). Pressing Enter means yes. Answering yes copies them from memory (the OpenTofu output `desktop_ca` and ConfigMap `openbao-ca-bundle`) into the system anchor directory as root, under the fixed names `data-science-cluster-desktop-ca.crt` and `data-science-cluster-openbao-ca.crt`, and refreshes the trust store. A re-bootstrap overwrites a stale anchor, answering no removes them, and `just uninstall` removes them too. The prompt can be answered ahead of time with `-e opentofu_desktop_trust=yes` or `=no`; the full-playbook Molecule scenario answers yes.

## Signing Profiles

| Issuer | Signing authority | Names and usages | Lifetime |
| --- | --- | --- | --- |
| `openbao-pki-issuer` | OpenBao `pki_int/sign/internal-server` | Server/client authentication for `${INTERNAL_DOMAIN}`, Kubernetes service names under `svc.cluster.local`, Hubble's `hubble-grpc.cilium.io`/`hubble-relay.cilium.io`/`hubble-metrics.cilium.io`/`hubble-ui.cilium.io` families, the Prometheus Operator webhook's `kube-prometheus-stack-operator` short names, and SeaweedFS S3's short aliases/localhost. Every SAN is a DNS name. | Up to 30 days |
| `openbao-ca-issuer` | OpenBao's local listener CA, name-constrained | OpenBao's service aliases and loopback, for server authentication. | `LOCAL_CA_CERT_DURATION` |
| `openbao-desktop-issuer` (namespaced, in `gateway`, `kube-system` and `tekton-pipelines`) | OpenBao `pki_desktop/sign/desktop` | Server authentication for `${INTERNAL_DOMAIN}` (wildcards allowed) and `localhost`. Every SAN is a DNS name. | Up to 30 days |
| `postgres-ca-issuer` | Dedicated PostgreSQL CA | PostgreSQL service/Gateway names and IPs for server authentication, and `streaming_replica` for replication client authentication. | `OPENBAO_PKI_CERT_DURATION` |
| SeaweedFS's namespaced `seaweedfs-ca-issuer` | Chart-owned SeaweedFS CA | Internal HTTPS/gRPC service and client certificates generated by the chart. | `LOCAL_CA_CERT_DURATION` |
| SPIRE upstream authority | OpenBao `pki/root/sign-intermediate` | SPIRE intermediates and workload identities in trust domain `cluster.internal`. | `SPIRE_CA_TTL` for intermediates |

OpenBao enforces the shared profile's DNS names, SAN types and lifetime. Wildcard certificates are permitted for the Gateway and Hubble. The CA issuers sign with their configured CA directly, outside OpenBao's leaf-role restrictions.

Hubble's Cilium chart uses one issuer for four certificates: its server requests both server and client authentication, Relay's client and Hubble UI's client request client authentication, and Relay's server requests server authentication.

The `internal-server` profile takes its Gateway domain from `cluster-config` through Ansible's OpenTofu inputs. Its short names are the SeaweedFS S3 aliases used by consumers and the Prometheus Operator webhook's Service names. An ordinary service FQDN under `svc.cluster.local` uses the shared signing role.

## Adding a Service Certificate

Declare the name the client actually connects to and choose the server issuer:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-tls
  namespace: example
spec:
  secretName: example-tls
  dnsNames:
    - example.example.svc.cluster.local
  duration: ${OPENBAO_PKI_CERT_DURATION}
  renewBefore: ${OPENBAO_PKI_CERT_RENEW_BEFORE}
  privateKey:
    algorithm: ${CERT_KEY_ALGORITHM}
    size: ${CERT_KEY_SIZE}
  issuerRef:
    name: openbao-pki-issuer
    kind: ClusterIssuer
```

Use the shared Gateway wildcard (from the desktop CA) for HTTPS routes and SPIRE for workload identities where supported. Hubble uses its chart-managed certificates and the shared issuer.

[cert-manager defaults](https://cert-manager.io/docs/usage/certificate/#x509-key-usages-and-extended-key-usages) request digital signature, key encipherment and server authentication. The signing role determines the issued certificate's permitted capabilities. That limit comes from the role, and a request's usages work within it.

## Operations and Sources

OpenBao's leaf profile and issuer authentication live in [`terraform/openbao/pki.tf`](../terraform/openbao/pki.tf) and [`kubernetes-auth.tf`](../terraform/openbao/kubernetes-auth.tf). The shared ClusterIssuer, the desktop Issuers and their RBAC grants live in [`openbao-issuers.yaml`](../infrastructure/openbao/server/openbao-issuers.yaml). The trust prompt's tasks live in the `opentofu` role's `tasks/desktop_trust.yml`. Hubble's chart issuer is configured in [`hubble-values.yaml`](../infrastructure/cilium/hubble/hubble-values.yaml).

Apply profile changes through the OpenTofu provisioning path. cert-manager and SPIRE renew certificates automatically. After a profile change, confirm that required names still issue and consumers can connect.

When changing credential delivery or expiry, check that a consumer receives its replacement and can use it for the required period. Coordinate deliberate revocation with affected consumers. Keep provisioning credentials, runtime credentials and recovery responsibilities distinct.

See [Operations](OPERATIONS.md) for provisioning and interactive access, [Verification](VERIFICATION.md) for operator checks, and [Backups and Restore](BACKUPS_RESTORE.md) for recovery procedures.
