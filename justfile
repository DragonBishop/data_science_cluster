module_name := "clusterpgis"

# list commands
default:
  @just --list

# install the packages
install:
  {{if path_exists("uv.lock") != "true" {"uv sync --all-groups --all-extras --inexact"} else {"uv sync --all-groups --all-extras --locked --inexact"} }}

# setup for development
setup: install git-setup

# run test coverage and create
test-cov:
  uv run pytest --cov=src/clusterpgis --cov-report=lcov:lcov.info --cov-report=term-missing --cov-report html --cov-report xml

# update packages and uv lock file
update:
  uv sync -U --all-groups --all-extras --inexact

# set up the nbwipers git filter so notebooks stay clean on commit
git-setup: install
  @if [ ! -d .git ]; then git init; fi
  uv run nbwipers install local

# start a long-lived port-forward to hubble-relay on localhost:4245; run this once in its own terminal and `just hubble ...` will reuse it
hubble-pf:
  kubectl port-forward -n kube-system svc/hubble-relay 4245:443

# run a hubble CLI command against hubble-relay (e.g. `just hubble status`, `just hubble observe --follow`); reuses an existing `just hubble-pf` if one is listening on 4245, else starts a short-lived one for this call only
hubble *ARGS='status':
  #!/usr/bin/env bash
  set -uo pipefail
  mkdir -p ~/.hubble/tls
  [ -f ~/.hubble/tls/ca.crt ]  || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.ca\.crt}'  | base64 -d > ~/.hubble/tls/ca.crt
  [ -f ~/.hubble/tls/tls.crt ] || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.hubble/tls/tls.crt
  [ -f ~/.hubble/tls/tls.key ] || kubectl get secret -n kube-system hubble-relay-client-certs -o jsonpath='{.data.tls\.key}' | base64 -d > ~/.hubble/tls/tls.key

  pf_pid=""
  logf=""
  if ! (exec 3<>/dev/tcp/127.0.0.1/4245) 2>/dev/null; then
    logf=$(mktemp)
    kubectl port-forward -n kube-system svc/hubble-relay 4245:443 >"$logf" 2>&1 &
    pf_pid=$!
    trap 'ec=$?; [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null; [ -n "$logf" ] && rm -f "$logf"; exit $ec' EXIT
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

# open the Hubble web UI: starts a background port-forward to localhost:12000 (reused across calls) and opens the browser
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
  disown 2>/dev/null || true

# open an interactive shell in vault-0 with VAULT_ADDR set and the inherited transit-unseal VAULT_TOKEN unset, ready for `vault login` or any other vault command
vault-shell:
  kubectl exec -it vault-0 -n vault -- sh -c 'export VAULT_ADDR=http://127.0.0.1:8200; unset VAULT_TOKEN; exec sh'

# same setup as `just vault-shell`, then runs `vault login`; the token prompt is vault's own masked stdin read, never a command argument or echoed value; drops into the shell already authenticated
vault-login:
  kubectl exec -it vault-0 -n vault -- sh -c 'export VAULT_ADDR=http://127.0.0.1:8200; unset VAULT_TOKEN; vault login && exec sh'