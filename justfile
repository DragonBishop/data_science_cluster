module_name := "clusterpgis"

# List available recipes
default:
  @just --list

# --- Bootstrap (first-time install, see INSTALLATION.md) -------------------

# Read-only host readiness check (tooling, gh auth, firewall, reserved IPs)
preflight:
  ./src/bash/preflight.sh

# Run the full first-time cluster bootstrap
bootstrap:
  ./src/bash/bootstrap-cluster.sh

# --- Cluster lifecycle -------------------------------------------------

# Start the cluster
start:
  ./src/bash/start-cluster.sh

# Stop the cluster (pass --force to skip confirmation on a stuck stop)
stop *ARGS:
  ./src/bash/stop-cluster.sh {{ARGS}}

# Fuzzy-select a pod (all namespaces) and describe it
fuzzypods:
  kubectl get pods -A --no-headers | fzf | awk '{print $2, $1}' | xargs -n 2 sh -c 'kubectl describe pod $0 -n $1'

# Read-only cluster health check (Flux, Gateway/DNS, cert-manager, database, backups, Hubble)
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
  kubectl get clusterissuer vault-pki-issuer

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
  kubectl get pods -n kube-system -l 'k8s-app in (hubble-relay,hubble-ui)'
  echo -n "HTTPRoute: "; kubectl get httproute -n kube-system hubble-ui -o jsonpath='{.status.parents[*].conditions[*].message}'; echo

# --- Database ------------------------------------------------------------

# Connect via psql to postgis-cluster (HOST defaults to the live Gateway IP; pass `localhost` for the node-local path)
db-connect HOST=`kubectl get gateway -n gateway internal-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null`:
  #!/usr/bin/env bash
  set -uo pipefail
  LEASE_USER=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.username}' | base64 -d)
  LEASE_PASS=$(kubectl get secret -n databases postgis-app-dynamic-credentials -o jsonpath='{.data.password}' | base64 -d)
  mkdir -p ~/.postgresql
  [ -f ~/.postgresql/root.crt ] || kubectl get secret postgis-server-cert -n databases -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.postgresql/root.crt
  PGPASSWORD="$LEASE_PASS" psql "host={{HOST}} port=5432 dbname=data_science user=$LEASE_USER sslmode=verify-full"

# --- Observability (Hubble) -----------------------------------------------

# Port-forward to hubble-relay on localhost:4245
hubble-pf:
  kubectl port-forward -n kube-system svc/hubble-relay 4245:443

# Run Hubble CLI command against hubble-relay
hubble *ARGS='status':
  #!/usr/bin/env bash
  set -uo pipefail
  mkdir -p ~/.hubble/tls
  [ -f ~/.hubble/tls/ca.crt ]  || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.ca\.crt}'  | base64 -d > ~/.hubble/tls/ca.crt
  [ -f ~/.hubble/tls/tls.crt ] || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.hubble/tls/tls.crt
  [ -f ~/.hubble/tls/tls.key ] || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.tls\.key}' | base64 -d > ~/.hubble/tls/tls.key

  if ! (exec 3<>/dev/tcp/127.0.0.1/4245) 2>/dev/null; then
    logf=$(mktemp)
    kubectl port-forward -n kube-system svc/hubble-relay 4245:443 >"$logf" 2>&1 &
    pf_pid=$!
    trap 'ec=$?; kill "$pf_pid" 2>/dev/null; rm -f "$logf"; exit $ec' EXIT
    for _ in $(seq 1 50); do grep -q "Forwarding from" "$logf" && break; sleep 0.1; done
  else
    exec 3<&- 3>&-
  fi

  hubble --server localhost:4245 --tls \
    --tls-server-name relay.hubble-relay.cilium.io \
    --tls-ca-cert-files ~/.hubble/tls/ca.crt \
    --tls-client-cert-file ~/.hubble/tls/tls.crt \
    --tls-client-key-file ~/.hubble/tls/tls.key \
    {{ARGS}} 2> >(grep -v --line-buffered "Hubble CLI version is lower than Hubble Relay" >&2)

# Open Hubble web UI
hubble-ui:
  #!/usr/bin/env bash
  set -uo pipefail
  mkdir -p ~/.hubble
  if ! (exec 3<>/dev/tcp/127.0.0.1/12000) 2>/dev/null; then
    nohup kubectl port-forward -n kube-system svc/hubble-ui 12000:80 >~/.hubble/ui-portforward.log 2>&1 &
    disown
    for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/12000) 2>/dev/null && break; sleep 0.1; done
  else
    exec 3<&- 3>&-
  fi
  echo "Hubble UI: http://localhost:12000"
  command -v xdg-open >/dev/null 2>&1 && xdg-open http://localhost:12000 >/dev/null 2>&1 &
  disown

# --- Vault -----------------------------------------------------------------

vault_env := "unset VAULT_TOKEN"

# Port-forward in-cluster Vault to localhost:8210 and fetch its CA
vault-pf:
  #!/usr/bin/env bash
  set -uo pipefail
  mkdir -p ~/.vault-certs
  [ -f ~/.vault-certs/vault-internal-ca.crt ] || kubectl get secret vault-server-cert -n vault -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/.vault-certs/vault-internal-ca.crt
  if ! (exec 3<>/dev/tcp/127.0.0.1/8210) 2>/dev/null; then
    nohup kubectl port-forward -n vault vault-0 8210:8200 >~/.vault-certs/pf.log 2>&1 &
    disown
    for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/8210) 2>/dev/null && break; sleep 0.1; done
  else
    exec 3<&- 3>&-
  fi
  echo "Vault (in-cluster): https://127.0.0.1:8210  (CA: ~/.vault-certs/vault-internal-ca.crt)"

# Open interactive shell in vault-0 pod
vault-shell:
  kubectl exec -it vault-0 -n vault -- sh -c '{{vault_env}}; exec sh'

# --- Development -------------------------------------------------------

# Install dependencies
install:
  {{ if path_exists("uv.lock") == "true" { "uv sync --all-groups --all-extras --locked --inexact" } else { "uv sync --all-groups --all-extras --inexact" } }}

# Setup development environment
setup: install git-setup

# Run tests and generate coverage reports
test-cov:
  uv run pytest --cov=src/clusterpgis --cov-report=lcov:lcov.info --cov-report=term-missing --cov-report html --cov-report xml

# Update packages and lockfile
update:
  uv sync -U --all-groups --all-extras --inexact

# set up the nbwipers git filter so notebooks stay clean on commit
git-setup:
  @[ -d .git ] || git init
  uv run nbwipers install local
