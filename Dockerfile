# Single-container transparent gateway: xray-core (native tun inbound) +
# a busybox toolbox + a self-healing entrypoint.
#
# The official xray-core image is distroless (no shell, no iproute2). Its tun
# inbound uses autoSystemRoutingTable to point "0.0.0.0/0" at tun0, but the
# container engine (docker/podman) always installs its own "default via
# <gateway> dev eth0" (implicit metric 0) when the container starts, which
# outranks xray's tun0 route (metric 1) -- without a fix, forwarded traffic
# would bypass tun0 entirely. The entrypoint demotes that engine-installed
# route on every single startup (keeping a metric-100 fallback so
# autoOutboundsInterface's device-bound sockets can still reach the VPS
# directly), regardless of how the container is restarted (crash recovery,
# host reboot auto-start, manual restart) -- all inside the container's own
# PID 1, with no external script involved.
ARG XRAY_BASE_IMAGE=ghcr.io/xtls/xray-core:26.10.10

FROM busybox:1.36-musl AS tools

FROM ${XRAY_BASE_IMAGE}
USER 0
COPY --from=tools /bin/busybox /bin/busybox
RUN ["/bin/busybox", "--install", "-s", "/bin"]
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
