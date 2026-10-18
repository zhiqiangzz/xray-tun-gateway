# Transparent Gateway (single container, xray-core native tun inbound)

A single container (`tun-gw-xray`) acts as a transparent gateway: any number
of ordinary sibling containers can have their non-local traffic routed
through a VLESS+Reality tunnel to a remote VPS, without adding any
capability to those sibling containers, without root on the host, and
without touching the host's own routing table. Works under both Docker and
Podman.

## How it works

- `tun-gw-xray` is built from the official `ghcr.io/xtls/xray-core` image
  plus a small busybox toolbox and a self-healing `entrypoint.sh` (see
  `Dockerfile` / `entrypoint.sh` for the exact mechanism).
- xray-core's native `"protocol": "tun"` inbound creates a `tun0` device and
  uses `autoSystemRoutingTable` to route all non-local traffic into it;
  `autoOutboundsInterface` is set to `"auto"`, which binds outbound sockets
  to the container's real physical interface (whatever it's named) to avoid
  routing back into itself.
- Sibling containers (B/C/...) are completely unmodified: zero extra
  capabilities, zero awareness of the proxy. The only thing ever changed
  about them is their own **default route**, pointed at the gateway's static
  IP by a one-shot helper container that borrows their network namespace
  (`--network container:<name>`) just long enough to run `ip route replace`
  — it never touches the host's routing table.
- The gateway container has no restart policy (it will not auto-start), but
  its entrypoint re-applies its internal route fix on every startup, so a
  manual `start`/`restart` is always enough to bring it back correctly.
- Routing policy is full-tunnel: everything except private/LAN addresses
  goes through `proxy` (see `config.template.json`'s `routing.rules` -- there
  is no geoip/geosite China-direct bypass). The config also exposes a
  `socks` inbound on `127.0.0.1:10808` inside the gateway's own netns, in
  addition to the `tun` inbound, for manual debugging from inside the
  gateway.

## Prerequisites

- `config.json`: your real VLESS+Reality server details. This file contains
  secrets and is gitignored. Either copy `config.template.json` by hand and
  fill in the placeholders, or generate it from a share link (see below).
- A helper image with `ip` (iproute2) for the one-shot route-fixup commands
  below: `docker.io/nicolaka/netshoot:latest`. Any image with `ip` works.

### Generating config.json from a vless:// link

`vless2config.py` parses a `vless://` share link into the "proxy" outbound
and splices it into `config.template.json` (replacing its placeholder
`proxy` outbound), writing the result to `config.json`. A share link alone
only describes how to reach the remote server -- it says nothing about local
listening/routing/DNS -- so the script's job is exactly that splice; the raw
outbound fragment by itself would not be a usable gateway config, and the
shared inbound/dns/routing structure lives once in `config.template.json`,
not duplicated inside the script.

The script only needs the standard library, but it's set up as a `uv`
project so running it doesn't depend on whatever Python happens to be on
your `PATH`:

```bash
uv sync                                                  # one-time: creates .venv
uv run vless2config.py 'vless://uuid@host:port?...#remark'   # writes config.json
```

Only `tcp` transport is supported, with `reality`, `tls` or no security
(matching what this gateway has actually been tested against); other
transports (`ws`/`grpc`/`kcp`/`quic`/`xhttp`) raise a clear error instead of
emitting a config that looks valid but doesn't work.

`config.template.json` mirrors a desktop (v2rayN-style) export almost
exactly -- same `dns` block, same `socks` + `tun` inbounds, same flattened
vless outbound shape (`settings.address/port/id` instead of
`vnext`/`users`), `network: "raw"`, `realitySettings.mldsa65Verify` --
with two deliberate differences from a literal copy:
- the `tun` inbound's device is named `"tun0"`, not a desktop-style
  `"utun46"`, because `entrypoint.sh` waits for and fixes up routing on
  a device literally named `tun0`;
- the desktop export's `process`-matched routing rules (matching the
  desktop app's own executable path to avoid looping back through itself)
  are dropped -- they reference paths that don't exist in this container,
  and this gateway already has its own, independently-verified anti-loop
  mechanism (`autoOutboundsInterface: "auto"` + the entrypoint's route-metric
  fix).

---

## Docker

### 1. Build the gateway image

```bash
docker build -t tun-gw-xray:local \
  --build-arg XRAY_BASE_IMAGE=ghcr.io/xtls/xray-core:26.10.10 .
```

### 2. Create the network

```bash
docker network create --subnet 10.90.0.0/24 tun-gw-network
```

### 3. Start the gateway container

```bash
docker run -d --name tun-gw-xray \
  --network tun-gw-network --ip 10.90.0.2 \
  --cap-add NET_ADMIN --device /dev/net/tun --user 0 \
  --sysctl net.ipv4.conf.all.forwarding=1 \
  -e HTTP_PROXY= -e HTTPS_PROXY= -e ALL_PROXY= -e NO_PROXY= \
  -e http_proxy= -e https_proxy= -e all_proxy= -e no_proxy= \
  -v "$(pwd)/config.json:/usr/local/etc/xray/config.json:ro" \
  tun-gw-xray:local
```

