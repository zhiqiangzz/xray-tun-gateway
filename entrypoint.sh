#!/bin/sh
# 在后台跑 xray, 等它自己的 tun0 建好, 再把引擎自动装的 eth0 default 路由降级
# (metric 100, 不整条删除——autoOutboundsInterface 的设备绑定 socket 还要靠它连 VPS),
# 让 xray 的 autoSystemRoutingTable 装的 "default dev tun0 metric 1" 成为非设备绑定
# 流量(包含所有转发流量)的默认路由。见 Dockerfile 顶部注释: 这段逻辑每次容器启动都会
# 跑一遍, 和容器怎么被重启无关。
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
