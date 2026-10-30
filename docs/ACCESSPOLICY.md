# Access Policy

## The Rules

1. A grant names the resources and operations its caller needs.
2. Access to namespaced resources uses a Role and RoleBinding in the resource's namespace. Cluster-wide access requires a cluster-wide job.
3. A token-request grant names the target ServiceAccount. Permission to request one account's token does not imply permission to request another's.

The host operator and Flux's cluster reconcilers are trusted administrators of this single-node cluster. Workload identities receive the access their jobs need.

## Issuer Authentication

cert-manager authenticates `openbao-pki-issuer` to OpenBao using a short-lived Kubernetes token for ServiceAccount `cert-manager` in namespace `cert-manager`.

The issuer and its grant live together in [`infrastructure/openbao/openbao-issuers.yaml`](../infrastructure/openbao/openbao-issuers.yaml). The `cert-manager-tokenrequest` Role allows `create` on `serviceaccounts/token` for `resourceNames: [cert-manager]`. Its RoleBinding grants that access to the cert-manager controller in the same namespace. This follows [cert-manager's named-account authentication pattern](https://cert-manager.io/docs/configuration/vault/).

A new issuer using another account needs a grant naming that account in its own namespace. It does not need permission to create tokens throughout the cluster. Kubernetes RBAC checks the target account's name for this named subresource.

## Delivery

Flux's `openbao` Kustomization applies the issuer manifest after cert-manager is available. Its pruning removes managed objects no longer declared in that source, including the previous cluster-wide token-request grant. Changes to the running cluster go through the Git source Flux reconciles.

Ansible reads the same manifest during a fresh bootstrap. It does not manage transitions between previous and current grants. A local branch change is not deployed until Flux reconciles that revision; applying the new namespaced grant alone would leave any old grant effective because RBAC permissions add together.

An API-breaking change follows the cluster's database-dump and re-bootstrap procedure. This scoped RBAC change preserves the issuer's ServiceAccount, audience, and API configuration.
