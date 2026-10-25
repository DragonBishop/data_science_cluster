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
* [Verify Dynamic Credentials](#verify-dynamic-credentials)
  * [Check Dynamic Secret & Role Membership](#check-dynamic-secret--role-membership)
  * [Test Leased Database Access](#test-leased-database-access)
* [Verify Gateway Routing](#verify-gateway-routing)
* [Hubble Observability Access](#hubble-observability-access)
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
kubectl exec -i postgres-cluster-1 -n databases -- psql -U postgres -d data_science -c '\dx'
```

Verify installed extensions: `postgis`, `postgis_topology`, `postgis_tiger_geocoder`, and `fuzzystrmatch`.

### Database Ownership

```bash
kubectl exec -i postgres-cluster-1 -n databases -- psql -U postgres -d postgres -c \
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
kubectl exec -i postgres-cluster-1 -n databases -- psql -U postgres -d data_science -c '\dn'
```

Verify all application schemas are present.

## Verify Dynamic Credentials

Once the CNPG cluster is healthy, ESO's `VaultDynamicSecret` generator requests credentials from OpenBao and writes them to the `postgres-app-dynamic-credentials` Secret. Every 2h (`ESO_DYNAMIC_REFRESH_INTERVAL`) it generates a new role; each old role expires at its 3h TTL.

### Check Dynamic Secret & Role Membership

```bash
kubectl get externalsecret postgres-app-dynamic-credentials -n databases
kubectl exec -i postgres-cluster-1 -n databases -- psql -U postgres -d postgres -c '\du'
```

Verify the generated role is a member of `app_readwrite`.

### Test Leased Database Access

Open psql in the CNPG primary pod as the current OpenBao-issued login:

> [!TIP]
> **Just Recipe:**
>
> ```bash
> just db-connect
> ```

> [!NOTE]
> **Manual Shell Command:**
>
> ```bash
> LEASE_USER=$(kubectl get secret -n databases postgres-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
> LEASE_PASS=$(kubectl get secret -n databases postgres-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
> kubectl cnpg psql postgres-cluster -n databases -- "host=localhost dbname=data_science user=$LEASE_USER password=$LEASE_PASS"
> ```

---

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

* **CLI Flow Streaming**: `just hubble status` and `just hubble observe --follow` stream flows from Hubble Relay over mTLS (port 4245).

---

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
