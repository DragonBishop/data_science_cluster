# Data Science DevContainer
#
# Base tools shared across all projects:
# - Python 3.14
# - uv
# - kubectl
# - Helm
# - Cilium CLI
# - DuckDB CLI
# - Quarto
# - Copier
#
# Project-specific Python libraries belong in each repository's pyproject.toml.

# Start from the official minimal Python 3.14 Debian image.
FROM python:3.14-slim

# Install common Linux utilities and development libraries.
# build-essential and libpq-dev are needed when compiling some Python packages.
# Remove apt metadata afterward to reduce image size.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl unzip jq sudo \
    build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*

# Install uv system-wide so the non-root vscode user can reach it
# And be reached after the container's build.
ENV UV_INSTALL_DIR="/usr/local/bin" \
    UV_TOOL_BIN_DIR="/usr/local/bin" \
    UV_TOOL_DIR="/usr/local/share/uv/tools"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Install the latest stable kubectl. The devcontainer mounts your kubeconfig, 
# giving kubectl the same cluster access that your host machine has.
# version --client command validates the installation.
RUN curl -LsSfo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client

# Download and execute the official Helm installation script.
# This step must run as root (prior to any USER switch) to grant 
# the script necessary write permissions to /usr/local/bin.
#
# The final `helm version` command validates the installation, 
# ensuring the Docker build fails immediately if the script 
# exits cleanly but fails to install the binary.
RUN curl -LsSfo /tmp/get-helm-3 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
 && chmod +x /tmp/get-helm-3 \
 && /tmp/get-helm-3 \
 && rm /tmp/get-helm-3 \
 && helm version

# Install the Cilium CLI to enable direct interaction with the Cilium agent 
# (e.g., Hubble flow visibility) from within the container.
#
# The `cilium version --client` command validates the installation, and the `--client`
# flag is used to bypass the  need for cluster connectivity, which is unavailable during the build stage.
RUN CILIUM_CLI_VERSION=$(curl -LsSf https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt) \
 && curl -LsSfo /tmp/cilium-linux-amd64.tar.gz \
      "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
 && tar -xzf /tmp/cilium-linux-amd64.tar.gz -C /usr/local/bin \
 && rm /tmp/cilium-linux-amd64.tar.gz \
 && cilium version --client

# Install the DuckDB command-line interface.
RUN curl -LsSfo /tmp/duckdb.zip https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip \
 && unzip -q /tmp/duckdb.zip -d /usr/local/bin \
 && rm /tmp/duckdb.zip

# Install Quarto. Keeping the version in an ARG makes upgrades easier.
ARG QUARTO_VERSION=1.4.555
RUN curl -LsSfo /tmp/quarto.deb https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb \
 && apt-get update \
 && apt-get install -y /tmp/quarto.deb \
 && rm /tmp/quarto.deb

# Install Copier and Cookiecutter as tools to share across projects.
RUN uv tool install copier \
&& uv tool install cookiecutter

# Create a non-root user for development, add it to the sudo group, and
# grant it passwordless sudo. Fine for local development, not suitable
# for production.
RUN useradd -ms /bin/bash vscode \
 && usermod -aG sudo vscode \
 && echo 'vscode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vscode-nopasswd \
 && chmod 440 /etc/sudoers.d/vscode-nopasswd \
 && visudo -cf /etc/sudoers.d/vscode-nopasswd

# Switch to the non-root user and set the default working directory.
USER vscode
WORKDIR /home/vscode/coding