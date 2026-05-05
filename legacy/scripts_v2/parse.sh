#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# fetch-subscription.sh
# Скачивает подписку (base64 или plain), парсит vless:// и ss://,
# нормализует, дедуплицирует и сохраняет в JSON-файл нод.
#
# Usage:
#   SUB_URLS="https://url1 https://url2" ./fetch-subscription.sh
#   или добавь несколько через пробел/перенос
# ═══════════════════════════════════════════════════════════════

: "${SUB_URLS:?Set SUB_URLS='url1 url2 ...' or pass as args}"
: "${NODES_FILE:=/etc/sing-box/nodes.json}"
: "${MIN_NODES:=1}"          # сколько нод минимально требуем; иначе не перезаписываем
: "${CURL_TIMEOUT:=15}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need curl; need python3; need jq

mkdir -p "$(dirname "${NODES_FILE}")"

# ─── Собираем ссылки из всех источников ───────────────────────
collect_links() {
  for url in ${SUB_URLS}; do
    raw="$(curl -fsSL --max-time "${CURL_TIMEOUT}" "${url}" 2>/dev/null || true)"
    [[ -z "${raw}" ]] && { echo "  [!] Failed to fetch: ${url}" >&2; continue; }

    # plain text?
    if echo "${raw}" | grep -qE '^(vless|ss|trojan|vmess)://'; then
      echo "${raw}" | tr -d '\r' | grep -E '^(vless|ss)://'
      continue
    fi

    # base64?
    decoded="$(echo "${raw}" | tr -d '\r\n ' | base64 -d 2>/dev/null || true)"
    if [[ -n "${decoded}" ]] && echo "${decoded}" | grep -qE '^(vless|ss|vmess|trojan)://'; then
      echo "${decoded}" | tr -d '\r' | grep -E '^(vless|ss)://'
      continue
    fi

    echo "  [!] Unknown format from: ${url}" >&2
  done
}

# ─── Python: parse каждую ссылку → JSON-объект ────────────────
parse_links() {
  python3 - "${1}" <<'PY'
import sys, json, base64
from urllib.parse import urlsplit, parse_qs, unquote

lines_file = sys.argv[1]
with open(lines_file) as f:
    lines = [l.strip() for l in f if l.strip()]

nodes = []

for uri in lines:
    try:
        u = urlsplit(uri)
        scheme = u.scheme.lower()

        # ── VLESS ────────────────────────────────────────────────
        if scheme == "vless":
            def q1(k, d=""):
                return parse_qs(u.query).get(k, [d])[0]

            node = {
                "type":     "vless",
                "label":    unquote(u.fragment) if u.fragment else f"{u.hostname}:{u.port}",
                "server":   u.hostname,
                "port":     int(u.port),
                "uuid":     u.username,
                "security": q1("security"),
                "flow":     q1("flow"),
                "sni":      q1("sni"),
                "fp":       q1("fp") or "randomized",
                "pbk":      q1("pbk"),
                "sid":      q1("sid"),
                "transport":q1("type", "tcp"),
                "path":     q1("path"),
                "host_hdr": q1("host"),
                "service_name": q1("serviceName") or q1("service_name"),
                "alpn":     q1("alpn"),
                "raw":      uri,
            }
            nodes.append(node)

        # ── Shadowsocks ──────────────────────────────────────────
        elif scheme == "ss":
            label = unquote(u.fragment) if u.fragment else f"{u.hostname}:{u.port}"

            def decode_userinfo(userinfo):
                try:
                    padded = userinfo + "=" * (-len(userinfo) % 4)
                    decoded = base64.urlsafe_b64decode(padded).decode()
                    if ":" in decoded:
                        m, p = decoded.split(":", 1)
                        return m, p
                except Exception:
                    pass
                if ":" in userinfo:
                    m, p = userinfo.split(":", 1)
                    return m, unquote(p)
                raise ValueError(f"Cannot parse SS userinfo: {userinfo!r}")

            host = u.hostname
            port = u.port

            # Legacy: всё тело — base64
            if not host:
                netloc = uri.split("ss://", 1)[1].split("#")[0]
                padded = netloc + "=" * (-len(netloc) % 4)
                decoded = base64.urlsafe_b64decode(padded).decode()
                userinfo_part, hostport = decoded.rsplit("@", 1)
                method, password = userinfo_part.split(":", 1)
                host, port_str = hostport.rsplit(":", 1)
                port = int(port_str)
            else:
                method, password = decode_userinfo(u.username or "")

            q2 = parse_qs(u.query)
            plugin_raw = q2.get("plugin", [""])[0]
            plugin = plugin_opts = ""
            if plugin_raw:
                parts = plugin_raw.split(";", 1)
                plugin = parts[0]
                plugin_opts = parts[1] if len(parts) > 1 else ""

            node = {
                "type":        "shadowsocks",
                "label":       label,
                "server":      host,
                "port":        int(port),
                "method":      method,
                "password":    password,
                "plugin":      plugin,
                "plugin_opts": plugin_opts,
                "raw":         uri,
            }
            nodes.append(node)

    except Exception as e:
        print(f"  [!] Parse error: {uri[:80]!r} → {e}", file=sys.stderr)

print(json.dumps(nodes, ensure_ascii=False, indent=2))
PY
}

# ─── Дедупликация по (server, port, uuid/password) ────────────
deduplicate() {
  jq '
    . as $all |
    reduce range(length) as $i (
      {"seen": [], "result": []};
      . as $acc |
      $all[$i] as $n |
      (($n.server // "") + ":" + ($n.port // 0 | tostring) +
       ":" + ($n.uuid // $n.password // "")) as $key |
      if ($acc.seen | index($key)) != null then .
      else {
        seen: ($acc.seen + [$key]),
        result: ($acc.result + [$n])
      }
      end
    ) | .result
  '
}

# ─── Основной поток ───────────────────────────────────────────
echo "Fetching subscriptions..."
tmplinks="$(mktemp)"
collect_links > "${tmplinks}"

total_raw=$(wc -l < "${tmplinks}")
echo "  raw links found: ${total_raw}"

if [[ "${total_raw}" -eq 0 ]]; then
  echo "ERROR: no links collected. Check SUB_URLS." >&2
  rm -f "${tmplinks}"
  exit 1
fi

echo "Parsing..."
parsed="$(parse_links "${tmplinks}")"
rm -f "${tmplinks}"

echo "Deduplicating..."
deduped="$(echo "${parsed}" | deduplicate)"

total=$(echo "${deduped}" | jq 'length')
echo "  unique nodes: ${total}"

if [[ "${total}" -lt "${MIN_NODES}" ]]; then
  echo "ERROR: only ${total} nodes parsed (min=${MIN_NODES}). Not overwriting ${NODES_FILE}." >&2
  exit 1
fi

# ─── Сохранение ───────────────────────────────────────────────
tmp_out="$(mktemp)"
echo "${deduped}" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{updated_at: $ts, count: length, nodes: .}' > "${tmp_out}"

chmod 0600 "${tmp_out}"
mv "${tmp_out}" "${NODES_FILE}"

echo "Saved: ${NODES_FILE}"
echo

# ─── Краткий отчёт ────────────────────────────────────────────
echo "Nodes summary:"
jq -r '
  .nodes[] |
  "  [\(.type)] \(.label) → \(.server):\(.port)" +
  (if .security? then " [\(.security)]" else "" end) +
  (if .flow? and .flow != "" then " flow=\(.flow)" else "" end)
' "${NODES_FILE}"

