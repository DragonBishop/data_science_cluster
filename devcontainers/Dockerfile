# ==============================================================================
# Kubernetes & Data Science Foundation - Dockerfile
# ==============================================================================
# Base tools pre-installed for infrastructure management and analytics:
# - Python
# - uv (Modern Python package manager)
# - kubectl & Helm (Cluster management)
# - cnpg plugin (CloudNativePG status, backups, and psql access)
# - Cilium CLI (Network visibility)
# - PostgreSQL Client (Database access)
# - DuckDB CLI & Quarto (Data analytics & publishing)
#
# NOTE: Project-specific Python libraries do not belong here. 
# Manage them via `uv init`, `uv add`, and `uv sync` in your pyproject.toml.
# ==============================================================================

# Start from the official Dev Container Python image.
# This automatically handles the 'vscode' user, passwordless sudo, Git, curl, 
# build-essential, and proper UID/GID mapping out of the box.
FROM mcr.microsoft.com/devcontainers/python:3

# ------------------------------------------------------------------------------
# 1. System Utilities
# ------------------------------------------------------------------------------
# postgresql-client: Native interaction with local DB bridges.
# unzip: Required by the DuckDB CLI install below, which ships as a zip archive.
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    unzip \
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

# Registers as a kubectl subcommand by filename: `kubectl cnpg status`,
# `kubectl cnpg backup`, and `kubectl cnpg psql` resolve to kubectl-cnpg on PATH.
RUN curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh \
      | sh -s -- -b /usr/local/bin \
 && kubectl cnpg version

# ------------------------------------------------------------------------------
# 4. Networking Visibility (Cilium CLI)
# ------------------------------------------------------------------------------
RUN CILIUM_CLI_VERSION=$(curl -LsSf https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt) \
 && curl -LsSfo /tmp/cilium-linux-amd64.tar.gz \
      "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
 && tar -xzf /tmp/cilium-linux-amd64.tar.gz -C /usr/local/bin \
 && rm /tmp/cilium-linux-amd64.tar.gz \
 && cilium version --client

# ------------------------------------------------------------------------------
# 5. Data Analytics & Publishing Tools (DuckDB & Quarto)
# ------------------------------------------------------------------------------
RUN curl -LsSfo /tmp/duckdb.zip https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip \
 && unzip -q /tmp/duckdb.zip -d /usr/local/bin \
 && rm /tmp/duckdb.zip

ARG QUARTO_VERSION=1.4.555
RUN curl -LsSfo /tmp/quarto.deb https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb \
 && apt-get update \
 && apt-get install -y /tmp/quarto.deb \
 && rm /tmp/quarto.deb