- `--user 0`: the base image defaults to a non-root UID, and Linux does not
  propagate `--cap-add`-granted capabilities to a non-root process without
  explicit ambient capabilities. Without this, building `tun0` / editing
  routes fails with "operation not permitted".
- The `-e ..._PROXY=` flags scrub Docker's own daemon-level proxy injection
  (from `~/.docker/config.json`'s `proxies.default`, if you have one
  configured) — otherwise it silently overrides this container's real
  upstream path. Podman has no equivalent injection; see the Podman section.

Check it came up correctly:

```bash
docker logs tun-gw-xray
# should end with: "[entrypoint] demoted engine-assigned default route via ... to metric 100"

docker run --rm --network container:tun-gw-xray --entrypoint ip \
  docker.io/nicolaka/netshoot:latest addr show tun0
```

### 4. Start a new container and attach it to the gateway

Start your own container completely normally — no extra flags, no extra
capabilities:

```bash
docker run -d --name my-app --network tun-gw-network \
  -e HTTP_PROXY= -e HTTPS_PROXY= -e ALL_PROXY= -e NO_PROXY= \
  -e http_proxy= -e https_proxy= -e all_proxy= -e no_proxy= \
  my-image
```

Then point its default route at the gateway. This is the *only* command that
ever touches `my-app`; it runs inside `my-app`'s own network namespace (never
the host's) and exits immediately:

```bash
docker run --rm --network container:my-app --cap-add NET_ADMIN \
  --entrypoint ip docker.io/nicolaka/netshoot:latest \
  route replace default via 10.90.0.2
```

### 5. Verify the tunnel

```bash
docker exec my-app curl -s https://api.ipify.org
# should print the VPS's IP, not your own
```

### 6. Detach a container (revert to the normal gateway)

```bash
GW="$(docker network inspect tun-gw-network --format '{{(index .IPAM.Config 0).Gateway}}')"
docker run --rm --network container:my-app --cap-add NET_ADMIN \
  --entrypoint ip docker.io/nicolaka/netshoot:latest \
  route replace default via "$GW"
```

### 7. Gateway lifecycle

```bash
docker stop tun-gw-xray
docker start tun-gw-xray     # entrypoint re-applies the route fix automatically
docker restart tun-gw-xray   # same
docker logs -f tun-gw-xray
docker rm -f tun-gw-xray      # remove the gateway (sibling containers are untouched)
docker network rm tun-gw-network
```

---

## Podman

Same steps as Docker, with two differences: use `--http-proxy=false` instead
of scrubbing proxy env vars, and the `network inspect` gateway-lookup format
is different. A separate subnet (`10.91.0.0/24`) is suggested so the Docker
and Podman stacks can coexist on the same machine.

### 1. Build the gateway image

```bash
podman build -t tun-gw-xray:local \
  --build-arg XRAY_BASE_IMAGE=ghcr.io/xtls/xray-core:26.10.10 .
```

### 2. Create the network

```bash
podman network create --subnet 10.91.0.0/24 tun-gw-network
```

### 3. Start the gateway container

```bash
podman run -d --name tun-gw-xray \
  --network tun-gw-network --ip 10.91.0.2 \
  --cap-add NET_ADMIN --device /dev/net/tun --user 0 \
  --sysctl net.ipv4.conf.all.forwarding=1 \
  --http-proxy=false \
  -v "$(pwd)/config.json:/usr/local/etc/xray/config.json:ro" \
  tun-gw-xray:local
```

- `--user 0`: same reason as Docker above.
- `--http-proxy=false`: stops Podman from injecting your shell's own
  `HTTP_PROXY`/`HTTPS_PROXY` env vars into the container.

Check it came up correctly:

```bash
podman logs tun-gw-xray
# should end with: "[entrypoint] demoted engine-assigned default route via ... to metric 100"

podman run --rm --network container:tun-gw-xray --entrypoint ip \
  docker.io/nicolaka/netshoot:latest addr show tun0
```

### 4. Start a new container and attach it to the gateway

```bash
podman run -d --name my-app --network tun-gw-network --http-proxy=false my-image
```

```bash
podman run --rm --network container:my-app --cap-add NET_ADMIN \
  --entrypoint ip docker.io/nicolaka/netshoot:latest \
  route replace default via 10.91.0.2
```

### 5. Verify the tunnel

```bash
podman exec my-app curl -s https://api.ipify.org
```

### 6. Detach a container (revert to the normal gateway)

```bash
GW="$(podman network inspect tun-gw-network --format '{{range .Subnets}}{{.Gateway}}{{end}}')"
podman run --rm --network container:my-app --cap-add NET_ADMIN \
  --entrypoint ip docker.io/nicolaka/netshoot:latest \
  route replace default via "$GW"
```

### 7. Gateway lifecycle

