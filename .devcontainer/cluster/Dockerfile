# In-cluster ETL/pipeline runtime image for this repo.

FROM python:3.14-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

ENV UV_INSTALL_DIR="/usr/local/bin" \
    UV_TOOL_BIN_DIR="/usr/local/bin" \
    UV_TOOL_DIR="/usr/local/share/uv/tools" \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# VS Code CLI, tunnel-capable (`code tunnel`).
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

COPY --chown=vscode:vscode pyproject.toml uv.lock README.md ./
COPY --chown=vscode:vscode src/ src/
RUN uv sync --frozen --no-dev
ENV UV_NO_SYNC=1

RUN printf '#!/bin/sh\nset -eu\nif [ -n "${VSCODE_CLI_ACCESS_TOKEN:-}" ]; then\n  code tunnel user login --provider github\nfi\nexec code tunnel --accept-server-license-terms --name "${TUNNEL_NAME:-datasci-k8s-cluster}"\n' > /home/vscode/tunnel-entrypoint.sh \
 && chmod +x /home/vscode/tunnel-entrypoint.sh

ENTRYPOINT ["/home/vscode/tunnel-entrypoint.sh"]
