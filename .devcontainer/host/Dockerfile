# Cluster management image.

FROM python:3.14.8-slim

# Source repo for cluster-config and the workspace clone.
ARG REPOSITORY=DragonBishop/data_science_cluster
ARG REPO_REF=main
ENV REPOSITORY=${REPOSITORY} \
    REPO_REF=${REPO_REF}

# Versions cluster-config doesn't pin; see docs/INSTALLATION.md.
ARG FLUX_VERSION=2.10.0
ARG OPENTOFU_VERSION=1.13.1

# Install prerequisites, plus just, fzf, gnupg, openssl, unzip and sudo.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl just fzf gnupg openssl unzip sudo \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI, from GitHub's apt repo.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && gh --version

ENV UV_INSTALL_DIR="/usr/local/bin" \
    UV_TOOL_BIN_DIR="/usr/local/bin" \
    UV_TOOL_DIR="/usr/local/share/uv/tools" \
    UV_PYTHON_INSTALL_DIR="/usr/local/share/uv/python" \
    UV_LINK_MODE=copy \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# The pinned Python, so container creation doesn't download it.
ADD https://raw.githubusercontent.com/${REPOSITORY}/${REPO_REF}/.python-version /tmp/.python-version
RUN uv python install "$(cat /tmp/.python-version)"

# Versions from cluster-config at REPO_REF, as preflight.sh reads them.
ADD https://raw.githubusercontent.com/${REPOSITORY}/${REPO_REF}/infrastructure/cluster-config/versions.yaml \
    /tmp/cluster-config/versions.yaml
RUN awk '/^  [A-Z0-9_]+: / { key = $1; sub(/:$/, "", key); value = $2; gsub(/"/, "", value); print key "=" value }' \
      /tmp/cluster-config/versions.yaml > /tmp/cluster-config.env

# kubectl at KUBECTL_VERSION.
RUN . /tmp/cluster-config.env \
 && curl -LsSfo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client

# Helm 4.
RUN curl -LsSfo /tmp/get-helm-4 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 \
 && chmod +x /tmp/get-helm-4 \
 && /tmp/get-helm-4 \
 && rm /tmp/get-helm-4 \
 && helm version

# cnpg plugin, matching the operator (CNPG_VERSION's appVersion).
RUN . /tmp/cluster-config.env \
 && CNPG_PLUGIN_VERSION=$(helm show chart cloudnative-pg --repo https://cloudnative-pg.github.io/charts \
      --version "${CNPG_VERSION}" | awk '/^appVersion:/ {print $2}') \
 && curl -LsSfo /tmp/kubectl-cnpg.deb \
      "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_PLUGIN_VERSION}/kubectl-cnpg_${CNPG_PLUGIN_VERSION}_linux_x86_64.deb" \
 && apt-get update && apt-get install -y --no-install-recommends /tmp/kubectl-cnpg.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/kubectl-cnpg.deb \
 && kubectl cnpg version

# Cilium CLI.
RUN CILIUM_CLI_VERSION=$(curl -LsSf https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt) \
 && curl -LsSfo /tmp/cilium-linux-amd64.tar.gz \
      "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
 && tar -xzf /tmp/cilium-linux-amd64.tar.gz -C /usr/local/bin \
 && rm /tmp/cilium-linux-amd64.tar.gz \
 && cilium version --client

# Flux CLI, matching gotk-components.yaml.
RUN curl -s https://fluxcd.io/install.sh | FLUX_VERSION=${FLUX_VERSION} bash \
 && flux version --client

# OpenTofu, standalone.
RUN curl --proto '=https' --tlsv1.2 -fsSLo /tmp/install-opentofu.sh https://get.opentofu.org/install-opentofu.sh \
 && chmod +x /tmp/install-opentofu.sh \
 && /tmp/install-opentofu.sh --install-method standalone --opentofu-version ${OPENTOFU_VERSION} \
 && rm /tmp/install-opentofu.sh \
 && tofu version

# vscode user, passwordless sudo, and its directories.
RUN useradd -ms /bin/bash -G sudo vscode \
 && echo 'vscode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vscode-nopasswd \
 && chmod 440 /etc/sudoers.d/vscode-nopasswd \
 && visudo -cf /etc/sudoers.d/vscode-nopasswd \
 && mkdir -p /home/vscode/.vscode-server/data/Machine /home/vscode/.vscode-server/bin \
      /home/vscode/data_science_cluster \
 && chown -R vscode:vscode /home/vscode

USER vscode
WORKDIR /home/vscode/data_science_cluster
