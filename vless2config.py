#!/usr/bin/env python3
"""Convert a vless:// share link into a full xray config.json for tun-gw.

A vless:// link only encodes how to reach the remote proxy server (address,
port, uuid, transport/security settings) -- it says nothing about how the
local xray instance should listen or route traffic. On its own it is NOT a
usable gateway config. This script parses the link into the "proxy" outbound
and splices it into config_tun.template.json (replacing its placeholder
"proxy" outbound in place), which is what actually makes the result usable
with this gateway.

It also reads the host's /etc/resolv.conf and routes that resolver's own
search/domain suffixes (plus any --local-domain) to it, directly -- see
apply_local_dns().

Usage:
  ./vless2config.py 'vless://uuid@host:port?...#remark'   # writes config.json
  ./vless2config.py 'vless://...' -o other.json -t other-template.json
  ./vless2config.py 'vless://...' --local-domain tencentyun.com
  ./vless2config.py --refresh-dns [--local-domain ...]   # re-read resolv.conf only

Only tcp transport is supported, with reality, tls or no security -- this
matches what the gateway has actually been built and tested against.
ws/grpc/kcp/quic/xhttp transports raise a clear error rather than silently
emitting a config that looks valid but doesn't work.
"""
import argparse
import ipaddress
import json
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
DEFAULT_TEMPLATE = HERE / "config_tun.template.json"
DEFAULT_OUTPUT = HERE / "config.json"
DEFAULT_RESOLV_CONF = Path("/etc/resolv.conf")
# systemd-resolved's list of its real upstreams, for when /etc/resolv.conf
# only points at its own 127.0.0.53 stub.
RESOLVED_UPSTREAM_CONF = Path("/run/systemd/resolve/resolv.conf")
LOCAL_DNS_TAG = "local-dns"


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
    # real deployed image before adopting this shape (and still hold on 26.11.9).
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


def parse_resolv_conf(path: Path) -> tuple[list[str], list[str]]:
    """Return (nameservers, suffixes) from a resolv.conf, in file order.

    The root domain "." (as in `search .`) means "no suffix" and is dropped.
    """
    nameservers, suffixes = [], []
    for line in path.read_text().splitlines():
        fields = line.split("#", 1)[0].split(";", 1)[0].split()
        if not fields:
            continue
        if fields[0] == "nameserver" and len(fields) > 1:
            nameservers.append(fields[1])
        elif fields[0] in ("search", "domain"):
            suffixes += [d.strip(".") for d in fields[1:] if d.strip(".")]
    return nameservers, suffixes


def _is_loopback(addr: str) -> bool:
    try:
        return ipaddress.ip_address(addr.split("%", 1)[0]).is_loopback
    except ValueError:
        return False


def local_dns_servers(
    resolv_conf: Path, extra_domains: list[str]
) -> tuple[list[str], list[str]]:
    """Work out the host's own resolver(s) and which suffixes belong to it.

    A loopback nameserver (systemd-resolved's 127.0.0.53 stub) is the
    container's *own* loopback from xray's point of view, so it's swapped
    for resolved's real upstreams. IPv6 nameservers are dropped: the
    gateway's Docker network is IPv4-only.
    """
    nameservers, suffixes = parse_resolv_conf(resolv_conf)
    if nameservers and all(_is_loopback(ns) for ns in nameservers):
        if not RESOLVED_UPSTREAM_CONF.exists():
            print(
                f"warning: {resolv_conf} only lists loopback nameservers and "
                f"{RESOLVED_UPSTREAM_CONF} doesn't exist -- no local DNS split",
                file=sys.stderr,
            )
            return [], []
        nameservers, more = parse_resolv_conf(RESOLVED_UPSTREAM_CONF)
        suffixes += more

    usable = []
    for ns in nameservers:
        try:
            ip = ipaddress.ip_address(ns.split("%", 1)[0])
        except ValueError:
            continue
        if ip.version == 6 or ip.is_loopback:
            print(f"warning: skipping nameserver {ns} (not reachable from the gateway)",
                  file=sys.stderr)
            continue
        usable.append(str(ip))

    domains = list(dict.fromkeys(d.strip(".").lower() for d in suffixes + extra_domains
                                 if d.strip(".")))
    return usable, domains


