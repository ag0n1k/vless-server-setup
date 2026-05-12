#!/usr/bin/env bash
# vpn-watch: dead-man check для vpn2, запускается на mini.local через launchd.
# Две проверки:
#   1. ping vpn2 — хост вообще жив
#   2. ssh vpn2 'curl --proxy socks5h://127.0.0.1:1080' — sing-box egress
#      работает и не WAN-leak (IP != server_public_ip)
# Алерт в TG при переходе OK→FAIL и FAIL→OK (анти-флуд через state-файл).
#
# Креды берутся из окружения: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID.
# launchd-юнит запускает через `zsh -ilc`, поэтому ~/.zshrc подсасывается
# автоматически (как у psn-watch).

set -u

STATE_FILE="${HOME}/vpn-watch/state"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "vpn-watch: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID не заданы в env" >&2
  echo "vpn-watch: для ручного теста — \`zsh -ilc '~/vpn-watch/check.sh'\`" >&2
  exit 1
fi

VPN_HOST="${VPN_HOST:-185.251.88.228}"
VPN_WAN_IP="${VPN_WAN_IP:-${VPN_HOST}}"
SSH_TARGET="${SSH_TARGET:-root@${VPN_HOST}}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
TEST_URL="${TEST_URL:-https://api.ipify.org}"

FAILS=()
EGRESS=""

# 1. Ping (macOS: -W в миллисекундах)
if ! /sbin/ping -c 3 -W 2000 "${VPN_HOST}" >/dev/null 2>&1; then
  FAILS+=("ping ${VPN_HOST}: хост не отвечает (3 пакета потеряны)")
fi

# 2. ssh + egress через sing-box
EGRESS="$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
              -o StrictHostKeyChecking=accept-new \
              "${SSH_TARGET}" \
              "curl -fsS --max-time 8 --proxy socks5h://127.0.0.1:${SOCKS_PORT} ${TEST_URL}" \
          2>/dev/null || true)"
EGRESS="${EGRESS//[$'\t\r\n ']}"

if [[ -z "${EGRESS}" ]]; then
  FAILS+=("egress: ssh+curl с ${VPN_HOST} ничего не вернул (ssh down или sing-box down)")
elif [[ "${EGRESS}" == "${VPN_WAN_IP}" ]]; then
  FAILS+=("LEAK: egress IP == WAN_IP (${EGRESS}) — трафик идёт напрямую через WAN")
fi

# ── Анти-флуд: алерт только при изменении состояния ──────────────────
mkdir -p "$(dirname "${STATE_FILE}")"
LAST="$(cat "${STATE_FILE}" 2>/dev/null || echo unknown)"
TS="$(date -u +%FT%TZ)"

send_tg() {
  curl -fsS --max-time 10 \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" \
    --data-urlencode "text=$1" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null
}

esc_html() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

if [[ "${#FAILS[@]}" -eq 0 ]]; then
  echo "${TS} vpn-watch OK (egress=${EGRESS})"
  if [[ "${LAST}" == "fail" ]]; then
    send_tg "✅ <b>vpn2 recovered</b>
<i>${TS}</i>

Egress: <code>$(printf '%s' "${EGRESS}" | esc_html)</code>"
  fi
  echo ok >"${STATE_FILE}"
  exit 0
fi

echo "${TS} vpn-watch FAIL: ${FAILS[*]}" >&2

if [[ "${LAST}" != "fail" ]]; then
  BODY=""
  for f in "${FAILS[@]}"; do
    BODY+="$(printf '%s\n' "${f}" | esc_html)"
  done
  send_tg "🚨 <b>vpn2 dead-man alert</b>
<i>${TS}</i>

<pre>${BODY}</pre>" || true
fi
echo fail >"${STATE_FILE}"
exit 1
