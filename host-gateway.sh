#!/usr/bin/env bash
# host-gateway.sh — selectively route some (or all) users' host-originated
# traffic through the tun gateway container, without touching the host's
# own default route and without looping when the gateway's own return
# traffic transits back through the host.
#
# Mechanism (verified live against this host before being written here --
# see README.md for the walkthrough):
#
#   pref 50: from $GW_IP lookup main
#       Loop fix. The gateway container's own relay/return traffic re-enters
#       the host as plain forwarded (no-UID) traffic. Without this rule it
#       would be caught by the same catch-all redirect below and bounce
#       forever between host and gateway, instead of ever reaching the real
#       internet.
#
#   pref 100-199 (reserved for this script, ~50 users' worth):
#       One pair per enabled user (or a single unconditional pair for "all"):
#         pref N:   [uidrange U-U] lookup main suppress_prefixlength 0
#         pref N+1: [uidrange U-U] lookup $TABLE
#       "Stay local if main already has a specific route, otherwise redirect
#       to the gateway" -- the same longest-prefix-match principle used
#       everywhere else in this project; gated by uidrange only in
#       "specific users" mode.
#
#   table 200: a single `default via $GW_IP` route, nothing else.
#
# Usage:
#   sudo ./host-gateway.sh [-g GW_IP] enable all
#   sudo ./host-gateway.sh [-g GW_IP] enable <user1> [user2 ...]
#   sudo ./host-gateway.sh disable
#        ./host-gateway.sh status
#   sudo ./host-gateway.sh reapply      # used by the systemd unit at boot
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$HERE/host-gateway.state"
TABLE=200
LOOP_FIX_PREF=50
BASE_PREF=100
MAX_PREF=199
DEFAULT_GW_IP=10.90.0.2

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }

usage() {
  cat >&2 <<EOF
Usage:
  sudo $0 [-g GW_IP] enable all
  sudo $0 [-g GW_IP] enable <user1> [user2 ...]
  sudo $0 disable
       $0 status
  sudo $0 reapply
EOF
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "requires root; re-run this command with sudo"
    exit 1
  fi
}

# ---- parse -g/--gateway (can appear anywhere before the subcommand) ----
GW_IP=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -g|--gateway) GW_IP="${2:?missing value for -g}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

# ---- clear every rule this script manages (idempotent, ignores "doesn't exist" errors) ----
_clear() {
  local line pref rest
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pref="${line%%:*}"
    rest="${line#*:}"
    rest="${rest#$'\t'}"
    if [ "$pref" != "$LOOP_FIX_PREF" ]; then
      { [ "$pref" -ge "$BASE_PREF" ] && [ "$pref" -le "$MAX_PREF" ]; } 2>/dev/null || continue
    fi
    # shellcheck disable=SC2086
    ip rule del pref "$pref" $rest 2>/dev/null || true
  done < <(ip rule show)
  ip route flush table "$TABLE" >/dev/null 2>&1 || true
}

_apply_common() {
  ip route add default via "$GW_IP" table "$TABLE"
  ip rule add pref "$LOOP_FIX_PREF" from "$GW_IP" lookup main
}

_apply_all() {
  ip rule add pref "$BASE_PREF" lookup main suppress_prefixlength 0
  ip rule add pref "$((BASE_PREF + 1))" lookup "$TABLE"
}

_apply_users() {
  local pref=$BASE_PREF uid name
  for name in "$@"; do
    uid="$(id -u "$name" 2>/dev/null)" || { err "user not found: $name"; exit 1; }
    if [ "$pref" -gt "$((MAX_PREF - 1))" ]; then
      err "too many users, exceeds the reserved priority range ($BASE_PREF-$MAX_PREF)"
      exit 1
    fi
    ip rule add pref "$pref" uidrange "$uid-$uid" lookup main suppress_prefixlength 0
    ip rule add pref "$((pref + 1))" uidrange "$uid-$uid" lookup "$TABLE"
    pref=$((pref + 2))
  done
}

cmd_enable() {
  require_root
  [ $# -ge 1 ] || usage
  GW_IP="${GW_IP:-$DEFAULT_GW_IP}"

  local MODE USERS
  if [ "$1" = all ]; then
    MODE=all
    USERS=""
  else
    MODE=users
    local name
    for name in "$@"; do
      id -u "$name" >/dev/null 2>&1 || { err "user not found: $name"; exit 1; }
    done
    USERS="$*"
  fi

  log "clearing old rules"
  _clear
  log "applying new rules (gateway=$GW_IP, mode=$MODE${USERS:+, users=$USERS})"
  _apply_common
  if [ "$MODE" = all ]; then
    _apply_all
  else
    # shellcheck disable=SC2086
    _apply_users $USERS
  fi

  {
    echo "GW_IP=$GW_IP"
    echo "MODE=$MODE"
    echo "USERS=$USERS"
  } > "$STATE_FILE"
  log "done. Run '$0 status' to see the current state."
}

cmd_disable() {
  require_root
  log "clearing rules"
  _clear
  : > "$STATE_FILE"
  log "done"
}

cmd_reapply() {
  require_root
  if [ ! -s "$STATE_FILE" ]; then
    log "state file is empty/missing, nothing to do"
    exit 0
  fi
  local GW_IP MODE USERS
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [ -n "${MODE:-}" ] || exit 0
  GW_IP="${GW_IP:-$DEFAULT_GW_IP}"
  log "replaying state: gateway=$GW_IP, mode=$MODE${USERS:+, users=$USERS}"
  _clear
  _apply_common
  if [ "$MODE" = all ]; then
    _apply_all
  else
    # shellcheck disable=SC2086
    _apply_users $USERS
  fi
}

cmd_status() {
  echo "=== rules managed by this script (pref $LOOP_FIX_PREF, $BASE_PREF-$MAX_PREF) ==="
  ip rule show | awk -F: -v lo="$LOOP_FIX_PREF" -v b="$BASE_PREF" -v m="$MAX_PREF" \
    '{p=$1+0} p==lo || (p>=b && p<=m)'
  echo
  echo "=== table $TABLE ==="
  ip route show table "$TABLE" 2>/dev/null || echo "(empty)"
  echo
  if [ -s "$STATE_FILE" ]; then
    local GW_IP MODE USERS
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    if [ "${MODE:-}" = all ]; then
      echo "currently enabled: all users (gateway=${GW_IP:-?})"
    elif [ -n "${USERS:-}" ]; then
      echo "currently enabled: $USERS (gateway=${GW_IP:-?})"
    else
      echo "currently disabled"
    fi
  else
    echo "currently disabled"
  fi
}

case "$CMD" in
  enable)  cmd_enable "$@" ;;
  disable) cmd_disable ;;
  status)  cmd_status ;;
  reapply) cmd_reapply ;;
  *) usage ;;
esac
