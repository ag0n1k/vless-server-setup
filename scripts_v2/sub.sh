#!/usr/bin/env bash
set -euo pipefail

: "${SUB_URL:?Usage: SUB_URL='https://...' ./add-ss.sh}"
: "${SB_CFG:=/etc/sing-box/config.json}"
: "${NODE_GREP_REGEX:=}"   # опциональный фильтр по имени/хосту ноды (regex grep -E)

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need curl; need jq; need python3; need base64

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ -f "${SB_CFG}" ]] || { echo "sing-box config not found: ${SB_CFG}" >&2; exit 1; }

# ───────────────────────────────────────────────────────────────
# 1) Скачать подписку и вытащить ss:// ссылки
# ───────────────────────────────────────────────────────────────
decode_links() {
  raw="$(curl -fsSL "${SUB_URL}")"
  # Если уже plain text
  if echo "${raw}" | grep -qE '^(ss|vless|trojan)://'; then
    echo "${raw}" | tr -d '\r' | grep -E '^ss://'
    return
  fi
  # Иначе base64
  decoded="$(echo "${raw}" | tr -d '\r\n ' | base64 -d 2>/dev/null || true)"
  [[ -n "${decoded}" ]] || { echo "Cannot decode subscription" >&2; exit 1; }
  echo "${decoded}" | tr -d '\r' | grep -E '^ss://'
}

links="$(decode_links)"
[[ -n "${links}" ]] || { echo "No ss:// links in subscription" >&2; exit 1; }

if [[ -n "${NODE_GREP_REGEX}" ]]; then
  links="$(echo "${links}" | grep -E "${NODE_GREP_REGEX}" || true)"
  [[ -n "${links}" ]] || { echo "No ss:// links matched NODE_GREP_REGEX=${NODE_GREP_REGEX}" >&2; exit 1; }
fi

# Берём первую ноду (или задай номер через env NODE_INDEX=N)
: "${NODE_INDEX:=1}"
ss_uri="$(echo "${links}" | sed -n "${NODE_INDEX}p")"
[[ -n "${ss_uri}" ]] || { echo "NODE_INDEX=${NODE_INDEX} out of range (total $(echo "${links}" | wc -l) nodes)" >&2; exit 1; }

echo "Selected: ${ss_uri}"

# ───────────────────────────────────────────────────────────────
# 2) Распарсить ss:// URI → sing-box outbound JSON
#    Поддерживаем SIP002 (новый формат) и legacy (старый Base64)
# ───────────────────────────────────────────────────────────────
python3 - <<'PY' "${ss_uri}" "${SB_CFG}"
import sys, json, base64
from urllib.parse import urlsplit, parse_qs, unquote, unquote_to_bytes

uri = sys.argv[1].strip()
cfg_path = sys.argv[2]

u = urlsplit(uri)
if u.scheme != "ss":
    raise SystemExit("Not a ss:// URI")

host = u.hostname
port = u.port
tag_name = unquote(u.fragment) if u.fragment else f"ss-{host}:{port}"

def decode_userinfo(userinfo: str):
    """
    SIP002: userinfo = base64url(method:password)  ИЛИ  plain method:password
    Legacy: whole authority is base64(method:password@host:port)
    """
    # Пробуем base64url → method:password
    try:
        padded = userinfo + "=" * (-len(userinfo) % 4)
        decoded = base64.urlsafe_b64decode(padded).decode()
        if ":" in decoded:
            method, password = decoded.split(":", 1)
            return method, password
    except Exception:
        pass
    # Пробуем plain method:password
    if ":" in userinfo:
        method, password = userinfo.split(":", 1)
        return method, unquote(password)
    raise SystemExit(f"Cannot parse userinfo: {userinfo!r}")

# SIP002: у uri есть hostname → userinfo = u.username (encoded)
# Legacy: у uri нет hostname (всё в netloc как base64)
if host:
    method, password = decode_userinfo(u.username or "")
else:
    # Legacy: base64(method:password@host:port)
    netloc = uri.split("ss://", 1)[1].split("#")[0]
    padded = netloc + "=" * (-len(netloc) % 4)
    decoded = base64.urlsafe_b64decode(padded).decode()
    # format: method:password@host:port
    userinfo_part, hostport = decoded.rsplit("@", 1)
    method, password = userinfo_part.split(":", 1)
    host, port_str = hostport.rsplit(":", 1)
    port = int(port_str)

# Плагин (например obfs-local)
q = parse_qs(u.query)
plugin_raw = q.get("plugin", [""])[0]
plugin = ""
plugin_opts = ""
if plugin_raw:
    parts = plugin_raw.split(";", 1)
    plugin = parts[0]
    plugin_opts = parts[1] if len(parts) > 1 else ""

outbound = {
    "type": "shadowsocks",
    "tag": "proxy",
    "server": host,
    "server_port": int(port),
    "method": method,
    "password": password,
    # UDP-over-TCP полезен когда сервер не поддерживает native UDP
    "udp_over_tcp": False,
    # XUDP для хорошего UDP (аналог VLESS xudp)
    "packet_encoding": "xudp",
}

if plugin:
    outbound["plugin"] = plugin
if plugin_opts:
    outbound["plugin_opts"] = plugin_opts

# ─── Патчим конфиг: заменяем/добавляем outbound с tag "proxy" ───
with open(cfg_path) as f:
    config = json.load(f)

outbounds = config.get("outbounds", [])
existing = [i for i, o in enumerate(outbounds) if o.get("tag") == "proxy"]
if existing:
    old = outbounds[existing[0]]
    print(f"Replacing outbound 'proxy' (was type={old.get('type')}) → type=shadowsocks")
    outbounds[existing[0]] = outbound
else:
    print("Adding new outbound 'proxy' (type=shadowsocks)")
    outbounds.insert(0, outbound)

config["outbounds"] = outbounds

with open(cfg_path, "w") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

print(f"OK: {cfg_path}")
print(f"  server:   {host}:{port}")
print(f"  method:   {method}")
print(f"  tag:      {tag_name}")
if plugin:
    print(f"  plugin:   {plugin} ({plugin_opts})")
PY

# ───────────────────────────────────────────────────────────────
# 3) Перезапустить sing-box
# ───────────────────────────────────────────────────────────────
systemctl restart sing-box
sleep 1

echo
echo "Test:"
echo "  curl -fsS --proxy socks5h://127.0.0.1:1080 https://api.ipify.org; echo"

