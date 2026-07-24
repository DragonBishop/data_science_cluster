# Local K3s Data Analytics Stack Documentation

This document outlines the architecture and deployment operations for a local, containerized data analytics stack hosted on Windows Subsystem for Linux (WSL). Orchestrated via k3s, the environment is optimized for an on-demand, resource-efficient workflow, utilizing PostGIS as the primary spatial datastore.

To establish a hardened security posture, the architecture integrates two critical infrastructure components: HashiCorp Vault is deployed to broker identity and dynamically manage database credentials—mitigating the vulnerabilities of static Kubernetes secrets—while Falco is implemented via the Falco Operator to enforce runtime security by monitoring kernel-level system calls for anomalous container behavior.

## 1. Engine Installation (K3s)

The k3s engine is deployed with the default Traefik ingress controller explicitly disabled to prevent port-binding conflicts on the WSL host network. Bypassing this reverse proxy minimizes the cluster's resource overhead, aligning with the requirements of a lightweight, on-demand analytics stack. This strategy simplifies the local environment setup by eliminating the need to manage local DNS entries or complex ingress routing rules.

```bash
# Install K3s
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

# Create a permanent symlink for the standard kubectl command
sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
```

## 2. Vault Installation & Initialization

To establish secrets management within the k3s cluster, the architecture integrates HashiCorp Vault. Vault mitigates the vulnerabilities inherent to static, base64-encoded Kubernetes Secrets by functioning as a centralized identity broker and encryption engine.

Deploying Vault enables the dynamic generation, automated lifecycle management, and strict access control of database credentials. This ensures that containerized workloads authenticate securely against backend datastores without exposing long-lived or hardcoded tokens within the cluster environment.

```bash
# Add the HashiCorp Helm repository
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Create the vault namespace
kubectl create namespace vault

# Install Vault in standalone mode
helm install vault hashicorp/vault \
    --namespace vault \
    --set "server.dev.enabled=false" \
    --set "injector.enabled=true"
```

Initialize the Vault to generate the master unseal keys and the root token:
*(Note: Save the generated Root Token to a secure password manager.)*

```bash
kubectl exec -it vault-0 -n vault -- vault operator init
```

### Create unseal.keys

Store the generated unseal keys in a highly restricted host file for the automated startup script:

```bash
mkdir -p ~/.vault
touch ~/.vault/unseal.keys
chmod 600 ~/.vault/unseal.keys
```

Open `~/.vault/unseal.keys` and paste exactly three unseal keys, one per line.

### Configure Database Secrets

Unseal the Vault, log in with the Root Token, and store the PostGIS credentials:

```bash
# Unseal using three keys
kubectl exec -it vault-0 -n vault -- vault operator unseal <KEY_1>
kubectl exec -it vault-0 -n vault -- vault operator unseal <KEY_2>
kubectl exec -it vault-0 -n vault -- vault operator unseal <KEY_3>

# Log in
kubectl exec -it vault-0 -n vault -- vault login <ROOT_TOKEN>

# Enable the Key-Value (KV) v2 secrets engine
kubectl exec -it vault-0 -n vault -- vault secrets enable -path=secret kv-v2

# Store the default postgres credentials
kubectl exec -it vault-0 -n vault -- vault kv put secret/postgis POSTGRES_USER="postgres" POSTGRES_PASSWORD="YourSecurePassword"
```

## 3. PostGIS Database Deployment

Create the namespace and deploy the database with Vault annotations to automatically inject credentials.

```bash
kubectl create namespace data-processing
```

