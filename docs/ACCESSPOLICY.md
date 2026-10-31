# Access Policy

## The Rules

1. Each caller gets only the access its job needs.
2. Verify the expected identity before granting access or trusting a connection.
3. A grant names the resources and operations the caller may use. Cluster-wide access requires a cluster-wide job.
4. Deliver credentials privately to authorized consumers. Limit provisioning credentials to the operation that needs them.
5. Limit certificate signing to the required names, uses and lifetimes. Trust bundles contain public CA certificates, never private keys.
6. Deliver usable replacement credentials before expiry. Distribute replacement CA trust before switching issuers.

This single-node cluster trusts its human administrator and the configured Flux, cert-manager and credential-delivery controllers. Workloads authenticate through their named identities; receiving services enforce their permissions. [Network Policy](NETWORKPOLICY.md) governs connection reachability.

## Permissions

Access to namespaced Kubernetes resources uses a Role and RoleBinding in the resource's namespace. RBAC permissions add together: a narrow grant does not cancel access provided by another grant.

### Issuer Authentication

cert-manager authenticates `openbao-pki-issuer` to OpenBao using a short-lived Kubernetes token for ServiceAccount `cert-manager` in namespace `cert-manager`.

The issuer and its grant live together in [`infrastructure/openbao/openbao-issuers.yaml`](../infrastructure/openbao/openbao-issuers.yaml). The `cert-manager-tokenrequest` Role allows `create` on `serviceaccounts/token` for `resourceNames: [cert-manager]`. Its RoleBinding grants that access to the cert-manager controller in the same namespace. This follows [cert-manager's named-account authentication pattern](https://cert-manager.io/docs/configuration/vault/).

A token-request grant names the target ServiceAccount. A new issuer using another account needs a grant naming that account in its own namespace. Kubernetes RBAC checks the target account's name for this named subresource.

Kubernetes permissions also control who may create Certificate resources or edit issuers. A ClusterIssuer is available across namespaces; choosing a profile is not a namespace access boundary.

Flux's `openbao` Kustomization applies the issuer manifest after cert-manager is available and prunes managed objects removed from that source. Ansible uses the same manifest during a fresh bootstrap.

## Provisioning Credentials

`just bootstrap` collects provisioning inputs through private prompts. The Ansible OpenTofu role supplies them to the apply process through environment variables, with task logging suppressed. OpenTofu uses OpenBao's root token to configure policies, authentication methods and secret engines. The state-encryption passphrase protects local OpenTofu state and plans.

The OpenTofu role verifies OpenBao's listener certificate using the public CA in ConfigMap `openbao-ca-bundle`. It waits for the Bundle output and writes the CA to `.local/openbao/certs/openbao-internal-ca.crt`. The directory and file have owner-only permissions to protect the trust file from modification.

Ansible installs trust-manager and OpenBao's listener certificates and Bundle before OpenTofu and Flux. The listener CA is independent of the service PKI managed by OpenTofu. The GPG-encrypted unseal file supplies the startup workflow's recovery input.

## Workload Credentials

| Consumer | Delivery | Lifetime and refresh |
| --- | --- | --- |
| CNPG Barman Cloud | OpenBao CSI provider, using the named Barman ServiceAccount and S3 role | Four-day S3 lease; issuing token covers that lease; daily refresh/reload |
| Tekton Results | OpenBao CSI provider, synchronizing the database login into its configured Secret | Four-day database lease; issuing token covers that lease; daily refresh/reload |
| Data-science database clients | OpenBao's named database authentication role | Three-hour default database lease, up to 24 hours; the client must refresh before expiry |

A CSI issuing token must cover the lease of the credential it creates. Keep the provider's `cache-size=0`, issuing-token lifetimes and child leases aligned. Shortening a parent token independently can revoke credentials still in use. Daily rotation and consumer reload deliver replacement credentials.

Keep secret values out of Git, ordinary task output, command arguments and reports. Use private prompts, protected files and workload delivery mechanisms. Secret-bearing Ansible tasks suppress their results; public CA data does not require secret handling.

## Certificate Trust

Trust a certificate only when it identifies the service or workload you expected, is valid for the connection, and can be verified using the intended CA.

| Consumer | Trust source |
| --- | --- |
| OpenTofu, cert-manager and SPIRE connecting to OpenBao | `openbao-local-ca-secret`, distributed as `openbao-ca-bundle` |
| Gateway, SeaweedFS S3, Results API and Hubble clients | OpenBao's service-PKI root, distributed as `openbao-root-ca` or carried in their TLS Secret |
| PostgreSQL server verification and replication | Dedicated `postgres-ca` |
| PostgreSQL SVID login | `postgres-client-ca`, containing the SPIRE signing root and PostgreSQL replication CA |
| Flux controller mTLS and workload identity consumers | SPIRE's workload API trust bundle |
| SeaweedFS internal HTTPS/gRPC | SeaweedFS's chart-owned CA |

Keep the listener CA, service PKI, PostgreSQL CA and SeaweedFS CA distinct. DNS name constraints do not restrict SPIFFE URI identities.

## Signing Profiles

| Issuer | Signing authority | Names and usages | Lifetime |
| --- | --- | --- | --- |
| `openbao-pki-issuer` | OpenBao `pki_int/sign/internal-server` | Server/client authentication for `${INTERNAL_DOMAIN}`, Kubernetes service names under `svc.cluster.local`, Hubble's `hubble-grpc.cilium.io`/`hubble-relay.cilium.io` families, and SeaweedFS S3's short aliases/localhost. No IP or URI SANs. | Up to 30 days |
| `openbao-ca-issuer` | OpenBao's local listener CA | OpenBao's service aliases and loopback; server authentication. | `LOCAL_CA_CERT_DURATION` |
| `postgres-ca-issuer` | Dedicated PostgreSQL CA | PostgreSQL service/Gateway names and IPs for server authentication; `streaming_replica` for replication client authentication. | `OPENBAO_PKI_CERT_DURATION` |
| SeaweedFS's namespaced `seaweedfs-ca-issuer` | Chart-owned SeaweedFS CA | Internal HTTPS/gRPC service and client certificates generated by the chart. | `LOCAL_CA_CERT_DURATION` |
| SPIRE upstream authority | OpenBao `pki/root/sign-intermediate` | SPIRE intermediates and workload identities in trust domain `cluster.internal`. | `SPIRE_CA_TTL` for intermediates |

OpenBao enforces the shared profile's DNS names, SAN types and lifetime. Wildcard certificates are permitted for the Gateway and Hubble. The CA issuers use their configured CA directly; OpenBao's leaf-role restrictions do not apply to those issuers.

Hubble's Cilium chart uses one issuer for three certificates: its server requests both server and client authentication, its Relay client requests client authentication, and its Relay server requests server authentication. The shared OpenBao role supports both usages; ordinary service certificates can also carry client authentication. Workload identity and application permissions are governed by SPIRE and the receiving service's authentication rules.

The `internal-server` profile takes its Gateway domain from `cluster-config` through Ansible's OpenTofu inputs. Its short names are the SeaweedFS S3 aliases used by consumers. An ordinary service FQDN under `svc.cluster.local` uses the shared signing role.

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

Use the shared Gateway wildcard for HTTPS routes and SPIRE for workload identities where supported. Hubble uses its chart-managed certificates and the shared issuer.

[cert-manager defaults](https://cert-manager.io/docs/usage/certificate/#x509-key-usages-and-extended-key-usages) request digital signature, key encipherment and server authentication. The signing role determines the issued certificate's permitted capabilities; the request's usages alone do not restrict the signing authority.

## Operations and Sources

OpenBao's leaf profile and issuer authentication live in [`terraform/openbao/pki.tf`](../terraform/openbao/pki.tf) and [`kubernetes-auth.tf`](../terraform/openbao/kubernetes-auth.tf). The shared ClusterIssuer and its RBAC grant live in [`openbao-issuers.yaml`](../infrastructure/openbao/openbao-issuers.yaml). Hubble's chart issuer is configured in [`hubble-values.yaml`](../infrastructure/hubble/hubble-values.yaml).

Apply profile changes through the OpenTofu provisioning path. cert-manager renews service certificates through their configured issuers; SPIRE renews workload identities. Editing a leaf profile does not replace CA roots or revoke certificates already issued. Confirm that required names still issue and consumers can connect after a profile change.

When changing credential delivery or expiry, check that a consumer receives its replacement and can use it for the required period. Coordinate deliberate revocation with affected consumers. Keep provisioning credentials, runtime credentials and recovery responsibilities distinct.

See [Operations](OPERATIONS.md) for provisioning and interactive access, [Verification](VERIFICATION.md) for operator checks, and [Backups and Restore](BACKUPS_RESTORE.md) for recovery procedures.
