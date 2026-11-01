# Backups and Restore

The cluster supports two backup paths:

* **Logical exports:** `pg_dump --format=custom` writes a compressed archive of one database to a location the administrator chooses. Restore it with `pg_restore`.
* **Physical recovery:** CNPG archives WAL continuously and writes scheduled base backups to SeaweedFS through the Barman Cloud Plugin. A new CNPG Cluster can recover all databases and roles from a base backup and its archived WAL.

Workstation-specific command notebooks, dump files and saved recovery manifests belong outside this repository.

## Logical Exports

Run the database tools inside the current primary Pod so their versions match PostgreSQL. Binary archives require `kubectl exec` without a TTY. The shell redirection below writes to the current directory on the workstation, rather than into the Pod:

```bash
primary=$(kubectl get pods -n databases \
  -l cnpg.io/cluster=postgres-cluster,cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n databases "$primary" -c postgres -- \
  pg_dump -U postgres -d data_science --format=custom --compress=6 \
  > data_science.dump
```

The format flag selects the archive type. Changing a `.sql` suffix to `.dump` does not convert an existing SQL file. Custom archives are compressed and support selective restoration. List the archive's contents through the same container:

```bash
kubectl exec -i -n databases "$primary" -c postgres -- \
  pg_restore --list < data_science.dump > data_science.toc
```

This listing checks that the archive header and table of contents are readable. A test restore followed by data checks establishes recoverability.

A logical dump covers only the named database. Cluster roles are provisioned separately through CNPG and OpenBao. When restoring into a newly provisioned database, use `--no-owner --no-privileges --role=app_readwrite` and explicitly select application schemas or a reviewed archive list. CNPG already manages the PostGIS extensions and their schemas. Dumped event triggers require superuser privileges and should be reviewed separately from application data. `--single-transaction --exit-on-error` makes a selected logical restore roll back if a statement fails.

## Physical Backups to SeaweedFS

Trigger a base backup and inspect the resulting Backup resource:

```bash
just backup
kubectl get backups -n databases --sort-by=.metadata.creationTimestamp
```

`just backup` uses the Barman Cloud Plugin. Confirm that the new Backup reaches `completed`. [Verification](VERIFICATION.md#verify-database-backups) covers backup and archive status checks.

## Restoring the PostgreSQL Cluster from SeaweedFS

Create a separate `Cluster` custom resource using the CRD CNPG already installed. It bootstraps a new PostgreSQL cluster and leaves `postgres-cluster` and its Gateway route in place. This example reads the source archive and does not enable new WAL archiving on the recovery cluster.

Prerequisites:

* The CNPG operator, Barman Cloud Plugin, SeaweedFS and credential-delivery components are running.
* The `postgres-backups` ObjectStore, its `barman-s3-credentials` Secret and the `openbao-root-ca` ConfigMap exist in `databases`.
* The recovery image matches the backup's PostgreSQL major version and required extensions. Storage is at least as large as the source volume.
* The separate recovery cluster has the receiver-side network permissions shown below.

Save this manifest as `postgres-restore.yaml` in a local directory:

```yaml
# A Cluster custom resource, using the CRD already installed by CNPG.
# Match imageName to the physical backup's PostgreSQL major and extensions.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restore
  namespace: databases
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgis:18.6-3.6.4-system-trixie
  storage:
    size: 100Gi
    storageClass: local-path
  enableSuperuserAccess: true
  superuserSecret:
    name: postgres-superuser-credentials
  bootstrap:
    recovery:
      source: postgres-backup-store
      # Optional: recover to a time covered by the backup and archived WAL.
      # recoveryTarget:
      #   targetTime: "2026-01-01 00:00:00+00:00"
  externalClusters:
    - name: postgres-backup-store
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: postgres-backups
          serverName: postgres-cluster
```

`serverName` identifies the source backup archive and remains `postgres-cluster`. The external-cluster name identifies the recovery source within this manifest. Omitting `recoveryTarget` replays all available archived WAL. Transactions not yet archived are outside that recovery point.

### Recovery Network Permissions

The normal database and SeaweedFS rules name `postgres-cluster`. A differently named recovery cluster needs additional permissions for CNPG's operator checks, its own instances and SeaweedFS S3. Save these as `restore-networkpolicy.yaml` beside the Cluster manifest:

```yaml
# Additive permissions for a separate recovery cluster under the default-deny baseline.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: postgres-restore
  namespace: databases
spec:
  endpointSelector:
    matchLabels:
      cnpg.io/cluster: postgres-restore
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: cnpg-system
      toPorts:
        - ports:
            - port: "8000"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            cnpg.io/cluster: postgres-restore
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: postgres-restore-s3
  namespace: seaweedfs
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: seaweedfs
      app.kubernetes.io/instance: seaweedfs
      app.kubernetes.io/component: s3
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: databases
            cnpg.io/cluster: postgres-restore
      toPorts:
        - ports:
            - port: "9000"
              protocol: TCP
```

The cluster baseline already permits outgoing Pod, DNS and Kubernetes API connections. These receiver rules match the SeaweedFS chart labels and S3 port configured by this repository.

### Apply and Verify

From the directory containing the saved files:

```bash
df -h /var/lib/rancher/k3s/storage
kubectl apply -f restore-networkpolicy.yaml
kubectl create -f postgres-restore.yaml
kubectl wait -n databases --for=condition=Ready cluster/postgres-restore --timeout=30m
kubectl cnpg status postgres-restore -n databases
kubectl cnpg psql postgres-restore -n databases --tty=false -- postgres -c '\l'
```

Check expected schemas, row counts and representative queries before relying on the recovered data. Production cutover and the restored cluster's future backup destination are separate operations.

After inspection, optionally delete the recovery cluster and its retained PVCs:

```bash
kubectl delete cluster postgres-restore -n databases
kubectl delete pvc -n databases -l cnpg.io/cluster=postgres-restore
kubectl delete -f restore-networkpolicy.yaml
```

These commands delete the recovery cluster's local data. They leave the source cluster and its SeaweedFS backup archive in place.

## Recovery Limits and Image Updates

PostgreSQL and SeaweedFS currently share one host. Keep an additional copy off the machine to cover loss of its storage. SeaweedFS recovery also depends on surviving object-store data and the working OpenBao/CSI credential-delivery path.

`POSTGIS_IMAGE_TAG` in `infrastructure/cluster-config/versions.yaml` holds the complete operand tag. Renovate tracks that pin, the README version and the recovery example above. Its regex rule compares both component versions and retains `system-trixie`. New PostgreSQL major and PostGIS minor or major versions can be proposed for review. PostgreSQL major upgrades require a migration, and PostGIS upgrades may require updating the installed extensions. Local recovery files do not change when Renovate updates the repository. Review their image against the backup being restored.

## Sources

* [PostgreSQL 18: pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html)
* [PostgreSQL 18: pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html)
* [Using the Barman Cloud Plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/)
* [CNPG PostGIS Container Images](https://github.com/cloudnative-pg/postgis-containers)
* [Renovate: Regular Expression Versioning](https://docs.renovatebot.com/modules/versioning/regex/)
