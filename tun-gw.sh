#!/usr/bin/env bash
# =============================================================================
# tun-gw.sh — 单容器版透明网关 (docker / podman 均可用, rootless 友好, 不碰 host 路由)
#   ./tun-gw.sh <docker|podman> up|down|restart|status|logs [名字]|destroy|
#                                build|attach <名字>|detach <名字>|check-gateway
#
# 架构:
#   单一容器 tun-gw-xray, 基于本仓库 Dockerfile 构建(FROM $XRAY_BASE_IMAGE + busybox
#   工具箱 + 自愈 entrypoint, 见 Dockerfile/entrypoint.sh 顶部注释)。xray-core 自身的
#   "protocol": "tun" 入站(26.1.x 起支持)建 tun0, autoSystemRoutingTable 把非本地流量
#   导入 tun0, autoOutboundsInterface 给出站 socket 绑定物理接口防自环。
#   容器不设自动重启策略(故意不加 --restart, 按要求不自启动; 崩溃/停机后需要显式
#   './tun-gw.sh <engine> up' 或 'start' 拉起)。
#   B/C/... 仍是零额外 capability 的普通容器, 默认路由由外部一次性 helper 改写。
# =============================================================================
set -euo pipefail

ENGINE="${1:-}"
case "$ENGINE" in
  docker|podman) shift ;;
  *)
    echo "用法: $0 <docker|podman> <up|down|restart|status|logs [名字]|destroy|build|attach <名字>|detach <名字>|check-gateway>" >&2
    exit 1
    ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$DIR/.env"; set +a

if [ "$ENGINE" = docker ]; then
  SUBNET="$DOCKER_SUBNET"; GW_IP="$DOCKER_GW_IP"
  HTTPPROXY_ARGS=()
  NOPROXY_ARGS=(-e HTTP_PROXY= -e HTTPS_PROXY= -e ALL_PROXY= -e NO_PROXY=
                -e http_proxy= -e https_proxy= -e all_proxy= -e no_proxy=)
else
  SUBNET="$PODMAN_SUBNET"; GW_IP="$PODMAN_GW_IP"
  HTTPPROXY_ARGS=(--http-proxy=false)
  NOPROXY_ARGS=()
fi
SYSCTL_FALLBACK_NEEDED=0

