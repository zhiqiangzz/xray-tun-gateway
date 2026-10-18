#!/usr/bin/env python3
"""Convert a vless:// share link into a full xray config.json for tun-gw.

A vless:// link only encodes how to reach the remote proxy server (address,
port, uuid, transport/security settings) -- it says nothing about how the
local xray instance should listen or route traffic. On its own it is NOT a
usable gateway config. This script parses the link into the "proxy" outbound
and splices it into the same tun-inbound + dns + routing template already
used by config/xray/config.json, which is what actually makes the result
usable with this gateway.

Usage:
  ./vless2config.py 'vless://uuid@host:port?...#remark' [-o OUTPUT]

Only tcp transport is supported, with reality, tls or no security -- this
matches what the gateway has actually been built and tested against.
ws/grpc/kcp/quic/xhttp transports raise a clear error rather than silently
emitting a config that looks valid but doesn't work.
"""
import argparse
import json
import sys
from urllib.parse import parse_qs, urlparse


def parse_vless_link(link: str) -> dict:
    if not link.startswith("vless://"):
        raise ValueError("not a vless:// link")

    parsed = urlparse(link)
    if not parsed.username or not parsed.hostname or not parsed.port:
        raise ValueError("link is missing uuid / host / port")

    # parse_qs already percent-decodes values; only the fragment needs it
    # done explicitly.
    q = {k: v[0] for k, v in parse_qs(parsed.query).items()}

    return {
        "uuid": parsed.username,
        "host": parsed.hostname,
        "port": parsed.port,
        "remark": parsed.fragment or None,
        "encryption": q.get("encryption", "none"),
        "flow": q.get("flow", ""),
        "security": q.get("security", "none"),
        "network": q.get("type", "tcp"),
        "header_type": q.get("headerType", "none"),
        "sni": q.get("sni", ""),
        "fp": q.get("fp", ""),
        "pbk": q.get("pbk", ""),
        "sid": q.get("sid", ""),
        "spx": q.get("spx", "/"),
        "alpn": q.get("alpn", ""),
    }


def build_proxy_outbound(p: dict) -> dict:
    if p["network"] != "tcp":
        raise NotImplementedError(
            f"transport type {p['network']!r} is not supported "
            "(only 'tcp' has been tested with this gateway)"
        )
    if p["header_type"] not in ("none", ""):
        raise NotImplementedError(
            f"headerType {p['header_type']!r} is not supported (only 'none')"
        )

    user = {"id": p["uuid"], "security": "auto", "encryption": p["encryption"]}
    if p["flow"]:
        user["flow"] = p["flow"]

    stream_settings = {"network": "tcp"}

    if p["security"] == "reality":
        if not p["sni"] or not p["pbk"]:
            raise ValueError("reality security requires 'sni' and 'pbk' in the link")
        stream_settings["security"] = "reality"
        stream_settings["realitySettings"] = {
            "serverName": p["sni"],
            "fingerprint": p["fp"] or "chrome",
            "show": False,
            "publicKey": p["pbk"],
            "shortId": p["sid"],
            "spiderX": p["spx"] or "/",
        }
    elif p["security"] == "tls":
        tls_settings = {}
        if p["sni"]:
            tls_settings["serverName"] = p["sni"]
        if p["fp"]:
            tls_settings["fingerprint"] = p["fp"]
        if p["alpn"]:
            tls_settings["alpn"] = p["alpn"].split(",")
        stream_settings["security"] = "tls"
        stream_settings["tlsSettings"] = tls_settings
    elif p["security"] in ("none", ""):
        pass
    else:
        raise NotImplementedError(f"security {p['security']!r} is not supported")

    return {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
            "vnext": [{"address": p["host"], "port": p["port"], "users": [user]}]
        },
        "streamSettings": stream_settings,
        "mux": {"enabled": False, "concurrency": -1},
    }


def build_gateway_config(proxy_outbound: dict) -> dict:
    # Everything below (log/dns/inbound/direct/block/routing) is the same
    # tun-gateway template used by config/xray/config.json. It is unrelated
    # to the vless link -- it governs how THIS xray instance listens and
    # routes, not which server it connects through.
    return {
        "log": {"loglevel": "warning"},
        "dns": {
            "hosts": {
                "dns.google": "8.8.8.8",
                "proxy.example.com": "127.0.0.1",
            },
            "servers": [
                {
                    "address": "1.1.1.1",
                    "skipFallback": True,
                    "domains": ["domain:googleapis.cn", "domain:gstatic.com"],
                },
                {
                    "address": "223.5.5.5",
                    "skipFallback": True,
                    "domains": ["geosite:cn"],
                    "expectIPs": ["geoip:cn"],
                },
                "1.1.1.1",
                "8.8.8.8",
                "https://dns.google/dns-query",
            ],
        },
        "inbounds": [
            {
                "tag": "tun-in",
                "protocol": "tun",
                "settings": {
                    "name": "tun0",
                    "mtu": 9000,
                    "gateway": ["198.18.0.1/15"],
                    "autoSystemRoutingTable": ["0.0.0.0/0"],
                    "autoOutboundsInterface": "auto",
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"],
                    "routeOnly": False,
                },
            }
        ],
        "outbounds": [
            proxy_outbound,
            {"tag": "direct", "protocol": "freedom"},
            {"tag": "block", "protocol": "blackhole"},
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {
                    "type": "field",
                    "outboundTag": "proxy",
                    "domain": ["domain:googleapis.cn", "domain:gstatic.com"],
                },
                {
                    "type": "field",
                    "port": "443",
                    "network": "udp",
                    "outboundTag": "block",
                },
                {"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]},
                {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": ["geosite:private"],
                },
                {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": [
                        "223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1",
                        "119.29.29.29", "1.12.12.12", "120.53.53.53", "2402:4e00::",
                        "2402:4e00:1::", "180.76.76.76", "2400:da00::6666",
                        "114.114.114.114", "114.114.115.115", "114.114.114.119",
                        "114.114.115.119", "114.114.114.110", "114.114.115.110",
                        "180.184.1.1", "180.184.2.2", "101.226.4.6", "218.30.118.6",
                        "123.125.81.6", "140.207.198.6", "1.2.4.8", "210.2.4.8",
                        "52.80.66.66", "117.50.22.22", "2400:7fc0:849e:200::4",
                        "2404:c2c0:85d8:901::4", "117.50.10.10", "52.80.52.52",
                        "2400:7fc0:849e:200::8", "2404:c2c0:85d8:901::8",
                        "117.50.60.30", "52.80.60.30",
                    ],
                },
                {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": [
                        "domain:alidns.com", "domain:doh.pub", "domain:dot.pub",
                        "domain:360.cn", "domain:onedns.net",
                    ],
                },
                {"type": "field", "outboundTag": "direct", "ip": ["geoip:cn"]},
                {"type": "field", "outboundTag": "direct", "domain": ["geosite:cn"]},
            ],
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Convert a vless:// link into a tun-gw config.json"
    )
    ap.add_argument("link", help="a vless:// share link (quote it in the shell)")
    ap.add_argument(
        "-o", "--output", default="config_target.json",
        help="output path (default: config_target.json)",
    )
    args = ap.parse_args()

    parsed = parse_vless_link(args.link)
    outbound = build_proxy_outbound(parsed)
    config = build_gateway_config(outbound)

    with open(args.output, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"wrote {args.output}", file=sys.stderr)
    if parsed["remark"]:
        print(f"remark: {parsed['remark']}", file=sys.stderr)


if __name__ == "__main__":
    main()
