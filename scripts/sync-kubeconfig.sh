#!/bin/bash
#
# sync-kubeconfig.sh
# Copies the live k3s kubeconfig to ~/.kube/config, owned by and readable
# only by the invoking user. k3s writes its kubeconfig to a system path
# (mode 644, but root-owned); most kubectl/Helm/devcontainer tooling expects
# ~/.kube/config instead, so this keeps the two in sync.
#
# Requires re-execution after any cluster rebuild to maintain synchronization.

set -euo pipefail

SOURCE_CONFIG="/etc/rancher/k3s/k3s.yaml"
DEST="$HOME/.kube/config"

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
if [ -L "$DEST" ]; then
    echo -e "❌ Error: $DEST is a symlink."
    echo -e "   Destination must be a regular file. Execute: rm \"$DEST\""
    exit 1
fi
if [ -e "$DEST" ] && [ ! -f "$DEST" ]; then
    echo -e "❌ Error: $DEST exists but is not a regular file."
    echo -e "   Execute: sudo rm -rf \"$DEST\""
    exit 1
fi

# --- Step 3: Ensure destination directory exists -----------------------------
mkdir -p "$(dirname "$DEST")"

# --- Step 4: Write the copy ---------------------------------------------------
# Modifies ownership to the executing user to allow unprivileged access.
# Leaves 127.0.0.1 intact — the devcontainer runs with --network=host, so it
# shares the host's loopback interface with the k3s API server directly.
echo "📋 Copying config to $DEST..."
sudo cp "$SOURCE_CONFIG" "$DEST"
sudo chown "$(id -u):$(id -g)" "$DEST"
chmod 600 "$DEST"

echo -e "✅ Success! Kubeconfig is synchronized with the live cluster.\n"
