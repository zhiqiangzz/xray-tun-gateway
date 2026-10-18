#!/bin/sh
# Run xray in the background, wait for its own tun0 to come up, then demote
# the engine-assigned eth0 default route (metric 100, not removed entirely --
# autoOutboundsInterface's device-bound sockets still need it to reach the
# VPS), so xray's autoSystemRoutingTable route ("default dev tun0 metric 1")
# becomes the default for everything else, including all forwarded traffic.
# See the Dockerfile header: this runs on every single container startup,
# regardless of how the container was restarted.
set -e

GW="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"

/usr/local/bin/xray run -confdir /usr/local/etc/xray/ &
XRAY_PID=$!
trap 'kill "$XRAY_PID" 2>/dev/null' TERM INT

i=0
while [ "$i" -lt 30 ]; do
  ip addr show tun0 >/dev/null 2>&1 && break
  sleep 1
  i=$((i + 1))
done

if [ -n "$GW" ]; then
  ip route del default via "$GW" dev eth0 2>/dev/null || true
  ip route replace default via "$GW" dev eth0 metric 100 2>/dev/null || true
  echo "[entrypoint] demoted engine-assigned default route via $GW to metric 100" >&2
else
  echo "[entrypoint] WARNING: could not detect engine-assigned default gateway" >&2
fi

wait "$XRAY_PID"
