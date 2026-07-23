#!/bin/bash
#
# sync-kubeconfig.sh
# Copies the live k3s kubeconfig to ~/.kube/config on WSL
# (bind-mount source for devcontainers).
#
# Requires re-execution after any cluster rebuild to maintain synchronization.
set -euo pipefail

SOURCE_CONFIG="/etc/rancher/k3s/k3s.yaml"
WSL_DEST="$HOME/.kube/config"

echo -e "\n🔄 Starting kubeconfig sync..."

# --- Step 1: Verify source configuration exists -----------------------------
if [ ! -f "$SOURCE_CONFIG" ]; then
    echo -e "❌ Error: Source config not found at $SOURCE_CONFIG."
    echo -e "   Ensure k3s is installed and actively running."
    exit 1
fi

# --- Step 2: Validate destination is a regular file --------------------------
# Prevents silent failures caused by symlinks or erroneous directory creation
# from container engine bind mounts.
if [ -L "$WSL_DEST" ]; then
    echo -e "❌ Error: $WSL_DEST is a symlink."
    echo -e "   Destination must be a regular file. Execute: rm \"$WSL_DEST\""
    exit 1
fi
if [ -e "$WSL_DEST" ] && [ ! -f "$WSL_DEST" ]; then
    echo -e "❌ Error: $WSL_DEST exists but is not a regular file."
    echo -e "   Execute: sudo rm -rf \"$WSL_DEST\""
    exit 1
fi

# --- Step 3: Ensure destination directory exists -----------------------------
mkdir -p "$(dirname "$WSL_DEST")"

# --- Step 4: Write WSL copy ---------------------------------------------------
# Modifies ownership to the executing user to allow unprivileged access.
# Leaves 127.0.0.1 intact — the devcontainer runs with --network=host,
# so it shares the WSL loopback with the k3s API server.
echo "📋 Copying config to WSL path ($WSL_DEST)..."
sudo cp "$SOURCE_CONFIG" "$WSL_DEST"
sudo chown "$(id -u):$(id -g)" "$WSL_DEST"
chmod 600 "$WSL_DEST"

echo -e "✅ Success! Kubeconfig is synchronized with the live cluster.\n"