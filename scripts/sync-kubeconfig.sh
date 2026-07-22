#!/bin/bash
#
# sync-kubeconfig.sh
# Copies the live k3s kubeconfig to two independent destinations:
# 1. ~/.kube/config on WSL (bind-mount source for devcontainers).
# 2. Windows-side path (for Windows-native applications).
#
# Requires re-execution after any cluster rebuild to maintain synchronization.

set -euo pipefail

SOURCE_CONFIG="/etc/rancher/k3s/k3s.yaml"
WSL_DEST="$HOME/.kube/config"
WINDOWS_DEST="/mnt/c/Users/benco/.kube/config"

echo -e "\n🔄 Starting kubeconfig sync..."

# --- Step 1: Verify source configuration exists -----------------------------
if [ ! -f "$SOURCE_CONFIG" ]; then
    echo -e "❌ Error: Source config not found at $SOURCE_CONFIG."
    echo -e "   Ensure k3s is installed and actively running."
    exit 1
fi

# --- Step 2: Validate destinations are regular files ------------------------
# Prevents silent failures caused by symlinks or erroneous directory creation
# from container engine bind mounts.
for dest in "$WSL_DEST" "$WINDOWS_DEST"; do
    if [ -L "$dest" ]; then
        echo -e "❌ Error: $dest is a symlink."
        echo -e "   Destination must be a regular file. Execute: rm \"$dest\""
        exit 1
    fi
    if [ -e "$dest" ] && [ ! -f "$dest" ]; then
        echo -e "❌ Error: $dest exists but is not a regular file."
        echo -e "   Execute: sudo rm -rf \"$dest\""
        exit 1
    fi
done

# --- Step 3: Ensure destination directories exist ---------------------------
mkdir -p "$(dirname "$WSL_DEST")"
mkdir -p "$(dirname "$WINDOWS_DEST")"

# --- Step 4: Write WSL copy -------------------------------------------------
# Modifies ownership to the executing user to allow unprivileged access.
echo "📋 Copying config to WSL path ($WSL_DEST)..."
sudo cp "$SOURCE_CONFIG" "$WSL_DEST"
sudo chown "$(id -u):$(id -g)" "$WSL_DEST"
chmod 600 "$WSL_DEST"

# --- Step 5: Write Windows copy ---------------------------------------------
# Skips chown/chmod operations, as drvfs mounts do not utilize Linux permissions.
echo "📋 Copying config to Windows path ($WINDOWS_DEST)..."
sudo cp "$SOURCE_CONFIG" "$WINDOWS_DEST"

echo -e "✅ Success! Kubeconfig copies are synchronized with the live cluster.\n"