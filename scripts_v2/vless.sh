#!/usr/bin/env bash
set -euo pipefail

# === ВХОДНЫЕ ПАРАМЕТРЫ (ОБЯЗАТЕЛЬНО) ===
: "${SUB_URL:?Set SUB_URL to your VLESS subscription URL, e.g. SUB_URL='https://example.com/sub' $0}"

# (опционально) выбрать ноду по имени (#fragment) или по содержимому ссылки (regex, grep -E)
: "${NODE_GREP_REGEX:=}"

# локальный socks порт
: "${SOCKS_PORT:=1080}"

# куда ставим
SB_BIN="/usr/local/bin/sing-box"
SB_DIR="/etc/sing-box"
SB_CFG="${SB_DIR}/config.json"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

need curl
need jq
need python3
need base64
need grep
need awk
need sed
need systemctl
need uname
need install
need mkdir
need chmod

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl jq python3 coreutils grep sed gawk

mkdir -p "${SB_DIR}"

install_singbox() {
  if [[ -x "${SB_BIN}" ]]; then
    echo "sing-box already installed: ${SB_BIN}"
    return
  fi

  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) asset_re='sing-box-.*-linux-amd64\.tar\.gz$' ;;
    aarch64|arm64) asset_re='sing-box-.*-linux-arm64\.tar\.gz$' ;;
    *)
      echo "Unsupported arch: ${arch}" >&2
      exit 1
      ;;
  esac

  echo "Installing sing-box (arch=${arch})..."

  rel_json="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest)"
  url="$(echo "${rel_json}" | jq -r --arg re "${asset_re}" '
    .assets[]
    | select(.name|test($re))
    | .browser_download_url
  ' | head -n1)"

  if [[ -z "${url}" || "${url}" == "null" ]]; then
    echo "Cannot find a suitable sing-box release asset for ${arch}" >&2
    exit 1
  fi

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  curl -fsSL "${url}" -o "${tmpdir}/sing-box.tgz"
  tar -xzf "${tmpdir}/sing-box.tgz" -C "${tmpdir}"

  # Внутри архива обычно каталог sing-box-<ver>-linux-<arch>/sing-box
  found_bin="$(find "${tmpdir}" -type f -name sing-box -perm -111 | head -n1 || true)"
  if [[ -z "${found_bin}" ]]; then
    echo "sing-box binary not found in the tarball" >&2
    exit 1
  fi

  install -m 0755 "${found_bin}" "${SB_BIN}"
  echo "Installed: ${SB_BIN}"
}

decode_subscription_to_links() {
  # Печатает список vless://... (по одному в строке) в stdout
  sub_raw="$(curl -fsSL "${SUB_URL}")"

  # Если это уже текст со ссылками
  if echo "${sub_raw}" | grep -qE '^vless://'; then
    echo "${sub_raw}" | tr -d '\r' | grep -E '^vless://'
    return
  fi

  # Иначе пробуем base64 decode (типичный формат подписок)
  decoded="$(echo "${sub_raw}" | tr -d '\r\n ' | base64 -d 2>/dev/null || true)"
  if [[ -z "${decoded}" ]]; then
    echo "Subscription is neither plain vless:// nor base64-decodable." >&2
    exit 1
  fi

  echo "${decoded}" | tr -d '\r' | grep -E '^vless://'
}

pick_vless_link() {
  links="$(decode_subscription_to_links)"

  if [[ -z "${links}" ]]; then
    echo "No vless:// links found in subscription." >&2
    exit 1
  fi

  if [[ -n "${NODE_GREP_REGEX}" ]]; then
    picked="$(echo "${links}" | grep -E "${NODE_GREP_REGEX}" | head -n1 || true)"
    if [[ -z "${picked}" ]]; then
      echo "No vless:// link matched NODE_GREP_REGEX=${NODE_GREP_REGEX}" >&2
      exit 1
    fi
    echo "${picked}"
    return
  fi

  echo "${links}" | head -n1
}

generate_config() {
  vless_uri="$(pick_vless_link)"

  python3 - <<'PY' "${vless_uri}" "${SOCKS_PORT}" "${SB_CFG}"
import sys, json
from urllib.parse import urlsplit, parse_qs, unquote

uri = sys.argv[1].strip()
socks_port = int(sys.argv[2])
out_path = sys.argv[3]

u = urlsplit(uri)
if u.scheme != "vless":
    raise SystemExit("Not a vless:// URI")

uuid = u.username
host = u.hostname
port = u.port

q = parse_qs(u.query)
def q1(k, default=""):
    v = q.get(k, [""])
    return v[0] if v and v[0] is not None else default

# Common v2ray-style params in VLESS URIs
encryption = q1("encryption", "none")  # usually none
flow = q1("flow", "")
security = q1("security", "")
sni = q1("sni", "")
fp = q1("fp", "")

# Reality
pbk = q1("pbk", "")   # public key
sid = q1("sid", "")   # short id

# Transport
net_type = q1("type", "")  # tcp, grpc, ws, http, quic...
path = q1("path", "")
host_hdr = q1("host", "")
service_name = q1("serviceName", q1("service_name", ""))

if not uuid or not host or not port:
    raise SystemExit("URI missing uuid/host/port")

outbound = {
    "type": "vless",
    "tag": "proxy",
    "server": host,
    "server_port": port,
    "uuid": uuid,
    # Важно для UDP через Xray-экосистему: xudp (оставляем явно).
    "packet_encoding": "xudp",
}

if flow:
    outbound["flow"] = flow

# TLS / REALITY
if security in ("tls", "reality"):
    tls = {"enabled": True}
    if sni:
        tls["server_name"] = sni
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    if security == "reality":
        # Для клиента нужны public_key и short_id (sid)
        if not pbk or not sid:
            raise SystemExit("REALITY selected but pbk/sid missing in URI")
        tls["reality"] = {"enabled": True, "public_key": pbk, "short_id": sid}
    outbound["tls"] = tls

# V2Ray transport in sing-box style
if net_type == "grpc":
    if not service_name:
        raise SystemExit("type=grpc but serviceName is missing")
    outbound["transport"] = {"type": "grpc", "service_name": service_name}
elif net_type == "ws":
    t = {"type": "ws"}
    if path:
        t["path"] = path
    if host_hdr:
        t["headers"] = {"Host": host_hdr}
    outbound["transport"] = t
elif net_type in ("", "tcp"):
    pass
else:
    raise SystemExit(f"Unsupported/unknown transport type={net_type!r}. Add handling in script if needed.")

config = {
    "log": {"level": "info"},
    "inbounds": [
        {"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": socks_port}
    ],
    "outbounds": [
        outbound,
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
    ],
    "route": {
        "final": "proxy",
        "rules": [
            # local/bypass
            {"ip_cidr": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"], "outbound": "direct"}
        ],
    },
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

print(out_path)
PY
}

install_systemd_unit() {
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box (VLESS client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -c ${SB_CFG}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now sing-box.service
}

install_singbox
generate_config
chmod 0600 "${SB_CFG}"
install_systemd_unit

echo
echo "OK."
echo "Config:   ${SB_CFG}"
echo "SOCKS5:   socks5h://127.0.0.1:${SOCKS_PORT}"
echo
echo "Test example:"
echo "  curl -fsS --proxy socks5h://127.0.0.1:${SOCKS_PORT} https://api.ipify.org ; echo"

