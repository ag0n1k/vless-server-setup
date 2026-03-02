#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# switch-node.sh — переключение ноды sing-box
#
# Режимы:
#   ./switch-node.sh              — авто: следующая нода по кругу
#   ./switch-node.sh --next       — следующая нода (явно)
#   ./switch-node.sh --first      — первая нода из списка
#   ./switch-node.sh --random     — случайная нода
#   ./switch-node.sh --name "Frankfurt"  — по подстроке label
#   ./switch-node.sh --index 3    — по номеру (1-based)
#   ./switch-node.sh --list       — показать все ноды и текущую
#   ./switch-node.sh --force      — применить текущую ноду заново
#                                   (без смены, только рестарт)
# ═══════════════════════════════════════════════════════════════

: "${NODES_FILE:=/etc/sing-box/nodes.json}"
: "${STATE_FILE:=/etc/sing-box/current-node.json}"   # хранит текущий индекс+метаданные
: "${SB_CFG:=/etc/sing-box/config.json}"
: "${SOCKS_PORT:=1080}"
: "${HEALTH_SCRIPT:=/usr/local/bin/check-proxy.sh}"  # путь к скрипту из шага 2

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }

[[ $EUID -eq 0 ]] || { fail "Run as root"; exit 1; }
[[ -f "${NODES_FILE}" ]] || { fail "nodes.json not found: ${NODES_FILE}"; exit 1; }

MODE="next"
TARGET_NAME=""
TARGET_INDEX=""

# ─── Аргументы ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --next)   MODE="next" ;;
    --first)  MODE="first" ;;
    --random) MODE="random" ;;
    --force)  MODE="force" ;;
    --list)   MODE="list" ;;
    --name)   MODE="name"; shift; TARGET_NAME="$1" ;;
    --index)  MODE="index"; shift; TARGET_INDEX="$1" ;;
    *) fail "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

# ─── Вспомогательные функции ──────────────────────────────────
node_count() {
  jq '.count' "${NODES_FILE}"
}

get_node_by_index() {
  # 0-based
  jq --argjson i "$1" '.nodes[$i]' "${NODES_FILE}"
}

get_current_index() {
  if [[ -f "${STATE_FILE}" ]]; then
    jq -r '.index // 0' "${STATE_FILE}" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

save_state() {
  local idx="$1"
  local node_json="$2"
  local label server port
  label="$(echo "${node_json}" | jq -r '.label')"
  server="$(echo "${node_json}" | jq -r '.server')"
  port="$(echo "${node_json}" | jq -r '.port')"
  jq -n \
    --argjson index "${idx}" \
    --arg label "${label}" \
    --arg server "${server}" \
    --argjson port "${port}" \
    --arg switched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{index: $index, label: $label, server: $server, port: $port, switched_at: $switched_at}' \
    > "${STATE_FILE}"
  chmod 0600 "${STATE_FILE}"
}

# ─── Список нод ───────────────────────────────────────────────
if [[ "${MODE}" == "list" ]]; then
  total=$(node_count)
  current=$(get_current_index)
  echo
  echo "  Nodes in ${NODES_FILE} (total: ${total}):"
  echo "  ─────────────────────────────────────────────────────"
  jq -r '
    .nodes | to_entries[] |
    "  #\(.key + 1)\t[\(.value.type)]\t\(.value.label)\t→ \(.value.server):\(.value.port)" +
    (if .value.security? and .value.security != "" then " [\(.value.security)]" else "" end)
  ' "${NODES_FILE}" | while IFS= read -r line; do
    idx_num=$(echo "${line}" | grep -oP '(?<=#)\d+' || true)
    if [[ $((idx_num - 1)) -eq ${current} ]]; then
      echo -e "${GREEN}${line}  ← current${NC}"
    else
      echo "  ${line}"
    fi
  done
  echo
  if [[ -f "${STATE_FILE}" ]]; then
    info "Current node state:"
    jq '.' "${STATE_FILE}"
  fi
  exit 0
fi

# ─── Выбор индекса ноды ───────────────────────────────────────
total=$(node_count)
current_idx=$(get_current_index)

case "${MODE}" in
  next)
    new_idx=$(( (current_idx + 1) % total ))
    ;;
  first)
    new_idx=0
    ;;
  random)
    new_idx=$(( RANDOM % total ))
    ;;
  force)
    new_idx=${current_idx}
    ;;
  name)
    [[ -n "${TARGET_NAME}" ]] || { fail "--name requires a value"; exit 1; }
    new_idx="$(jq --arg q "${TARGET_NAME}" '
      .nodes | to_entries[] |
      select(.value.label | ascii_downcase | contains($q | ascii_downcase)) |
      .key
    ' "${NODES_FILE}" | head -n1 || true)"
    if [[ -z "${new_idx}" ]]; then
      fail "No node matching name: ${TARGET_NAME}"
      echo "Use --list to see available nodes" >&2
      exit 1
    fi
    ;;
  index)
    [[ -n "${TARGET_INDEX}" ]] || { fail "--index requires a value"; exit 1; }
    new_idx=$(( TARGET_INDEX - 1 ))   # переводим из 1-based в 0-based
    if [[ ${new_idx} -lt 0 || ${new_idx} -ge ${total} ]]; then
      fail "Index out of range: ${TARGET_INDEX} (valid: 1–${total})"
      exit 1
    fi
    ;;