```bash
podman stop tun-gw-xray
podman start tun-gw-xray
podman restart tun-gw-xray
podman logs -f tun-gw-xray
podman rm -f tun-gw-xray
podman network rm tun-gw-network
```

---

## Routing the host's own traffic (optional, requires sudo)

Everything above redirects *other containers'* traffic without ever touching
host root, by borrowing their network namespace. The host itself isn't a
container -- it *is* the root network namespace -- so there is no namespace
to borrow: making the host's own traffic go through the gateway requires
changing the host's own routing table, which needs `sudo`/`CAP_NET_ADMIN` on
the host. There's no way around that for this one piece.

To avoid affecting other users on a shared machine, scope the change to your
own UID with Linux policy routing (`ip rule`) instead of changing the host's
global default route:

```bash
MY_UID=$(id -u)
GW_IP=10.90.0.2      # the docker gateway's IP; use 10.91.0.2 for podman
TABLE=200            # any unused routing table number

# 1. a table that only holds a default route via the gateway
sudo ip route add default via "$GW_IP" table "$TABLE"

# 2. for my UID: look up in "main", but reject a match that's only the
#    plain default route (prefix length 0) -- i.e. let any more specific
#    route (LAN, docker/podman bridges, ...) win and go out normally
sudo ip rule add pref 100 uidrange "$MY_UID-$MY_UID" lookup main suppress_prefixlength 0

# 3. for my UID: whatever didn't match a specific route above (i.e. would
#    have gone out the default route) -- send through the gateway instead
sudo ip rule add pref 101 uidrange "$MY_UID-$MY_UID" lookup "$TABLE"
```

Other UIDs never match `uidrange $MY_UID-$MY_UID`, so they fall straight
through to the normal built-in rule (`32766: from all lookup main`),
completely unaffected.

**Verify:**

```bash
ip rule show | head -5             # the two new rules, pref 100/101

curl -s https://api.ipify.org      # as yourself -> the VPS's IP

sudo curl -s https://api.ipify.org # as root (uid 0, doesn't match the rule)
                                    # -> your real IP (likely still blocked
                                    #    directly, which is the expected,
                                    #    unaffected baseline)
```

**Roll back:**

```bash
sudo ip rule del pref 100 uidrange "$MY_UID-$MY_UID" lookup main suppress_prefixlength 0
sudo ip rule del pref 101 uidrange "$MY_UID-$MY_UID" lookup "$TABLE"
sudo ip route del default via "$GW_IP" table "$TABLE"
```

Notes:

- This is a live, in-memory change to the kernel's routing policy database,
  not a persisted network config -- a host reboot reverts it on its own.
- It's scoped to your UID, but it's still *your own* connectivity it
  changes. The first time you run it, consider a safety-net auto-revert in
  case something's wrong and you can't type the rollback commands yourself
  (e.g. if this is a remote session going through the very connection that
  might break):
  ```bash
  ( sleep 90 && sudo ip rule del pref 100 uidrange "$MY_UID-$MY_UID" lookup main suppress_prefixlength 0; \
    sudo ip rule del pref 101 uidrange "$MY_UID-$MY_UID" lookup "$TABLE" ) &
  ```
- **`http_proxy`/`https_proxy`/`all_proxy` in your shell take priority over
  this for any app that honors them.** Those env vars work at the
  application layer: an app that reads them doesn't connect to the real
  destination at all -- it connects to whatever address *they* specify, and
  it's *that* connection the kernel-level rule above sees and routes. If that
  address happens to fall inside an already-locally-routed subnet (for
  example Docker's own `172.17.0.0/16`, a common default for a local proxy
  tool), rule 100 matches it as "local" and the app's traffic never reaches
  the gateway at all, silently. Unset those variables if you want this
  mechanism to actually apply to apps that would otherwise use them.

## Troubleshooting

- **`tun0` never shows up / gateway unreachable**: check
  `docker logs tun-gw-xray` (or `podman logs`). A missing
  `"[entrypoint] demoted engine-assigned default route..."` line means the
  entrypoint never saw `tun0` come up within its 30s wait — check that
  `--device /dev/net/tun`, `--cap-add NET_ADMIN` and `--user 0` are all
  present on the `run` command.
- **`--sysctl net.ipv4.conf.all.forwarding=1` rejected** (rare, engine/kernel
  dependent): drop the flag from the `run` command, then apply it manually
  once the container is up:
  ```bash
  docker run --rm --network container:tun-gw-xray --cap-add NET_ADMIN \
    --entrypoint sysctl docker.io/nicolaka/netshoot:latest \
    -w net.ipv4.conf.all.forwarding=1
  ```
  Note this one does **not** survive a gateway restart (unlike the
  route-metric fix, which is baked into `entrypoint.sh`), so it needs to be
  re-run after every restart if you ever need this fallback.
- **A sibling container's egress doesn't change**: local/subnet traffic
  (container-to-container, DNS to peer names) is expected to keep working
  normally — only non-local traffic goes through the tunnel, by design
  (Linux's longest-prefix-match always prefers the directly-connected subnet
  route over the default route).