Save the following configuration as `postgis-k3s.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgis-pvc
  namespace: data-processing
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgis
  namespace: data-processing
spec:
  serviceName: "postgis"
  replicas: 1
  selector:
    matchLabels:
      app: postgis
  template:
    metadata:
      labels:
        app: postgis
      annotations:
        # Enable the Vault sidecar injector
        vault.hashicorp.com/agent-inject: "true"
        # Reference the auth role for this server
        vault.hashicorp.com/role: "postgis-role"
        
        # Inject the POSTGRES_USER secret into /vault/secrets/pguser
        vault.hashicorp.com/agent-inject-secret-pguser: "secret/data/postgis"
        vault.hashicorp.com/agent-inject-template-pguser: |
          {{- with secret "secret/data/postgis" -}}
          {{ .Data.data.POSTGRES_USER }}
          {{- end -}}
          
        # Inject the POSTGRES_PASSWORD secret into /vault/secrets/pgpass
        vault.hashicorp.com/agent-inject-secret-pgpass: "secret/data/postgis"
        vault.hashicorp.com/agent-inject-template-pgpass: |
          {{- with secret "secret/data/postgis" -}}
          {{ .Data.data.POSTGRES_PASSWORD }}
          {{- end -}}
    spec:
      serviceAccountName: postgis-sa
      containers:
      - name: postgis
        # The PostGIS image repository typically tracks major PG versions.
        image: postgis/postgis:18-3.6 
        ports:
        - containerPort: 5432
          name: postgresql
        env:
        # Tell Postgres to read the credentials from the Vault-injected files
        - name: POSTGRES_USER_FILE
          value: "/vault/secrets/pguser"
        - name: POSTGRES_PASSWORD_FILE
          value: "/vault/secrets/pgpass"
        volumeMounts:
        - name: postgis-data
          mountPath: /var/lib/postgresql
      volumes:
      - name: postgis-data
        persistentVolumeClaim:
          claimName: postgis-pvc
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wsl-localhost-bridge
  namespace: data-processing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wsl-localhost-bridge
  template:
    metadata:
      labels:
        app: wsl-localhost-bridge
    spec:
      hostNetwork: true 
      dnsPolicy: ClusterFirstWithHostNet 
      containers:
      - name: tcp-bridge
        image: alpine/socat:latest 
        command:
          - "socat"
          - "TCP-LISTEN:5432,fork,reuseaddr"
          - "TCP:postgis-nodeport.data-processing.svc.cluster.local:5432"
        resources:
          requests:
            cpu: "10m"
            memory: "16Mi"
          limits:
            cpu: "50m"
            memory: "32Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: postgis-nodeport
  namespace: data-processing
spec:
  type: NodePort
  selector:
    app: postgis
  ports:
    - port: 5432
      targetPort: 5432
      nodePort: 30543
```

Apply the blueprint to initialize the database:

```bash
kubectl apply -f postgis-k3s.yaml
```

## 4. Deploying the Falco Operator

Within a k3s environment, Falco provides critical runtime security by monitoring system calls at the kernel level to detect anomalous container behavior, privilege escalations, and unauthorized cluster activity. To manage Falco’s lifecycle and rule configurations declaratively, the architecture utilizes the official Falco Operator.

The following deployment script provisions a dedicated namespace and executes a Kubernetes server-side apply, installing the operator's controller components and Custom Resource Definitions (CRDs) directly from the upstream GitHub release manifests.

```bash
# Create the dedicated namespace
kubectl create namespace falco-operator

# Define the target version and apply the manifest
VERSION=latest
if [ "$VERSION" = "latest" ]; then
  kubectl apply --server-side -f https://github.com/falcosecurity/falco-operator/releases/latest/download/install.yaml
else
  kubectl apply --server-side -f https://github.com/falcosecurity/falco-operator/releases/download/${VERSION}/install.yaml
fi
```

### What This Deploys

Applying this configuration automatically provisions the following resources in your cluster:

- Namespace: falco-operator
- Custom Resource Definitions (CRDs): Registers the core Falco artifacts (configs, plugins, rulesfiles) and instance definitions (components, falcos) to the Kubernetes API.
- RBAC & Security: Configures the falco-operator service account, cluster role, and cluster role binding to give the operator the necessary permissions to manage cluster resources.
- Controller: Deploys the falco-operator application deployment itself.

## 5. Cluster Management

The cluster is configured to operate on an on-demand basis to preserve system resources. Use these scripts to boot and safely spin down the environment.

### ~/stop-cluster.sh

To remove k3s from the systemctl, allowing for user-directed deployment of the cluster:

```bash
# Disable K3s systemd auto-start for on-demand usage
sudo systemctl disable k3s
```

To create the shutdown script file:

```bash
nano ~/stop-cluster.sh
```

Content of the shutdown script:

```bash
#!/bin/bash
echo "📉 Winding down safely before closing..."
kubectl scale statefulset postgis --replicas=0 -n data-processing

# Wait for the pod to fully terminate
until [ "$(kubectl get pods -n data-processing -l app=postgis --no-headers 2>/dev/null | wc -l)" -eq 0 ]; do sleep 2; done

echo "🛑 Stopping K3s engine..."
sudo systemctl stop k3s
echo "✅ Cluster Offline. Use ~/start-cluster.sh to restart the cluster."
```

Make it executable:

```bash
chmod +x ~/stop-cluster.sh
```

