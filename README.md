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
  `autoOutboundsInterface` binds outbound sockets to `eth0` to avoid routing
  back into itself.
- Sibling containers (B/C/...) are completely unmodified: zero extra
  capabilities, zero awareness of the proxy. The only thing ever changed
  about them is their own **default route**, pointed at the gateway's static
  IP by a one-shot helper container that borrows their network namespace
  (`--network container:<name>`) just long enough to run `ip route replace`
  — it never touches the host's routing table.
- The gateway container has no restart policy (it will not auto-start), but
  its entrypoint re-applies its internal route fix on every startup, so a
  manual `start`/`restart` is always enough to bring it back correctly.

## Prerequisites

- `config/xray/config.json`: copy `config/xray/config.json.example` and fill
  in your own VLESS+Reality server details. This file contains secrets and
  is gitignored.
- A helper image with `ip` (iproute2) for the one-shot route-fixup commands
  below: `docker.io/nicolaka/netshoot:latest`. Any image with `ip` works.

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
  -v "$(pwd)/config/xray/config.json:/usr/local/etc/xray/config.json:ro" \
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
  -v "$(pwd)/config/xray/config.json:/usr/local/etc/xray/config.json:ro" \
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
