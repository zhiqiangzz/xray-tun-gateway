#!/bin/sh
# attach-gw.sh -- attach already-running sibling containers to the gateway
# without recreating them: point the default route at the gateway and, only
# if the container wasn't created with `--dns <gateway>`, its DNS too.
#
#   ./attach-gw.sh [-g GW_IP] <container> [container ...]
#
# Both changes are runtime-only and are lost when the container restarts
# (its network namespace and Docker's resolv.conf are recreated), so re-run
# this after every restart. A container created with `--dns <gateway>` (see
# README "Start a new container and attach it to the gateway") keeps its DNS
# across restarts and only needs the route.
#
# DNS is fixed by replacing the container's nameservers with the gateway.
# That drops Docker's embedded resolver (127.0.0.11), so container-to-
# container *name* resolution stops working in that container -- recreate
# with `--dns <gateway>` instead if it needs that.
#
# Needs only docker access (no sudo): both edits are done from a throwaway
# container of the gateway image, which already ships busybox/ip.
set -eu

GW_IP="${TUN_GW_IP:-10.90.0.2}"
HELPER_IMAGE="${HELPER_IMAGE:-tun-gw-xray:local}"

err() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

usage() {
  echo "usage: $0 [-g GW_IP] <container> [container ...]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--gateway) GW_IP="${2:?missing value for -g}"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage

if ! docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
  err "helper image $HELPER_IMAGE not found (build the gateway image first, or set HELPER_IMAGE)"
  exit 1
fi

# Was the container created with --dns <gateway>? Then Docker's embedded
# resolver already forwards to the gateway, and survives restarts.
dns_set_to_gateway() {
  docker inspect "$1" -f '{{range .HostConfig.Dns}}{{println .}}{{end}}' | grep -qx "$GW_IP"
}

attach_one() {
  c="$1"
  if [ "$(docker inspect "$c" -f '{{.State.Running}}' 2>/dev/null)" != true ]; then
    err "$c: not running (or doesn't exist) -- start it first"
    return 1
  fi
  mode="$(docker inspect "$c" -f '{{.HostConfig.NetworkMode}}')"
  case "$mode" in
    host|none|container:*)
      err "$c: network mode '$mode' has no namespace of its own to re-route"
      return 1 ;;
  esac

  # 1. default route -> gateway (inside the container's own netns only)
  if ! docker run --rm --network "container:$c" --cap-add NET_ADMIN \
      --entrypoint ip "$HELPER_IMAGE" route replace default via "$GW_IP"; then
    err "$c: couldn't route via $GW_IP -- is it attached to the gateway's network?"
    return 1
  fi

  # 2. DNS -> gateway, unless --dns already did that at creation
  if dns_set_to_gateway "$c"; then
    log "$c: route via $GW_IP; DNS already --dns $GW_IP (kept, survives restarts)"
    return 0
  fi
  other="$(docker inspect "$c" -f '{{range .HostConfig.Dns}}{{.}} {{end}}')"
  if [ -n "$other" ]; then
    log "$c: was created with --dns ${other% } (not the gateway) -- overriding at runtime"
  fi
  conf="$(docker inspect "$c" -f '{{.ResolvConfPath}}')"
  if [ -z "$conf" ]; then
    err "$c: Docker reports no resolv.conf path -- DNS left unchanged"
    return 1
  fi
  # The file is bind-mounted into the container by inode, so it must be
  # rewritten in place (cat >), never replaced (sed -i renames a new file
  # over it, which the container would never see).
  docker run --rm -v "$conf:/target" --entrypoint busybox "$HELPER_IMAGE" sh -c '
    awk -v gw="$1" "
      /^nameserver[ \t]/ { if (!done) print \"nameserver \" gw; done = 1; next }
      { print }
      END { if (!done) print \"nameserver \" gw }
    " /target > /tmp/resolv.conf && cat /tmp/resolv.conf > /target
  ' sh "$GW_IP"
  log "$c: route via $GW_IP; DNS -> $GW_IP (runtime only: re-run after a restart)"
}

rc=0
for c in "$@"; do
  attach_one "$c" || rc=1
done
exit "$rc"
