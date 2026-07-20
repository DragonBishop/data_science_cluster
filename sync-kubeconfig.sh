#!/bin/bash
#
# sync-kubeconfig.sh — copies the live k3s kubeconfig to the user's default
# kubectl location, so tools like Headlamp/kubectl work without sudo.
#

SOURCE_CONFIG="/etc/rancher/k3s/k3s.yaml"
DEST_DIR="$HOME/.kube"
DEST_CONFIG="$DEST_DIR/config"

echo -e "\n🔄 Starting kubeconfig sync..."


# --- Step 1: Confirm the source file exists ---------------------------------
# k3s only writes this file while the server is running. Its absence means
# k3s either isn't installed or isn't currently up.
if [ ! -f "$SOURCE_CONFIG" ]; then
    echo -e "❌ Error: Source config not found at $SOURCE_CONFIG."
    echo -e "   Ensure k3s is installed and currently running."
    exit 1
fi


# --- Step 2: Ensure the destination directory exists ------------------------
mkdir -p "$DEST_DIR"


# --- Step 3: Copy the config --------------------------------------------------
# The source file is root-owned, so sudo is required to read it.
echo "📋 Copying config from $SOURCE_CONFIG..."
sudo cp "$SOURCE_CONFIG" "$DEST_CONFIG"


# --- Step 4: Hand ownership to the current user -----------------------------
# Without this, the copied file stays root-owned and kubectl/Headlamp can't
# read it without sudo.
echo "🔐 Updating ownership and permissions for user: $USER..."
sudo chown "$(id -u):$(id -g)" "$DEST_CONFIG"

echo -e "✅ Success! Your local kubeconfig is now synced with the live cluster.\n"