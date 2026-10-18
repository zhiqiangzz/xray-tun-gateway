# 单容器透明网关镜像: xray-core (原生 tun 入站) + busybox 工具箱 + 自愈 entrypoint
#
# xray-core 官方镜像是 distroless(无 shell/iproute2), 而它自己的 tun 入站虽然会用
# autoSystemRoutingTable 把 "0.0.0.0/0" 指向 tun0, 但引擎(docker/podman)在建容器时
# 自动装的 "default via <网关> dev eth0"(隐式 metric 0)比 tun0 那条(metric 1)优先级
# 更高——不处理的话转发流量会直接绕过 tun0。这个 entrypoint 在每次容器启动时都会把
# 那条引擎自装的路由降级(保留一条 metric 100 的同义路由, 留给 autoOutboundsInterface
# 的设备绑定 socket 用), 不管容器以哪种方式重启(崩溃自愈、host 重启自启动、手动
# restart)都会在 PID 1 里重新跑一遍, 不依赖任何外部脚本。
ARG XRAY_BASE_IMAGE=ghcr.io/xtls/xray-core:26.10.10

FROM busybox:1.36-musl AS tools

FROM ${XRAY_BASE_IMAGE}
USER 0
COPY --from=tools /bin/busybox /bin/busybox
RUN ["/bin/busybox", "--install", "-s", "/bin"]
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