rt() { "$ENGINE" "$@"; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
# 镜像 / 网络
# -----------------------------------------------------------------------------
ensure_image() {
  local img="$1"
  rt image inspect "$img" >/dev/null 2>&1 && return 0
  log "拉取镜像 $img"
  rt pull "$img" >/dev/null
}

cmd_build() {
  log "构建网关镜像 $GW_IMAGE_TAG (base: $XRAY_BASE_IMAGE)"
  rt build -t "$GW_IMAGE_TAG" --build-arg "XRAY_BASE_IMAGE=$XRAY_BASE_IMAGE" "$DIR"
}

ensure_gw_image() {
  rt image inspect "$GW_IMAGE_TAG" >/dev/null 2>&1 && return 0
  cmd_build
}

ensure_network() {
  rt network inspect "$NETWORK_NAME" >/dev/null 2>&1 && return 0
  log "创建网络 $NETWORK_NAME ($SUBNET)"
  rt network create --subnet "$SUBNET" "$NETWORK_NAME" >/dev/null
}

network_gateway_ip() {
  if [ "$ENGINE" = docker ]; then
    rt network inspect "$NETWORK_NAME" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null
  else
    rt network inspect "$NETWORK_NAME" --format '{{range .Subnets}}{{.Gateway}}{{end}}' 2>/dev/null
  fi
}

# -----------------------------------------------------------------------------
# A: 单容器网关 (tun-gw-xray, 自建镜像, 自愈 entrypoint)
# -----------------------------------------------------------------------------
start_gw() {
  if rt container inspect "$GW_NAME" >/dev/null 2>&1; then
    rt start "$GW_NAME" >/dev/null 2>&1
    log "$GW_NAME 已存在, 已启动"
    return
  fi
  ensure_gw_image
  log "启动 $GW_NAME (单容器网关, 不设自动重启策略)"
  # --user 0: 镜像默认非 root UID, --cap-add 的能力不会自动继承给非 root 进程,
  # 建 tun0/配路由会 "operation not permitted"(已实测确认)。
  local common=(-d --name "$GW_NAME"
    --network "$NETWORK_NAME" --ip "$GW_IP"
    --cap-add NET_ADMIN --device /dev/net/tun --user 0
    "${HTTPPROXY_ARGS[@]}" "${NOPROXY_ARGS[@]}"
    -v "$DIR/config/xray/config.json:/usr/local/etc/xray/config.json:ro")
  local out
  if out="$(rt run "${common[@]}" --sysctl net.ipv4.conf.all.forwarding=1 "$GW_IMAGE_TAG" 2>&1)"; then
    return
  fi
  err "带 --sysctl 启动失败 (${out}), 回退: 不设 sysctl, 稍后用 helper 补"
  rt run "${common[@]}" "$GW_IMAGE_TAG" >/dev/null
  SYSCTL_FALLBACK_NEEDED=1
}

fixup_ip_forward_fallback() {
  log "用一次性 helper 补设置 net.ipv4.conf.all.forwarding=1"
  rt run --rm --network "container:$GW_NAME" --cap-add NET_ADMIN \
    --entrypoint sysctl "$TEST_IMAGE" -w net.ipv4.conf.all.forwarding=1 >/dev/null
}

wait_gw_ready() {
  local i=0
  log "等待 tun0 建立 (entrypoint 会在容器自己启动时顺带修好路由优先级, 这里只等它就绪)"
  while [ "$i" -lt 30 ]; do
    rt run --rm --network "container:$GW_NAME" --entrypoint ip "$TEST_IMAGE" \
      addr show tun0 >/dev/null 2>&1 && break
    sleep 1; i=$((i+1))
  done
  if [ "$i" -ge 30 ]; then
    err "$GW_NAME 的 tun0 未能就绪"; rt logs --tail 30 "$GW_NAME"; exit 1
  fi
  log "gateway ready (tun0 已建立)"
}

# -----------------------------------------------------------------------------
# B/C/... : 普通容器, 零额外 capability; 路由由外部 helper 一次性改写
# -----------------------------------------------------------------------------
start_test_container() {
  local name="$1"
  if rt container inspect "$name" >/dev/null 2>&1; then
    rt start "$name" >/dev/null 2>&1
    log "$name 已存在, 已启动"
    return
  fi
  ensure_image "$TEST_IMAGE"
  log "启动测试容器 $name (零额外权限)"
  rt run -d --name "$name" \
    --network "$NETWORK_NAME" \
    "${HTTPPROXY_ARGS[@]}" "${NOPROXY_ARGS[@]}" \
    "$TEST_IMAGE" sleep infinity >/dev/null
}

fixup_route() {
  local target="$1"
  log "把 $target 的默认路由改向 $GW_IP (一次性 helper, $target 自身容器定义不变)"
  rt run --rm --network "container:$target" --cap-add NET_ADMIN \
    --entrypoint ip "$TEST_IMAGE" route replace default via "$GW_IP" >/dev/null
}

revert_route() {
  local target="$1" real_gw
  real_gw="$(network_gateway_ip)"
  [ -n "$real_gw" ] || { err "无法取到 $NETWORK_NAME 的网关地址"; return 1; }
  log "把 $target 的默认路由改回正常网关 $real_gw"
  rt run --rm --network "container:$target" --cap-add NET_ADMIN \
    --entrypoint ip "$TEST_IMAGE" route replace default via "$real_gw" >/dev/null
}

# -----------------------------------------------------------------------------
# 子命令
# -----------------------------------------------------------------------------
all_containers() { echo "$TEST_B_NAME $TEST_C_NAME $GW_NAME"; }

cmd_up() {
  ensure_network
  start_gw
  wait_gw_ready
  [ "$SYSCTL_FALLBACK_NEEDED" = 1 ] && fixup_ip_forward_fallback
  start_test_container "$TEST_B_NAME"
  start_test_container "$TEST_C_NAME"
  fixup_route "$TEST_B_NAME"
  fixup_route "$TEST_C_NAME"
  log "全部就绪。用 '$0 $ENGINE check-gateway' 校验。"
}

cmd_down() {
  local c
  for c in $(all_containers); do
    rt container inspect "$c" >/dev/null 2>&1 && rt stop -t 10 "$c" >/dev/null && log "已停止 $c"
  done
  true
}

cmd_restart() { cmd_down; cmd_up; }

cmd_status() {
  rt ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
    --filter "name=^${TEST_B_NAME}\$" --filter "name=^${TEST_C_NAME}\$" \
    --filter "name=^${GW_NAME}\$"
}

cmd_logs() { rt logs -f --tail 100 "${1:-$GW_NAME}"; }

cmd_destroy() {
  read -r -p "删除 $ENGINE 下全部 tun-gw 容器和网络 (不可恢复)? 输入 yes 确认: " a
  [ "$a" = yes ] || { echo "已取消"; return 1; }
  local c
  for c in $(all_containers); do rt rm -f "$c" >/dev/null 2>&1 || true; done
  rt network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  log "已清理 ($ENGINE)"
}

cmd_attach() {
  local name="${1:?用法: $0 $ENGINE attach <容器名>}"
  rt container inspect "$name" >/dev/null 2>&1 || { err "容器 $name 不存在"; exit 1; }
  fixup_route "$name"
}

cmd_detach() {
  local name="${1:?用法: $0 $ENGINE detach <容器名>}"
  rt container inspect "$name" >/dev/null 2>&1 || { err "容器 $name 不存在"; exit 1; }
  revert_route "$name"
}

cmd_check_gateway() {
  echo "=== [$ENGINE] 1. B/C/$GW_NAME 容器内代理环境变量 (应无非空取值) ==="
  local n
  for n in "$TEST_B_NAME" "$TEST_C_NAME" "$GW_NAME"; do
    echo "--- $n ---"
    rt inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$n" 2>/dev/null | grep -iE 'proxy=.+' \
      || echo "(无非空代理变量, 符合预期)"
  done

  echo; echo "=== 2. B/C 的额外 capability (应为空/null, 证明零特权) ==="
  for n in "$TEST_B_NAME" "$TEST_C_NAME"; do
    echo -n "$n CapAdd: "; rt inspect -f '{{.HostConfig.CapAdd}}' "$n"
  done

  echo; echo "=== 3. $GW_NAME 内 tun0 + ip_forward (借一次性 helper 探测, $GW_NAME 本身是 distroless 基底) ==="
  rt run --rm --network "container:$GW_NAME" --entrypoint ip "$TEST_IMAGE" addr show tun0 \
    | grep -E 'tun0|inet ' || echo "!! tun0 未找到"
  rt run --rm --network "container:$GW_NAME" --entrypoint cat "$TEST_IMAGE" \
    /proc/sys/net/ipv4/conf/all/forwarding

  echo; echo "=== 4. B/C 默认路由 (应指向 $GW_IP) ==="
  for n in "$TEST_B_NAME" "$TEST_C_NAME"; do
    echo -n "$n: "; rt exec "$n" ip route show default
  done

  echo; echo "=== 5. 出口 IP: B/C (经隧道) vs host 直连 (对照) ==="
  echo -n "$TEST_B_NAME -> "; rt exec "$TEST_B_NAME" curl -s --max-time 15 https://api.ipify.org || echo "(失败, exit=$?)"; echo
  echo -n "$TEST_C_NAME -> "; rt exec "$TEST_C_NAME" curl -s --max-time 15 https://api.ipify.org || echo "(失败, exit=$?)"; echo
  echo -n "host 直连(对照) -> "; curl -s --noproxy '*' --max-time 15 https://api.ipify.org || echo "(失败, exit=$?)"; echo

  echo; echo "=== 6. 本地直连 (不经隧道): B -> 网关 IP (ping), B -> C 容器名解析/连通 ==="
  rt exec "$TEST_B_NAME" sh -c "ping -c2 -W2 $GW_IP" 2>&1 | tail -4
  rt exec "$TEST_B_NAME" getent hosts "$TEST_C_NAME" 2>&1 || rt exec "$TEST_B_NAME" sh -c "nslookup $TEST_C_NAME" 2>&1 || true

  echo; echo "=== 7. 端口独立性: B/C 各自在容器内绑定同一端口 8080, 互不冲突 ==="
  rt exec -d "$TEST_B_NAME" socat TCP-LISTEN:8080,fork,reuseaddr SYSTEM:'echo hi-from-b' >/dev/null 2>&1 || true
  rt exec -d "$TEST_C_NAME" socat TCP-LISTEN:8080,fork,reuseaddr SYSTEM:'echo hi-from-c' >/dev/null 2>&1 || true
  sleep 1
  echo -n "$TEST_B_NAME:8080 -> "; rt exec "$TEST_B_NAME" sh -c "echo | socat - TCP:127.0.0.1:8080" 2>/dev/null || echo "(失败)"
  echo -n "$TEST_C_NAME:8080 -> "; rt exec "$TEST_C_NAME" sh -c "echo | socat - TCP:127.0.0.1:8080" 2>/dev/null || echo "(失败)"
}

case "${1:-}" in
  up) cmd_up ;;
  down) cmd_down ;;
  restart) cmd_restart ;;
  status|ps) cmd_status ;;
  logs) shift; cmd_logs "$@" ;;
  destroy) cmd_destroy ;;
  build) cmd_build ;;
  attach) shift; cmd_attach "$@" ;;
  detach) shift; cmd_detach "$@" ;;
  check-gateway) cmd_check_gateway ;;
  *)
    echo "用法: $0 $ENGINE {up|down|restart|status|logs [名字]|destroy|build|attach <名字>|detach <名字>|check-gateway}" >&2
    exit 1
    ;;
esac
