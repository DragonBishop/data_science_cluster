# In-cluster runtime image.

FROM python:3.14.8-slim

# Source repo; the image's clone seeds a devcontainer's empty workspace volume.
ARG REPOSITORY=DragonBishop/data_science_cluster
ARG REPO_REF=main
ENV REPOSITORY=${REPOSITORY} \
    REPO_REF=${REPO_REF}

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ENV UV_INSTALL_DIR="/usr/local/bin" \
    UV_TOOL_BIN_DIR="/usr/local/bin" \
    UV_TOOL_DIR="/usr/local/share/uv/tools" \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# VS Code CLI, for `code tunnel`.
RUN curl -LsSfo /tmp/vscode_cli.tar.gz \
      "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64" \
 && tar -xzf /tmp/vscode_cli.tar.gz -C /usr/local/bin \
 && rm /tmp/vscode_cli.tar.gz \
 && code --version

RUN useradd -ms /bin/bash vscode \
 && mkdir -p /home/vscode/.vscode-server/data/Machine /home/vscode/.vscode-server/bin \
      /home/vscode/data_science_cluster \
 && chown -R vscode:vscode /home/vscode

USER vscode
WORKDIR /home/vscode/data_science_cluster

# Invalidates the cached clone when REPO_REF moves.
ADD https://api.github.com/repos/${REPOSITORY}/commits/${REPO_REF} /tmp/repo-ref.json
# .venv outside the workspace; the notebook group adds ipykernel for Jupyter.
ENV UV_PROJECT_ENVIRONMENT=/home/vscode/.venv
RUN git clone --branch "${REPO_REF}" "https://github.com/${REPOSITORY}.git" . \
 && uv sync --frozen --no-dev --group notebook
ENV UV_NO_SYNC=1

RUN printf '#!/bin/sh\nset -eu\nif [ -n "${VSCODE_CLI_ACCESS_TOKEN:-}" ]; then\n  code tunnel user login --provider github\nfi\nexec code tunnel --accept-server-license-terms --name "${TUNNEL_NAME:-datasci-k8s-cluster}"\n' > /home/vscode/tunnel-entrypoint.sh \
 && chmod +x /home/vscode/tunnel-entrypoint.sh

ENTRYPOINT ["/home/vscode/tunnel-entrypoint.sh"]
