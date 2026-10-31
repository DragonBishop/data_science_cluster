# Verification

`just bootstrap` deploys the cluster. The checks below verify what Flux already reconciled.

## Table of Contents

* [Verify Database Deployment](#verify-database-deployment)
  * [Cluster Status & WAL Archiving](#cluster-status--wal-archiving)
  * [CNPG Database Resource](#cnpg-database-resource)
  * [PostGIS Extensions](#postgis-extensions)
  * [Database Ownership](#database-ownership)
  * [Gateway TCPRoute Binding](#gateway-tcproute-binding)
  * [Restored Schemas (if migrating data)](#restored-schemas-if-migrating-data)
* [Verify Gateway Routing](#verify-gateway-routing)
* [Hubble Observability Access](#hubble-observability-access)
* [Host Firewall Network Checks](#host-firewall-network-checks)
* [Verify Cluster Health](#verify-cluster-health)
* [Verify Database Backups](#verify-database-backups)
  * [Verify Scheduled Backups](#verify-scheduled-backups)
  * [Trigger Manual Test Backup](#trigger-manual-test-backup)
  * [Confirm Backup Status](#confirm-backup-status)

---

## Verify Database Deployment

### Cluster Status & WAL Archiving

> [!TIP]
> **Just Recipe (bundled into the full health check):**
>
> ```bash
> just status
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> kubectl cnpg status postgres-cluster -n databases
> ```

Verify output shows `Status: Healthy`, `1/1 ready`, and `WAL archiving: OK`.

### CNPG Database Resource

> [!TIP]
> **Just Recipe (bundled into the full health check):**
>
> ```bash
> just status
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> kubectl get database -n databases
> ```

Verify output shows `postgres-cluster/data-science` with `status.applied: true`.

### PostGIS Extensions

```bash
kubectl cnpg psql postgres-cluster -n databases -- -d data_science -c '\dx'
```

Verify installed extensions: `postgis`, `postgis_topology`, `postgis_tiger_geocoder`, and `fuzzystrmatch`.

### Database Ownership

```bash
kubectl cnpg psql postgres-cluster -n databases -- -c \
  "SELECT datname, pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='data_science';"
```

Verify database owner is `app_readwrite`.

### Gateway TCPRoute Binding

> [!TIP]
> **Just Recipe (bundled into the full health check):**
>
> ```bash
> just status
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> kubectl get tcproute -n databases postgres-external -o jsonpath='{.status.parents[*].conditions[*].message}'
> ```

Verify condition returns `Service reference is valid`.

### Restored Schemas (if migrating data)

```bash
kubectl cnpg psql postgres-cluster -n databases -- -d data_science -c '\dn'
```

Verify all application schemas are present.

## Verify Gateway Routing

Test Gateway listener routing and edge certificate termination:

> [!TIP]
> **Just Recipe:**
>
> ```bash
> just gateway-check <name>.internal
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> curl -v --resolve <name>.internal:443:192.0.2.240 \
>   --cacert <(kubectl get secret -n gateway internal-edge-cert -o jsonpath='{.data.ca\.crt}' | base64 -d) \
>   https://<name>.internal/
> ```

Run it for any hostname with an HTTPRoute on the Gateway. Verify that the page responds and the certificate chains to `openbao-pki-issuer`'s CA (`internal-edge-cert`).

---

## Hubble Observability Access

Verify network visibility with the Hubble CLI:

* **CLI Flow Streaming**: `just hubble status` and `just hubble observe --follow` run the Hubble CLI inside the Cilium agent and stream its flows.

---

## Host Firewall Network Checks

Run these checks before changing the firewall and repeat them afterward. Compare service behavior, not just resource readiness. Read `GATEWAY_IP`, `COREDNS_LAN_IP`, and `INTERNAL_DOMAIN` from cluster-config and substitute them below.

| Path | Service check | Expected result |
| --- | --- | --- |
| Host to LAN DNS address | `dig @<COREDNS_LAN_IP> postgres.<INTERNAL_DOMAIN> A +short`, then repeat with `+tcp` | Both return `GATEWAY_IP` |
| Host through Gateway to PostgreSQL | `pg_isready -h <GATEWAY_IP> -p 5432 -t 5` | Accepting connections; also repeat a normal authenticated database query using the existing client |
| Host through HTTPS Gateway to a workload | `just gateway-check <existing-route-hostname>` | Valid TLS and the workload's expected response; requires an actual HTTPRoute |
| Metrics-server pod to host kubelet | `kubectl top nodes` | Current metrics for the node |
| Hubble Relay pod to host agent | Commands below | Relay Ready and recent forwarded traffic to 4244 |
| Host to Kubernetes API | `kubectl get --raw /readyz` | `ok` |
| Host to OpenBao localhost redirect | TLS health request below | Initialized and unsealed |

```bash
kubectl get pods -n kube-system -l k8s-app=hubble-relay
kubectl exec -n kube-system ds/cilium -c cilium-agent -- \
  hubble observe --since 5m --from-label k8s-app=hubble-relay --to-port 4244 --last 3

curl --fail --silent --show-error --max-time 10 \
  --cacert <(kubectl get configmap -n openbao openbao-ca-bundle -o jsonpath='{.data.ca\.crt}') \
  https://127.0.0.1:8210/v1/sys/health
```

Check that Flux controllers continue reconciling and the existing CSI-backed consumers remain healthy with `just status`. Do not shorten credential leases or change Cilium policy to make these firewall checks pass.

Then repeat DNS, Gateway, and the authenticated database checks from a separate LAN client. From that client, the node's API, kubelet, and Hubble ports must refuse or time out:

```bash
nc -vz -w 3 <NODE_LAN_IP> 6443
nc -vz -w 3 <NODE_LAN_IP> 10250
nc -vz -w 3 <NODE_LAN_IP> 4244
```

Also check the allocated NodePorts (`kubectl get svc -A`) from that client. Cilium handles these paths in eBPF, so removing a firewalld port range alone does not establish that NodePorts are closed. Record any remaining exposure for the network-publication phase. Checks from the node itself cannot establish LAN isolation.

## Verify Cluster Health

Check the overall operational status and reconciliation health of all cluster components:

> [!TIP]
> **Just Recipe:**
>
> ```bash
> just status
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> flux get kustomizations
> ```

---

## Verify Database Backups

Verify automated backup schedules and trigger an on-demand backup to SeaweedFS S3:

### Verify Scheduled Backups

> [!TIP]
> **Just Recipe (bundled into the full health check):**
>
> ```bash
> just status
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> kubectl get scheduledbackup -n databases
> ```

Verify `suspend: false` and scheduled backup intervals.

### Trigger Manual Test Backup

> [!TIP]
> **Just Recipe:**
>
> ```bash
> just backup
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> kubectl cnpg backup postgres-cluster -n databases -m plugin --plugin-name barman-cloud.cloudnative-pg.io
> ```

### Confirm Backup Status

> [!TIP]
> **Just Recipe (bundled into the full health check):**
>
> ```bash
> just status
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> kubectl cnpg status postgres-cluster -n databases
> ```

Verify `Last Successful Backup` timestamp updates to the current time.
