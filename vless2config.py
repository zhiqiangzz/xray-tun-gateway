#!/usr/bin/env python3
"""Convert a vless:// share link into a full xray config.json for tun-gw.

A vless:// link only encodes how to reach the remote proxy server (address,
port, uuid, transport/security settings) -- it says nothing about how the
local xray instance should listen or route traffic. On its own it is NOT a
usable gateway config. This script parses the link into the "proxy" outbound
and splices it into config_tun.template.json (replacing its placeholder
"proxy" outbound in place), which is what actually makes the result usable
with this gateway.

Usage:
  ./vless2config.py 'vless://uuid@host:port?...#remark'   # writes config.json
  ./vless2config.py 'vless://...' -o other.json -t other-template.json

Only tcp transport is supported, with reality, tls or no security -- this
matches what the gateway has actually been built and tested against.
ws/grpc/kcp/quic/xhttp transports raise a clear error rather than silently
emitting a config that looks valid but doesn't work.
"""
import argparse
import json
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
DEFAULT_TEMPLATE = HERE / "config_tun.template.json"
DEFAULT_OUTPUT = HERE / "config.json"


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

    # Flattened outbound settings (address/port/id directly, no vnext/users
    # wrapper) and "raw" in place of "tcp" -- matches the shape xray-core
    # 26.10.10 actually emits/accepts now; both were verified against the
    # real deployed image before adopting this shape.
    settings = {
        "address": p["host"],
        "port": p["port"],
        "id": p["uuid"],
        "encryption": p["encryption"],
    }
    if p["flow"]:
        settings["flow"] = p["flow"]

    stream_settings = {"network": "raw"}

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
            "mldsa65Verify": "",
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
        "settings": settings,
        "streamSettings": stream_settings,
        "mux": {"enabled": False, "concurrency": -1},
    }


def splice_outbound(template: dict, proxy_outbound: dict) -> dict:
    outbounds = template.get("outbounds", [])
    for i, o in enumerate(outbounds):
        if o.get("tag") == "proxy":
            outbounds[i] = proxy_outbound
            return template
    raise ValueError("template has no outbound tagged 'proxy' to replace")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Convert a vless:// link into a tun-gw config.json"
    )
    ap.add_argument("link", help="a vless:// share link (quote it in the shell)")
    ap.add_argument(
        "-t", "--template", default=DEFAULT_TEMPLATE, type=Path,
        help=f"template config to splice into (default: {DEFAULT_TEMPLATE})",
    )
    ap.add_argument(
        "-o", "--output", default=DEFAULT_OUTPUT, type=Path,
        help=f"output path (default: {DEFAULT_OUTPUT})",
    )
    args = ap.parse_args()

    template = json.loads(args.template.read_text())
    parsed = parse_vless_link(args.link)
    outbound = build_proxy_outbound(parsed)
    config = splice_outbound(template, outbound)

    args.output.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")

    print(f"wrote {args.output}", file=sys.stderr)
    if parsed["remark"]:
        print(f"remark: {parsed['remark']}", file=sys.stderr)


if __name__ == "__main__":
    main()
