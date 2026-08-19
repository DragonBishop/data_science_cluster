# ==============================================================================
# Kubernetes & Data Science Foundation - Dockerfile
# ==============================================================================
# Base tools installed:
# - Python
# - uv (Python package manager)
# - just (Command runner for repository tasks)
# - kubectl & Helm (Cluster management)
# - cnpg plugin (CloudNativePG CLI plugin)
# - Cilium CLI & Hubble CLI (Network management and observability)
# - Flux CLI (GitOps reconciliation)
# - PostgreSQL Client (Database connectivity)
#
# Manage project-specific Python dependencies via pyproject.toml using uv.
# ==============================================================================

# Start from the official Dev Container Python image.
# This automatically handles the 'vscode' user, passwordless sudo, Git, curl, 
# build-essential, and proper UID/GID mapping out of the box.
FROM mcr.microsoft.com/devcontainers/python:3

# ------------------------------------------------------------------------------
# 1. System Utilities
# ------------------------------------------------------------------------------
# postgresql-client: Database CLI utilities.
# just: Command runner.
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    just \
 && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# 2. Python Tooling (uv)
# ------------------------------------------------------------------------------
ENV UV_INSTALL_DIR="/usr/local/bin" \
    UV_TOOL_BIN_DIR="/usr/local/bin" \
    UV_TOOL_DIR="/usr/local/share/uv/tools"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# ------------------------------------------------------------------------------
# 3. Cluster Management (kubectl, Helm & the cnpg plugin)
# ------------------------------------------------------------------------------
RUN curl -LsSfo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client

RUN curl -LsSfo /tmp/get-helm-3 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
 && chmod +x /tmp/get-helm-3 \
 && /tmp/get-helm-3 \
 && rm /tmp/get-helm-3 \
 && helm version

# CloudNativePG kubectl plugin
RUN curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh \
      | sh -s -- -b /usr/local/bin \
 && kubectl cnpg version

# ------------------------------------------------------------------------------
# 4. Networking Visibility (Cilium CLI & Hubble CLI)
# ------------------------------------------------------------------------------
RUN CILIUM_CLI_VERSION=$(curl -LsSf https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt) \
 && curl -LsSfo /tmp/cilium-linux-amd64.tar.gz \
      "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
 && tar -xzf /tmp/cilium-linux-amd64.tar.gz -C /usr/local/bin \
 && rm /tmp/cilium-linux-amd64.tar.gz \
 && cilium version --client

# Hubble CLI client
RUN HUBBLE_VERSION=$(curl -LsSf https://raw.githubusercontent.com/cilium/hubble/master/stable.txt) \
 && curl -LsSfo /tmp/hubble-linux-amd64.tar.gz \
      "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-amd64.tar.gz" \
 && tar -xzf /tmp/hubble-linux-amd64.tar.gz -C /usr/local/bin \
 && rm /tmp/hubble-linux-amd64.tar.gz \
 && hubble version

# ------------------------------------------------------------------------------
# 5. GitOps (Flux CLI)
# ------------------------------------------------------------------------------
RUN curl -s https://fluxcd.io/install.sh | bash \
 && flux version --client