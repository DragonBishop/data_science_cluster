# Cluster Network Policy

## The Rules

**Start closed, allow shared infrastructure in the baseline, and let each component declare its additional connections.**

**One policy for the cluster, one per namespace.** `cluster-default` is the one policy for the whole cluster. Every other rule belongs to one namespace, and lives in the policy file of the component that deploys into that namespace, beside its resources. No component writes policy into another component's namespace. A caller from another namespace, or from a module, gets its rule in the receiver's file, where it stays while the module is off.

The cluster baseline, `cluster-default` in [`infrastructure/cilium/cilium-clusterwide-networkpolicy.yaml`](../infrastructure/cilium/cilium-clusterwide-networkpolicy.yaml):

1. Every pod starts closed.
2. The node reaches any pod.
3. Any pod reaches any other pod; the receiver decides.
4. Any pod reaches the Kubernetes API.
5. Any pod reaches CoreDNS.
6. The LAN and the node reach the Gateway.

Everything else is opened by the component that needs it:

* A pod accepts a call when its own policy names the caller and the port.
* The Gateway reaches a backend when the receiver's policy allows `ingress` on its listening port.
* A pod reaches an internet site when its own policy names the domain.
* A pod reaches a host port when its own policy names the port.
* A service is reached from the LAN through a Gateway route.
* CoreDNS accepts LAN DNS directly on 53/TCP and UDP.

The rest of this page explains how these rules work and how to add to them.

## Host and LAN Access

The host firewall and Cilium have different jobs. The host firewall filters connections into the node. Cilium controls pod traffic and Gateway routing.

On Fedora/RHEL, the host firewall follows these rules:

1. The LAN interface uses a filtering zone, not an `ACCEPT` zone. Read `LAN_INTERFACE` from cluster-config; do not assume the default zone owns it.
2. Declare each host service explicitly. Keep named workstation services and individual port allowances; remove FedoraWorkstation's blanket TCP/UDP `1025-65535` allowances. Add a narrow exception before using a workstation application that previously relied on that range.
3. Keep DNS (53/TCP and UDP), Gateway HTTPS (443/TCP), and Gateway PostgreSQL (5432/TCP) available in the LAN zone. CoreDNS is the explicit exception to publishing services through Gateway.
4. Pods in the trusted Cilium zone may reach the host. `k8s-containers-to-host` accepts `trusted -> HOST`, never `ANY -> HOST`. The pod's Cilium egress policy still names the host ports it needs, including API 6443, kubelet 10250, and Hubble 4244.
5. Keep Cilium interfaces and pod CIDR trusted, existing forwarding policies intact, and masquerading owned by Cilium.

[`setup-firewall.sh`](../src/bash/setup-firewall.sh) applies these rules; [`preflight.sh`](../src/bash/preflight.sh) checks the LAN zone, port ranges, and policy directions. Neither changes k3s's listen addresses. The Ubuntu/Debian branch retains its existing UFW setup for Cilium; this Fedora correction does not establish equivalent UFW perimeter enforcement.

A local firewall configuration check does not prove LAN isolation. Cilium's eBPF service and NodePort paths can bypass ordinary host input filtering. Check service continuity and unwanted exposure from a separate LAN client as described in [Verification](VERIFICATION.md#host-firewall-network-checks). Adding a listener requires reviewing both the host firewall and the receiving Cilium policy.

## How Cilium Decides

Cilium treats each pod as open until a policy selects it. Once a policy with an `ingress` section selects a pod, that pod accepts the traffic the policy lists and drops the rest. An `egress` section does the same for outgoing traffic.

Policies add up. A pod selected by three policies accepts the traffic any of them allow. Nothing in this cluster subtracts traffic: there are no deny rules. Every rule you write opens one more path.

`cluster-default` selects every pod and has both sections. That one policy closes the whole cluster. Every other policy reopens a single path for a single workload.

## The Baseline

Each numbered comment in the [baseline manifest](../infrastructure/cilium/cilium-clusterwide-networkpolicy.yaml) marks the rule below with the same number.

**1. Every pod starts closed.** The first entry selects every pod (`endpointSelector: {}`) and has both an `ingress` and an `egress` section. Rules 2 to 5 are the traffic it lets through.