esac

node="$(get_node_by_index "${new_idx}")"
label="$(echo "${node}" | jq -r '.label')"
server="$(echo "${node}" | jq -r '.server')"
port="$(echo "${node}" | jq -r '.port')"
type="$(echo "${node}" | jq -r '.type')"

echo
info "Mode:    ${MODE}"
info "Node:    #$((new_idx + 1))/${total}  [${type}]  ${label}"
info "Server:  ${server}:${port}"
echo

# ─── Генерация конфига из ноды ────────────────────────────────
generate_config() {
  local n="$1"
  python3 - "${n}" "${SB_CFG}" "${SOCKS_PORT}" <<'PY'
import sys, json
from urllib.parse import urlsplit, parse_qs, unquote

node      = json.loads(sys.argv[1])
cfg_path  = sys.argv[2]
socks_port = int(sys.argv[3])

ntype = node["type"]

# ── VLESS ──────────────────────────────────────────────────────
if ntype == "vless":
    outbound = {
        "type": "vless",
        "tag":  "proxy",
        "server":      node["server"],
        "server_port": node["port"],
        "uuid":        node["uuid"],
        "packet_encoding": "xudp",
    }
    if node.get("flow"):
        outbound["flow"] = node["flow"]

    security = node.get("security", "")
    if security in ("tls", "reality"):
        valid_fps = {"chrome","firefox","safari","ios","android","edge","360","qq","random","randomized"}
        fp = node.get("fp", "randomized").lower()
        if fp not in valid_fps:
            fp = "randomized"

        tls = {
            "enabled": True,
            "server_name": node.get("sni") or node["server"],
            "utls": {"enabled": True, "fingerprint": fp},
        }
        if node.get("alpn"):
            tls["alpn"] = [a.strip() for a in node["alpn"].split(",") if a.strip()]
        if security == "reality":
            tls["reality"] = {
                "enabled":    True,
                "public_key": node["pbk"],
                "short_id":   node["sid"],
            }
        outbound["tls"] = tls

    transport_type = node.get("transport", "tcp")
    if transport_type == "ws":
        t = {"type": "ws"}
        if node.get("path"):    t["path"] = node["path"]
        if node.get("host_hdr"): t["headers"] = {"Host": node["host_hdr"]}
        outbound["transport"] = t
    elif transport_type == "grpc":
        outbound["transport"] = {"type": "grpc", "service_name": node.get("service_name", "")}
    elif transport_type == "http":
        t = {"type": "http"}
        if node.get("path"):     t["path"] = node["path"]
        if node.get("host_hdr"): t["host"] = [node["host_hdr"]]
        outbound["transport"] = t

# ── Shadowsocks ────────────────────────────────────────────────
elif ntype == "shadowsocks":
    outbound = {
        "type": "shadowsocks",
        "tag":  "proxy",
        "server":      node["server"],
        "server_port": node["port"],
        "method":      node["method"],
        "password":    node["password"],
        "packet_encoding": "xudp",
    }
    if node.get("plugin"):
        outbound["plugin"] = node["plugin"]
    if node.get("plugin_opts"):
        outbound["plugin_opts"] = node["plugin_opts"]
else:
    raise SystemExit(f"Unsupported node type: {ntype}")

config = {
    "log": {"level": "info"},
    "inbounds": [{
        "type": "socks", "tag": "socks-in",
        "listen": "127.0.0.1", "listen_port": socks_port
    }],
    "outbounds": [
        outbound,
        {"type": "direct", "tag": "direct"},
        {"type": "block",  "tag": "block"},
    ],
    "route": {
        "final": "proxy",
        "rules": [{
            "ip_cidr": ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"],
            "outbound": "direct"
        }]
    }
}

with open(cfg_path, "w") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
print("ok")
PY
}

info "Generating config..."
result="$(generate_config "${node}")"
if [[ "${result}" != "ok" ]]; then
  fail "Config generation failed: ${result}"; exit 1
fi
chmod 0600 "${SB_CFG}"

# ─── Валидация ────────────────────────────────────────────────
if sing-box check -c "${SB_CFG}" 2>/dev/null; then
  ok "Config valid"
else
  fail "sing-box check FAILED — aborting"
  exit 1
fi

# ─── Рестарт ──────────────────────────────────────────────────
info "Restarting sing-box..."
systemctl restart sing-box
sleep 2

if systemctl is-active sing-box >/dev/null 2>&1; then
  ok "sing-box restarted"
else
  fail "sing-box failed to start"
  journalctl -u sing-box -n 20 --no-pager >&2
  exit 1
fi

# ─── Сохраняем состояние ──────────────────────────────────────
save_state "${new_idx}" "${node}"

# ─── Быстрая проверка прокси (если есть check-proxy.sh) ───────
echo
if [[ -x "${HEALTH_SCRIPT}" ]]; then
  info "Running health check..."
  if bash "${HEALTH_SCRIPT}"; then
    ok "Node is healthy"
  else
    warn "Health check FAILED on new node #$((new_idx + 1))"
    warn "Run './switch-node.sh --next' to try next node"
  fi
else
  info "(Health check script not found at ${HEALTH_SCRIPT}, skipping)"
fi

echo
ok "Done. Active node: #$((new_idx + 1))/${total} — ${label} (${server}:${port})"

