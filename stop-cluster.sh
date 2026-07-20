#!/bin/bash
echo "🛑 Stopping k3s..."

K3S_PID=$(sudo ss -tlnp 2>/dev/null | grep ':6443 ' | grep -oP 'pid=\K[0-9]+' | head -1)

if [ -z "$K3S_PID" ]; then
    echo "k3s is not running (nothing listening on :6443)."
    exit 0
fi

echo "Sending graceful stop to k3s (pid $K3S_PID)..."
sudo kill -TERM "$K3S_PID"

for i in $(seq 1 15); do
    sudo kill -0 "$K3S_PID" 2>/dev/null || { echo "💤 k3s stopped cleanly."; exit 0; }
    sleep 1
done

echo "⚠️  k3s (pid $K3S_PID) did not stop within 15s of SIGTERM."
echo "   Something's off — check: sudo tail -n 50 /var/log/k3s.log"
echo "   If you're sure it's safe, force-stop manually with: sudo k3s-killall.sh"
exit 1