# List available recipes
default:
  @just --list

# --- Bootstrap (first-time install, see docs/INSTALLATION.md) --------------

# Configure the host firewall for Kubernetes and Cilium
setup-firewall:
  ./src/bash/setup-firewall.sh

# Read-only host readiness check (tooling, gh auth, firewall, reserved IPs)
preflight:
  ./src/bash/preflight.sh

# Bootstrap with Ansible (prompts for sudo; accepts playbook flags)
bootstrap *ARGS:
  uv run ansible-galaxy collection install --upgrade -p ansible ansible/ansible_collections/dragonbishop/cluster
  uv run ansible-playbook dragonbishop.cluster.data_cluster --ask-become-pass {{ARGS}}

# Trust the cluster's CAs and resolve its Gateway hostnames on this machine
workstation-trust *ARGS:
  uv run ansible-galaxy collection install --upgrade -p ansible ansible/ansible_collections/dragonbishop/cluster
  uv run ansible-playbook dragonbishop.cluster.workstation_trust --ask-become-pass {{ARGS}}

# --- Cluster lifecycle -------------------------------------------------

# Start the cluster
start:
  ./src/bash/start-cluster.sh

# Show Flux readiness, alerts, scrape failures and database status
status:
  #!/usr/bin/env bash
  set -uo pipefail
  # Alertmanager and Prometheus through the API server's service proxy
  proxy=/api/v1/namespaces/observability/services
  echo "== Flux Kustomizations not Ready =="
  flux get kustomizations --status-selector ready=false

  echo ""
  echo "== Firing alerts (Watchdog and InfoInhibitor always fire) =="
  kubectl get --raw "$proxy/https:kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?active=true&silenced=false&inhibited=false" \
    | jq -r '.[] | select(.labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")
        | "\(.labels.severity // "-")\t\(.labels.alertname)\t\(.labels.namespace // "-")\t\(.annotations.summary // .annotations.description // "")"'

  echo ""
  echo "== Prometheus scrape targets not up =="
  kubectl get --raw "$proxy/https:kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets?state=active" \
    | jq -r '.data.activeTargets[] | select(.health != "up") | "\(.labels.job)\t\(.health)\t\(.lastError)"'

  echo ""
  echo "== Database =="
  kubectl cnpg status postgres-cluster -n databases

# Run core-test, follow its logs, and return its result
core-test:
  #!/usr/bin/env bash
  set -euo pipefail
  run_name=$(kubectl create -f infrastructure/tekton/pipelines/core-test/core-test-run.yaml -o jsonpath='{.metadata.name}')
  echo "PipelineRun $run_name"
  tkn pipelinerun logs "$run_name" -n tekton-pipelines --follow
  succeeded=$(kubectl get pipelinerun "$run_name" -n tekton-pipelines -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}')
  [[ $succeeded == True ]]

# Stop the cluster (--force stops k3s even when hibernation isn't confirmed)
stop *ARGS:
  ./src/bash/stop-cluster.sh {{ARGS}}

# Uninstall k3s and clear stale local cluster state (sudo required)
uninstall:
  ./src/bash/uninstall-cluster.sh

# Fuzzy-select a pod (all namespaces) and describe it
fuzzypods:
  kubectl get pods -A --no-headers | fzf | awk '{print "-n", $1, $2}' | xargs kubectl describe pod

# Run a Hubble CLI command inside the Cilium agent (defaults to status)
[positional-arguments]
hubble *ARGS='status':
  kubectl exec -n kube-system ds/cilium -c cilium-agent -- hubble "$@"

# Open hubble, tekton, openbao or grafana and print its URL
ui NAME:
  #!/usr/bin/env bash
  set -euo pipefail
  # Ports match the localhost redirect policies; Grafana goes through the Gateway
  case "{{NAME}}" in
    hubble) url="https://localhost:12000/" ;;
    tekton) url="https://localhost:12001/" ;;
    openbao) url="https://localhost:8210/ui/" ;;
    grafana) url="https://grafana.$(kubectl get configmap cluster-config -n flux-system -o jsonpath='{.data.INTERNAL_DOMAIN}')/" ;;
    *) echo "Unknown UI {{NAME}}: use hubble, tekton, openbao or grafana." >&2; exit 2 ;;
  esac
  echo "$url"
  if command -v xdg-open >/dev/null; then
    xdg-open "$url"
  fi

# Open a shell in openbao-0; pass --login to authenticate first
[positional-arguments]
bao-shell OPTION='':
  #!/bin/sh
  case "${1:-}" in
    ''|--login) ;;
    *) echo 'Usage: just bao-shell [--login]' >&2; exit 2 ;;
  esac
  kubectl exec -it openbao-0 -n openbao -- sh -c '
    unset BAO_TOKEN
    if [ "$1" = --login ]; then
      BAO_TOKEN=$(bao login -token-only) || exit
      export BAO_TOKEN
    fi
    exec sh
  ' sh "${1:-}"

# --- Database ------------------------------------------------------------

# Back up PostgreSQL to SeaweedFS with Barman Cloud
backup:
  kubectl cnpg backup postgres-cluster -n databases -m plugin --plugin-name barman-cloud.cloudnative-pg.io

# --- Development -------------------------------------------------------

# Setup development environment
setup: install git-setup

# Install dependencies
install:
  {{ if path_exists("uv.lock") == "true" { "uv sync --all-groups --all-extras --locked --inexact" } else { "uv sync --all-groups --all-extras --inexact" } }}

# Update packages and lockfile
update:
  uv sync -U --all-groups --all-extras --inexact

# set up pre-commit hooks
git-setup:
  @[ -d .git ] || git init -b main
  uv run prek install