**2. The node reaches any pod.** The `host` entity is the node. It carries kubelet probes, and on k3s the apiserver's webhook calls also come from the host. Every pod needs those infrastructure calls. Gateway traffic has the separate `ingress` identity and needs a receiver rule on the backend's listening port.

**3. Any pod reaches any other pod; the receiver decides.** The receiving pod's policy decides whether the call lands. Ownership stays in one place: the pod that listens on a port declares who may use it.

**4. Any pod reaches the Kubernetes API.** Controllers and operators talk to the API on 6443. RBAC decides what they can do once connected.

**5. Any pod reaches CoreDNS.** Name lookups go to CoreDNS on 53. The `dns` rule sends them through Cilium's DNS proxy. The proxy is how Cilium learns which IP belongs to which domain, and `toFQDNs` rules depend on it.

**6. The LAN and the node reach the Gateway.** The second entry selects the Gateway's Envoy (`reserved:ingress`) and admits `LAN_CIDR` and the node's loopback. The Gateway's listeners and routes decide where that traffic goes next.

```mermaid
flowchart LR
  LAN[LAN client] -->|listener ports| GW[Gateway]
  Node[Node: kubelet, apiserver] --> A
  GW -->|"receiver permits ingress on its backend port"| A[Pod A]
  A -->|"allowed if B's rule names A"| B[Pod B]
  A -->|53| DNS[CoreDNS]
  A -->|API port| API[Kubernetes API]
  A -->|"only with an FQDN rule, 443"| Net[Internet site]
```

## Opening a Path

Each example below is a policy already in the cluster.

### A pod calls another pod

The Tekton Results watcher sends records to the Results API. The rule lives on the API, the receiving side:

```mermaid
flowchart LR
  watcher[Results watcher] -->|8080| api
  subgraph policy["results-api: ingress rule names the watcher and 8080"]
    api[Results API]
  end
```

[`infrastructure/tekton/tekton-networkpolicy.yaml`](../infrastructure/tekton/tekton-networkpolicy.yaml)

```yaml
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: tekton-results-api
  ingress:
    # Watcher sends PipelineRun and TaskRun records
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: tekton-results-watcher
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
```

In a namespaced policy, `fromEndpoints` matches pods in the policy's own namespace. To name a caller from another namespace, add `k8s:io.kubernetes.pod.namespace: <namespace>` to the rule's `matchLabels`, as `postgres-cluster` does for OpenBao.

Write the pod's listening port, not the Service port. Cilium translates the Service address before it checks policy. `kubectl get svc <name> -o yaml` shows the `targetPort`.

### A pod calls an internet site

TaskRun pods in `tekton-pipelines` clone from the Git forge and install from PyPI. The rule lives on the sender:

```mermaid
flowchart LR
  subgraph policy["taskrun: egress rule names the domains and 443"]
    run[TaskRun pod]
  end
  run -->|"53, through the DNS proxy"| dns[CoreDNS]
  run -->|443| sites[Git forge, PyPI]
```

[`infrastructure/tekton-pipelines/tekton-pipelines-networkpolicy.yaml`](../infrastructure/tekton-pipelines/tekton-pipelines-networkpolicy.yaml)

```yaml
  egress:
    - toFQDNs:
        - matchName: "github.com"
        - matchPattern: "*.github.com"
        - matchName: "pypi.org"
        - matchName: "files.pythonhosted.org"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

Name each host with `matchName`. Use `matchPattern` wildcards for vendor-owned domains, where one company owns every subdomain. Tenant domains such as `*.github.io` host many owners; list those by full name.

### A pod calls a host port

Hubble Relay reads the Cilium agent's Hubble server on the node:

```mermaid
flowchart LR
  subgraph policy["hubble-relay: egress rule names host and 4244"]
    relay[Hubble Relay]
  end
  relay -->|4244| agent["Node: Cilium agent's Hubble server"]
```

[`infrastructure/cilium/kube-system-networkpolicy.yaml`](../infrastructure/cilium/kube-system-networkpolicy.yaml)

```yaml
  egress:
    - toEntities:
        - host
      toPorts:
        - ports:
            - port: "4244"
              protocol: TCP