def apply_local_dns(config: dict, resolv_conf: Path, extra_domains: list[str]) -> dict:
    """Route the host resolver's own suffixes to that resolver, directly.

    Split by domain, never by failure: xray's DNS module moves on to the
    next server on *any* failure (NXDOMAIN and a proxy timeout look the
    same), so a "fall back to the local resolver" server would receive
    every lookup in plaintext whenever the proxy is down.

    Idempotent: entries tagged LOCAL_DNS_TAG are replaced, not appended.
    """
    dns = config.setdefault("dns", {})
    servers = [s for s in dns.get("servers", [])
               if not (isinstance(s, dict) and s.get("tag") == LOCAL_DNS_TAG)]
    rules = [r for r in config.setdefault("routing", {}).get("rules", [])
             if r.get("inboundTag") != [LOCAL_DNS_TAG]]

    nameservers, domains = local_dns_servers(resolv_conf, extra_domains)
    if not nameservers or not domains:
        if nameservers and not domains:
            print(
                f"warning: {resolv_conf} has no search/domain suffixes and no "
                "--local-domain was given -- no local DNS split",
                file=sys.stderr,
            )
        dns["servers"] = servers
        config["routing"]["rules"] = rules
        return config

    # In front of everything (wins over e.g. geosite:private, which may also
    # list "lan"), skipped as a fallback for unrelated names, and finalQuery
    # on the last one so an internal name never goes on to a public server.
    local = [
        {"address": ns, "domains": [f"domain:{d}" for d in domains],
         "skipFallback": True, "tag": LOCAL_DNS_TAG}
        for ns in nameservers
    ]
    local[-1]["finalQuery"] = True
    dns["servers"] = local + servers

    # Before "inboundTag: dns-module -> proxy": the VPS can't reach a LAN or
    # cloud-internal resolver. Right after the dns-in rule if there is one.
    at = next((i + 1 for i, r in enumerate(rules) if r.get("inboundTag") == ["dns-in"]), 0)
    rules.insert(at, {"inboundTag": [LOCAL_DNS_TAG], "outboundTag": "direct"})
    config["routing"]["rules"] = rules

    print(f"local DNS: {', '.join(nameservers)} for {', '.join(domains)}", file=sys.stderr)
    return config


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Convert a vless:// link into a tun-gw config.json"
    )
    ap.add_argument("link", nargs="?",
                    help="a vless:// share link (quote it in the shell)")
    ap.add_argument(
        "-t", "--template", default=DEFAULT_TEMPLATE, type=Path,
        help=f"template config to splice into (default: {DEFAULT_TEMPLATE})",
    )
    ap.add_argument(
        "-o", "--output", default=DEFAULT_OUTPUT, type=Path,
        help=f"output path (default: {DEFAULT_OUTPUT})",
    )
    ap.add_argument(
        "--refresh-dns", action="store_true",
        help="no link: only re-read resolv.conf into the existing --output file",
    )
    ap.add_argument(
        "--local-domain", action="append", default=[], metavar="SUFFIX",
        help="extra suffix for the host's own resolver, e.g. tencentyun.com (repeatable)",
    )
    ap.add_argument(
        "--resolv-conf", default=DEFAULT_RESOLV_CONF, type=Path,
        help=f"resolver config to read (default: {DEFAULT_RESOLV_CONF})",
    )
    ap.add_argument(
        "--no-local-dns", action="store_true",
        help="don't add the host-resolver split at all",
    )
    args = ap.parse_args()

    if args.refresh_dns:
        if args.link:
            ap.error("--refresh-dns doesn't take a link")
        config = json.loads(args.output.read_text())
        parsed = None
    else:
        if not args.link:
            ap.error("a vless:// link is required (or use --refresh-dns)")
        template = json.loads(args.template.read_text())
        parsed = parse_vless_link(args.link)
        outbound = build_proxy_outbound(parsed)
        config = splice_outbound(template, outbound)

    if not args.no_local_dns:
        config = apply_local_dns(config, args.resolv_conf, args.local_domain)

    args.output.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")

    print(f"wrote {args.output}", file=sys.stderr)
    if parsed and parsed["remark"]:
        print(f"remark: {parsed['remark']}", file=sys.stderr)


if __name__ == "__main__":
    main()