### ~/start-cluster.sh

To create the `~/start-cluster.sh` file:

```bash
nano ~/start-cluster.sh
```

Script for the startup:

```bash
#!/bin/bash
echo "🚀 Booting K3s engine..."
sudo systemctl start k3s

echo "⏳ Waiting for Kubernetes API..."
until kubectl get nodes > /dev/null 2>&1; do sleep 2; done

echo "⏳ Waiting for Vault to initialize..."
until kubectl get pods -n vault | grep -q "vault-0"; do sleep 2; done
sleep 5 # Brief buffer for the Vault API

echo "🔓 Unsealing Vault from secure host file..."
kubectl exec -n vault vault-0 -- vault operator unseal $(sed -n '1p' ~/.vault/unseal.keys) > /dev/null
kubectl exec -n vault vault-0 -- vault operator unseal $(sed -n '2p' ~/.vault/unseal.keys) > /dev/null
kubectl exec -n vault vault-0 -- vault operator unseal $(sed -n '3p' ~/.vault/unseal.keys) > /dev/null

echo "📈 Starting PostGIS database..."
kubectl scale statefulset postgis --replicas=1 -n data-processing

echo "✅ Cluster Online! Use ~/stop-cluster.sh to wind down the cluster."
```

Make it executable:

```bash
chmod +x ~/start-cluster.sh
```

### Synchronizing Kubeconfig (WSL / k3s)

This project uses a local k3s Kubernetes cluster running inside Windows Subsystem for Linux (WSL). By default, the active k3s configuration file is locked to the Linux root user.

To manage the cluster efficiently, this project utilizes a client-server architecture: the k3s cluster operates as the backend server entirely within WSL, while management and development applications run natively on Windows. The kubeconfig file acts as the ultimate bridge between the two operating systems, providing the necessary routing addresses and security keys.

By creating a static, user-owned copy of this configuration in the Linux ~/.kube directory , Windows can safely read the live file via the \\wsl$\ network path. This allows you to seamlessly connect your local cluster to powerful Windows-based desktop clients, including:

- Headlamp Desktop: For intuitive, graphical cluster monitoring and resource management.
- Lens Desktop: Another robust Kubernetes IDE that is highly popular for monitoring CPU/GPU utilization during intensive machine learning tasks.
- VS Code (Kubernetes Extension): Allows managing data science pods, deploying JupyterHub instances, or orchestrating Kubeflow pipelines.
- Standard kubectl: For native command-line execution directly from Windows PowerShell.

To prevent these Windows applications from being blocked by Linux "Permission Denied" errors , this bash script automates the process of safely snapshotting the root-locked k3s file and assigning it the correct user permissions.

Create the script file in the home directory:

```bash
nano ~/sync-kubeconfig.sh
```

Paste the bash script into the .sh file:

```bash
#!/bin/bash

# Define file paths
SOURCE_CONFIG="/etc/rancher/k3s/k3s.yaml"
DEST_DIR="$HOME/.kube"
DEST_CONFIG="$DEST_DIR/config"

echo -e "\n🔄 Starting kubeconfig sync..."

# Check if the k3s source file actually exists
if [ ! -f "$SOURCE_CONFIG" ]; then
    echo -e "❌ Error: Source config not found at $SOURCE_CONFIG."
    echo -e "   Ensure k3s is installed and currently running."
    exit 1
fi

# Ensure the hidden .kube directory exists
mkdir -p "$DEST_DIR"

# Copy the file using sudo to bypass the root lock
echo "📋 Copying config from $SOURCE_CONFIG..."
sudo cp "$SOURCE_CONFIG" "$DEST_CONFIG"

# Update ownership of the copied file to the current Linux user
echo "🔐 Updating file permissions for user: $USER..."
sudo chown $(id -u):$(id -g) "$DEST_CONFIG"

echo -e "✅ Success! Your local kubeconfig is now synced with the live k3s cluster.\n"
```

Execute the command from the terminal:

```bash
~/sync-kubeconfig.sh
```

**What this script does:**

1. Validates that the active `k3s` cluster is running and generating a config.
2. Creates the hidden `~/.kube` directory if it does not exist.
3. Copies `/etc/rancher/k3s/k3s.yaml` to `~/.kube/config`.
4. Changes the file ownership from `root` to the active standard Linux user.
5. Prints status feedback to the terminal.

*Note: You will be prompted for your standard Linux `sudo` password when running this script, as it must temporarily elevate privileges to read the root k3s file.