```

### The LAN reaches a service

Publishing a service has three declarations:

1. **Once per namespace:** label it `data-cluster/gateway-access: "true"` in `infrastructure/namespaces/namespaces.yaml`. The Gateway's listeners only accept routes from namespaces with that label. Every service in an approved namespace reuses that approval.
2. Add a Gateway route (`HTTPRoute` or `TCPRoute`) in that namespace.
3. Allow `fromEntities: [ingress]` on the backend's listening port in the receiver's policy.

PostgreSQL declares its backend permission in `apps/databases/databases-networkpolicy.yaml`:

```yaml
ingress:
  - fromEntities:
      - ingress
    toPorts:
      - ports:
          - port: "5432"
            protocol: TCP
```

Baseline rule 6 admits the LAN into the Gateway. Do not add public-listener port restrictions to that rule: Envoy's internal listener ports differ. Restrict the backend port in the receiver's policy instead. [Cilium documents these two policy enforcement points](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/#ciliums-ingress-config-and-ciliumnetworkpolicy); [Gateway API documents namespace selectors for route attachment](https://gateway-api.sigs.k8s.io/guides/user-guides/multiple-ns/).

The namespace label permits route attachment. The receiver's policy permits the actual backend connection. Both are required; an accepted route does not open an undeclared backend port.

```mermaid
flowchart LR
  lan[LAN client] -->|"listener port, rule 6"| gw[Gateway]
  ns[Labelled namespace] -->|route attachment| gw
  gw -->|"receiver's backend port"| pods[The service's pods]
```

CoreDNS is the direct LAN exception. Its policy in `kube-system-networkpolicy.yaml` allows `LAN_CIDR` on 53/TCP and UDP, alongside pod DNS queries. Keep the existing DNS proxy and upstream resolver rules. This step leaves the DNS Service's traffic policy unchanged.

### Adding an HTTPS service

Reuse the shared `https` listener on 443, its wildcard DNS, and its wildcard certificate. The configured domain is `cluster.internal`, so applications use names such as `example.cluster.internal` and the certificate covers `*.cluster.internal`. Adding a hostname under that wildcard needs no per-service edit to the Gateway, DNS, certificate, or host firewall.

Suppose namespace `tools` has a Service named `example` on port 80, targeting pods labelled `app.kubernetes.io/name: example` on port 8080. Approve `tools` once in the namespace file:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tools
  labels:
    data-cluster/gateway-access: "true"
```

Add the route beside the workload and include it in the component's existing `kustomization.yaml`, like any other resource:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: example
  namespace: tools
spec:
  parentRefs:
    - name: internal-gateway
      namespace: gateway
      sectionName: https
  hostnames:
    - "example.${INTERNAL_DOMAIN}"
  rules:
    - backendRefs:
        - name: example
          port: 80
```

In the namespace's existing network-policy file, add this permission to the workload's policy. Select only the receiving pods:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: example
  namespace: tools
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: example
  ingress:
    - fromEntities:
        - ingress
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
```

The route names the **Service port** (80); the receiver rule names the **pod port** (8080). Keep the route and backend in the same namespace. The component's Flux Kustomization must substitute cluster-config for `${INTERNAL_DOMAIN}`, as the existing components do. After reconciliation, run `just gateway-check example.<INTERNAL_DOMAIN>` with the configured domain.

### Adding a raw TCP service

Reuse `databases-route.yaml` as the TCPRoute pattern. A different raw TCP service needs its own Gateway listener and port; raw TCP does not select backends by HTTP hostname. Add that port to the explicit allowances in `setup-firewall.sh` and the corresponding checks in `preflight.sh`. Then add the route and receiver permission as above. Adding another HTTPS application uses the existing 443 listener.

## Conventions

* The cluster has one policy file, `infrastructure/cilium/cilium-clusterwide-networkpolicy.yaml`.
* Each namespace that needs more than the baseline has one policy file, `<component>-networkpolicy.yaml`, holding every policy object for that namespace. It sits in the directory of the Kustomization that deploys the namespace's resources.
* A namespace that needs nothing beyond the baseline has no policy file.
* A policy is named after the workload it selects, and holds that workload's incoming and outgoing rules.
* Each rule carries a one-line comment saying what the traffic is.
* Callers are named by namespace and `app.kubernetes.io/name`, or by the labels their chart sets.
* A port this repo sets comes from cluster-config as `${VAR}`. A port the upstream software fixes is a literal.
* A chart's own policy is fine when the chart builds it from its own port values. SeaweedFS does this.

## Finding a Missing Rule

```bash
hubble observe --verdict DROPPED -f
```

Each line shows the source, destination and port of a dropped connection. First confirm the connection is required. For a pod-to-pod call, inspect the receiver's caller/port rule; for an internet call, inspect the sender's domain rule. Add only the required permission in the owning component's file. [Troubleshooting](TROUBLESHOOTING.md) covers `toPorts` rules that don't match.

## Bootstrap

Flux needs network access before it can deliver any policy, and so do the workloads Ansible installs before Flux. Ansible applies three files first, one per scope. The `cilium` role applies the cluster-wide file and `kube-system`'s file right after Cilium installs (`roles/cilium/tasks/policies.yml`). The `flux` role applies `flux-system`'s file (`roles/flux/tasks/sync.yml`). Flux takes ownership of them on its first reconcile.

## Policies

| Policy | File | Allows |
| --- | --- | --- |
| `cluster-default` | [`infrastructure/cilium/cilium-clusterwide-networkpolicy.yaml`](../infrastructure/cilium/cilium-clusterwide-networkpolicy.yaml) | Baseline rules 1 to 6 |
| `coredns` | [`infrastructure/cilium/kube-system-networkpolicy.yaml`](../infrastructure/cilium/kube-system-networkpolicy.yaml) | LAN and every pod on 53; CoreDNS to upstream resolvers on 53 |
| `metrics-server` | [`infrastructure/cilium/kube-system-networkpolicy.yaml`](../infrastructure/cilium/kube-system-networkpolicy.yaml) | metrics-server to the kubelet on 10250 |
| `hubble-relay` | [`infrastructure/cilium/kube-system-networkpolicy.yaml`](../infrastructure/cilium/kube-system-networkpolicy.yaml) | Hubble Relay to the agent's Hubble server on 4244; Tekton runs to Relay on 4245 |
| `flux` | [`clusters/local/flux-system/flux-networkpolicy.yaml`](../clusters/local/flux-system/flux-networkpolicy.yaml) | Flux controllers to each other on 9090; Flux to its source hosts on 443 |
| `openbao` | [`infrastructure/openbao/openbao-networkpolicy.yaml`](../infrastructure/openbao/openbao-networkpolicy.yaml) | cert-manager, the OpenBao CSI Provider, the SPIRE server and `core-test` to OpenBao on 8200; OpenBao to the secrets-aws plugin's registry on 443 |
| `plugin-barman-cloud` | [`apps/barman-cloud/cnpg-system-networkpolicy.yaml`](../apps/barman-cloud/cnpg-system-networkpolicy.yaml) | The CNPG operator to the plugin on 9090 |
| `postgres-cluster` | [`apps/databases/databases-networkpolicy.yaml`](../apps/databases/databases-networkpolicy.yaml) | Gateway, instances, OpenBao, Tekton Results and `core-test` on 5432; the CNPG operator on 8000 |
| SeaweedFS chart policies | [`apps/seaweedfs/seaweedfs-release.yaml`](../apps/seaweedfs/seaweedfs-release.yaml) (`networkPolicy`) | SeaweedFS components to each other; Postgres, OpenBao and `core-test` to S3 on `SEAWEEDFS_S3_PORT` |
| `remote-resolvers`, `results-api` | [`infrastructure/tekton/tekton-networkpolicy.yaml`](../infrastructure/tekton/tekton-networkpolicy.yaml) | The resolvers to their source hosts on 443; the Results watcher to the Results API on 8080 |
| `taskrun` | [`infrastructure/tekton-pipelines/tekton-pipelines-networkpolicy.yaml`](../infrastructure/tekton-pipelines/tekton-pipelines-networkpolicy.yaml) | TaskRuns to their source hosts on 443 |
