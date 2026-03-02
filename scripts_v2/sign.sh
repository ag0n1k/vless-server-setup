#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# Usage:
#   VLESS_URI='vless://...' ./vless2singbox.sh
#   или передай как аргумент:
#   ./vless2singbox.sh 'vless://...'
# ═══════════════════════════════════════════════════════════════

VLESS_URI="${1:-${VLESS_URI:-}}"
: "${VLESS_URI:?Provide VLESS_URI as env or first argument}"

: "${SB_CFG:=/etc/sing-box/config.json}"
: "${SOCKS_PORT:=1080}"
: "${RESTART_SERVICE:=1}"   # 1 = рестартовать sing-box после записи конфига

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need python3
need jq

[[ $EUID -eq 0 ]] || { echo "Run as root (or set RESTART_SERVICE=0 and change SB_CFG path)" >&2; exit 1; }

mkdir -p "$(dirname "${SB_CFG}")"

# ─── Python: parse vless:// → sing-box outbound JSON ──────────
python3 - "${VLESS_URI}" "${SB_CFG}" "${SOCKS_PORT}" <<'PY'
import sys, json
from urllib.parse import urlsplit, parse_qs, unquote

uri        = sys.argv[1].strip()
cfg_path   = sys.argv[2]
socks_port = int(sys.argv[3])

u = urlsplit(uri)
if u.scheme != "vless":
    raise SystemExit(f"Not a vless:// URI (got scheme={u.scheme!r})")

uuid = u.username
host = u.hostname
port = u.port
label = unquote(u.fragment) if u.fragment else f"{host}:{port}"

if not uuid or not host or not port:
    raise SystemExit("URI is missing uuid / host / port")

def q1(key, default=""):
    return parse_qs(u.query).get(key, [default])[0]

security      = q1("security")          # tls | reality | none
flow          = q1("flow")              # xtls-rprx-vision | ""
sni           = q1("sni")
fp            = q1("fp")               # chrome|firefox|safari|randomized|...
pbk           = q1("pbk")              # REALITY public key
sid           = q1("sid")              # REALITY short id
net_type      = q1("type", "tcp")      # tcp|ws|grpc|http|quic
path          = q1("path")
host_hdr      = q1("host")
service_name  = q1("serviceName") or q1("service_name")
alpn_raw      = q1("alpn")             # comma-separated
encryption    = q1("encryption", "none")

# ── outbound ────────────────────────────────────────────────────
outbound = {
    "type":            "vless",
    "tag":             "proxy",
    "server":          host,
    "server_port":     port,
    "uuid":            uuid,
    "packet_encoding": "xudp",
}

if flow:
    outbound["flow"] = flow

# ── TLS / REALITY ───────────────────────────────────────────────
if security in ("tls", "reality"):
    tls = {"enabled": True}

    if sni:
        tls["server_name"] = sni
    elif host:
        tls["server_name"] = host   # fallback

    # uTLS fingerprint
    if fp:
        # sing-box принимает: chrome firefox safari ios android edge 360 qq random randomized
        valid_fps = {"chrome","firefox","safari","ios","android","edge","360","qq","random","randomized"}
        fp_clean = fp.lower()
        if fp_clean not in valid_fps:
            print(f"  [!] Unknown fp={fp!r}, using 'randomized'", file=sys.stderr)
            fp_clean = "randomized"
        tls["utls"] = {"enabled": True, "fingerprint": fp_clean}
    else:
        tls["utls"] = {"enabled": True, "fingerprint": "randomized"}

    if alpn_raw:
        tls["alpn"] = [a.strip() for a in alpn_raw.split(",") if a.strip()]

    if security == "reality":
        if not pbk or not sid:
            raise SystemExit("security=reality but pbk/sid missing in URI")
        tls["reality"] = {"enabled": True, "public_key": pbk, "short_id": sid}

    outbound["tls"] = tls

# ── V2Ray transport ─────────────────────────────────────────────
transport = None
if net_type == "ws":
    transport = {"type": "ws"}
    if path:
        transport["path"] = path
    if host_hdr:
        transport["headers"] = {"Host": host_hdr}
elif net_type == "grpc":
    if not service_name:
        raise SystemExit("type=grpc but serviceName is missing")
    transport = {"type": "grpc", "service_name": service_name}
elif net_type == "http":
    transport = {"type": "http"}
    if path:
        transport["path"] = path
    if host_hdr:
        transport["host"] = [host_hdr]
elif net_type in ("tcp", "", None):
    pass  # no transport block needed
else:
    print(f"  [!] Unknown transport type={net_type!r} — skipping transport block", file=sys.stderr)

if transport:
    outbound["transport"] = transport

# ── Full config ─────────────────────────────────────────────────
config = {
    "log": {"level": "info"},
    "inbounds": [
        {
            "type":        "socks",
            "tag":         "socks-in",
            "listen":      "127.0.0.1",
            "listen_port": socks_port
        }
    ],
    "outbounds": [
        outbound,
        {"type": "direct", "tag": "direct"},
        {"type": "block",  "tag": "block"}
    ],
    "route": {
        "final": "proxy",
        "rules": [
            {
                "ip_cidr": [
                    "127.0.0.0/8",
                    "10.0.0.0/8",
                    "172.16.0.0/12",
                    "192.168.0.0/16"
                ],
                "outbound": "direct"
            }
        ]
    }
}

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

print(f"Written: {cfg_path}")
print(f"  label:     {label}")
print(f"  server:    {host}:{port}")
print(f"  uuid:      {uuid[:8]}...{uuid[-4:]}")
print(f"  security:  {security or 'none'}")
print(f"  flow:      {flow or '—'}")
print(f"  transport: {net_type or 'tcp'}")
print(f"  socks5:    127.0.0.1:{socks_port}")
PY

chmod 0600 "${SB_CFG}"

# Валидация конфига
if sing-box check -c "${SB_CFG}" 2>/dev/null; then
    echo "Config validation: OK"
else
    echo "[!] sing-box check failed — проверь конфиг вручную" >&2
fi

if [[ "${RESTART_SERVICE}" == "1" ]]; then
    systemctl restart sing-box
    sleep 1
    echo
    echo "Service status:"
    systemctl is-active sing-box && echo "  sing-box: running" || echo "  sing-box: FAILED"
    echo
    echo "Test:"
    echo "  curl -fsS --proxy socks5h://127.0.0.1:${SOCKS_PORT} https://api.ipify.org; echo"
fi

