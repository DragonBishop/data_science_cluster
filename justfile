module_name := "clusterpgis"

# List available recipes
default:
  @just --list

# --- Bootstrap (first-time install, see docs/INSTALLATION.md) --------------

# Configure host firewall rules for Kubernetes and Cilium (Fedora firewalld or Ubuntu ufw)
setup-firewall:
  ./src/bash/setup-firewall.sh

# Read-only host readiness check (tooling, gh auth, firewall, reserved IPs)
preflight:
  ./src/bash/preflight.sh

# Run full cluster bootstrap via Ansible (prompts for sudo; accepts flags like --tags, --check, -v)
bootstrap *ARGS:
  uv run ansible-galaxy collection install --upgrade -p ansible ansible/ansible_collections/dragonbishop/cluster
  uv run ansible-playbook dragonbishop.cluster.data_cluster --ask-become-pass {{ARGS}}

# --- Cluster lifecycle -------------------------------------------------

# Start the cluster
start:
  ./src/bash/start-cluster.sh

# Read-only cluster health check (Flux, Gateway/DNS, cert-manager, database, backups, SeaweedFS, Hubble)
status:
  #!/usr/bin/env bash
  set -uo pipefail
  echo "== Flux =="
  flux get kustomizations

  echo ""
  echo "== Gateway / DNS =="
  kubectl get ciliumloadbalancerippool
  kubectl get gateway -n gateway internal-gateway -o wide
  kubectl get svc -n kube-system coredns-external

  echo ""
  echo "== cert-manager =="
  kubectl get clusterissuer openbao-pki-issuer

  echo ""
  echo "== Database =="
  kubectl cnpg status postgis-cluster -n databases
  kubectl get database -n databases
  echo -n "TCPRoute: "; kubectl get tcproute -n databases postgis-external -o jsonpath='{.status.parents[*].conditions[*].message}'; echo

  echo ""
  echo "== Backups =="
  kubectl get scheduledbackup -n databases
  kubectl rollout status deployment -n cnpg-system plugin-barman-cloud --timeout=10s

  echo ""
  echo "== SeaweedFS =="
  kubectl get svc,pods -n databases -l app.kubernetes.io/instance=seaweedfs

  echo ""
  echo "== Hubble =="
  kubectl get pods -n kube-system -l k8s-app=hubble-relay

# Stop the cluster (pass --force to skip confirmation on a stuck stop)
stop *ARGS:
  ./src/bash/stop-cluster.sh {{ARGS}}

# Uninstall k3s and clear stale local cluster state (sudo required)
uninstall:
  ./src/bash/uninstall-cluster.sh

# Fuzzy-select a pod (all namespaces) and describe it
fuzzypods:
  kubectl get pods -A --no-headers | fzf | awk '{print $2, $1}' | xargs -n 2 sh -c 'kubectl describe pod $0 -n $1'

# Verify TLS and routing for a Gateway hostname (HOST defaults to the live Gateway IP)
gateway-check DOMAIN HOST=`kubectl get gateway -n gateway internal-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null`:
  #!/usr/bin/env bash
  set -uo pipefail
  if [ -z "{{HOST}}" ]; then
    echo "Error: Could not determine the Gateway IP. Pass it explicitly: just gateway-check {{DOMAIN}} <HOST>" >&2
    exit 1
  fi
  curl -v --resolve "{{DOMAIN}}:443:{{HOST}}" \
    --cacert <(kubectl get secret -n gateway internal-edge-cert -o jsonpath='{.data.ca\.crt}' | base64 -d) \
    "https://{{DOMAIN}}/"

# Run Hubble CLI command against hubble-relay (localhost:4245 through a local redirect)
hubble *ARGS='status':
  #!/usr/bin/env bash
  set -uo pipefail
  mkdir -p ~/.hubble/tls
  for file in ca.crt tls.crt tls.key; do
    kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath="{.data.${file//./\\.}}" | base64 -d > ~/.hubble/tls/$file
  done
  chmod 600 ~/.hubble/tls/*

  hubble --server localhost:4245 --tls \
    --tls-server-name relay.hubble-relay.cilium.io \
    --tls-ca-cert-files ~/.hubble/tls/ca.crt \
    --tls-client-cert-file ~/.hubble/tls/tls.crt \
    --tls-client-key-file ~/.hubble/tls/tls.key \
    {{ARGS}} 2> >(grep -v --line-buffered "Hubble CLI version is lower than Hubble Relay" >&2)

bao_env := "unset BAO_TOKEN"

# Export OpenBao's CA and print its local address
bao-ca:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p .local/openbao/certs
  kubectl get secret openbao-server-cert -n openbao -o jsonpath='{.data.ca\.crt}' | base64 -d > .local/openbao/certs/openbao-internal-ca.crt
  echo "OpenBao API: https://127.0.0.1:8210  UI: https://127.0.0.1:8210/ui/  (CA: .local/openbao/certs/openbao-internal-ca.crt)"

# Open interactive shell in openbao-0 pod
bao-shell:
  kubectl exec -it openbao-0 -n openbao -- sh -c '{{bao_env}}; exec sh'

# --- Database ------------------------------------------------------------

# Open psql in the postgis-cluster primary as the current OpenBao-issued login
db-connect:
  #!/usr/bin/env bash
  set -uo pipefail
  LEASE_USER=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
  LEASE_PASS=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
  DATABASE_NAME=$(kubectl get configmap cluster-config -n flux-system -o jsonpath='{.data.DATA_SCIENCE_DB_NAME}')
  if [ -z "$DATABASE_NAME" ]; then
    echo "Error: DATA_SCIENCE_DB_NAME not found in the live cluster-config ConfigMap." >&2
    exit 1
  fi
  kubectl cnpg psql postgis-cluster -n databases -- "host=localhost dbname=$DATABASE_NAME user=$LEASE_USER password=$LEASE_PASS"

# Trigger a manual base backup of postgis-cluster to SeaweedFS through the Barman Cloud plugin
backup:
  kubectl cnpg backup postgis-cluster -n databases -m plugin --plugin-name barman-cloud.cloudnative-pg.io

# --- Development -------------------------------------------------------

# Setup development environment
setup: install git-setup

# Install dependencies
install:
  {{ if path_exists("uv.lock") == "true" { "uv sync --all-groups --all-extras --locked --inexact" } else { "uv sync --all-groups --all-extras --inexact" } }}

# run test coverage and create
test-cov:
  uv run pytest --cov=src/data_science_cluster --cov-report=lcov:lcov.info --cov-report=term-missing --cov-report html --cov-report xml

# Update packages and lockfile
update:
  uv sync -U --all-groups --all-extras --inexact

# set up pre-commit hooks
git-setup:
  @[ -d .git ] || git init -b main
  uv run prek install
