"""Network policies follow the rules in README.md "Network Policy"."""

# Scaffold: pseudocode for each test, to be written. Reuse REPO_ROOT and the
# yaml.safe_load_all pattern from test_cluster_config_drift.py.
#
# gather every network policy in infrastructure/ and apps/
#   (kind CiliumNetworkPolicy or CiliumClusterwideNetworkPolicy)
# for each policy, list its rules: each ingress and egress entry,
#   with its "who" part (entities, endpoints, CIDRs, domain names) and its "which ports" part
#
# test: every rule outside the baseline names its ports                  (Additional Policies)
#   baseline files = infrastructure/cilium/clusterwide-networkpolicy.yaml,
#                    infrastructure/gateway/gateway-networkpolicy.yaml,
#                    infrastructure/namespaces/namespaces.yaml
#   for each policy in any other file, for each rule:
#     expect it to list ports
#
# test: baseline rules that reach the host or the API server name their ports   (Baseline 1)
#   for each outgoing rule in the baseline files whose "who" includes host or kube-apiserver:
#     expect it to list ports (6443 for the API)
#
# test: no rule opens the whole cluster at once                          (Baseline 1)
#   for each rule:
#     expect its "who" not to include the cluster entity
#
# test: the internet opens by domain name                                (Additional Policies)
#   for each outgoing rule whose "who" includes world:
#     expect it to be the CoreDNS upstream rule (port 53)
#   (domain-name lists are fine anywhere)
#
# test: pods accept outside traffic only through the Gateway             (Baseline 2, 3)
#   for each namespaced policy, for each incoming rule:
#     expect it not to come from world or from a CIDR range
#
# test: every namespace has its same-namespace rule                      (Baseline: new namespace)
#   for each Namespace in infrastructure/namespaces/namespaces.yaml:
#     expect an allow-same-namespace policy for it in the same file
#
# Sanity check while writing: these fail against the manifests before the
# network-policy rewrite and pass after it.
