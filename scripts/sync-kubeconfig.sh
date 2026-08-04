#!/bin/bash
#
# sync-kubeconfig.sh
# Copies /etc/rancher/k3s/k3s.yaml to ~/.kube/config, owned by the invoking
# user and mode 600. The source file is root-owned; kubectl, Helm and the
# devcontainer read ~/.kube/config.
#
# The copy is a snapshot. Re-run after a cluster rebuild.

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
# A symlink or directory at $DEST is rejected rather than written through or
# into. Container engine bind mounts can create a directory at this path.
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
# The server address in the copied file is left as written by k3s
# (https://127.0.0.1:6443). The devcontainer runs with --network=host and
# reaches the API server on that address.
echo "📋 Copying config to $DEST..."
sudo cp "$SOURCE_CONFIG" "$DEST"
sudo chown "$(id -u):$(id -g)" "$DEST"
chmod 600 "$DEST"

echo -e "✅ Success! Kubeconfig is synchronized with the live cluster.\n"