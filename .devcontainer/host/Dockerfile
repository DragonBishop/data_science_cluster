# Host devcontainer image for this repo.

FROM python:3.14.7-slim

# git/ca-certificates/curl for the installs below; postgresql-client for
# interactive database access; just, this repo's command runner; sudo for
# the passwordless vscode user setup further down.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl postgresql-client just sudo \
 && rm -rf /var/lib/apt/lists/*

ENV UV_INSTALL_DIR="/usr/local/bin" \
    UV_TOOL_BIN_DIR="/usr/local/bin" \
    UV_TOOL_DIR="/usr/local/share/uv/tools" \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

RUN useradd -ms /bin/bash vscode

# kubectl.
RUN curl -LsSfo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client

# Helm.
RUN curl -LsSfo /tmp/get-helm-3 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
 && chmod +x /tmp/get-helm-3 \
 && /tmp/get-helm-3 \
 && rm /tmp/get-helm-3 \
 && helm version

# cnpg plugin — `kubectl cnpg status`/`backup`/`psql`. Requires kubectl above.
RUN curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh \
      | sh -s -- -b /usr/local/bin \
 && kubectl cnpg version

# Cilium CLI.
RUN CILIUM_CLI_VERSION=$(curl -LsSf https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt) \
 && curl -LsSfo /tmp/cilium-linux-amd64.tar.gz \
      "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
 && tar -xzf /tmp/cilium-linux-amd64.tar.gz -C /usr/local/bin \
 && rm /tmp/cilium-linux-amd64.tar.gz \
 && cilium version --client

# Hubble CLI — separate binary from the Cilium CLI above.
RUN HUBBLE_VERSION=$(curl -LsSf https://raw.githubusercontent.com/cilium/hubble/master/stable.txt) \
 && curl -LsSfo /tmp/hubble-linux-amd64.tar.gz \
      "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-amd64.tar.gz" \
 && tar -xzf /tmp/hubble-linux-amd64.tar.gz -C /usr/local/bin \
 && rm /tmp/hubble-linux-amd64.tar.gz \
 && hubble version

# Flux CLI.
RUN curl -s https://fluxcd.io/install.sh | bash \
 && flux version --client

# Passwordless sudo and VS Code Server directories, for interactive use.
RUN usermod -aG sudo vscode \
 && echo 'vscode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vscode-nopasswd \
 && chmod 440 /etc/sudoers.d/vscode-nopasswd \
 && visudo -cf /etc/sudoers.d/vscode-nopasswd \
 && mkdir -p /home/vscode/.vscode-server/data/Machine /home/vscode/.vscode-server/bin \
      /home/vscode/data_science_cluster \
 && chown -R vscode:vscode /home/vscode

USER vscode
WORKDIR /home/vscode/data_science_cluster
