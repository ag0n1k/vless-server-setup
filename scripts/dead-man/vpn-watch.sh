#!/usr/bin/env bash
# vpn-watch: dead-man check для vpn2, запускается на mini.local через launchd.
# Две проверки:
#   1. ping vpn2 — хост вообще жив
#   2. ssh vpn2 'curl --proxy socks5h://127.0.0.1:1080' — sing-box egress
#      работает и не WAN-leak (IP != server_public_ip)
#
# Анти-флуд (двойной):
#   - ретрай ВНУТРИ одной проверки: ping/egress пробуются N раз, FAIL только
#     если все попытки мимо. Гасит одиночные EOF апстрима vpnd.io.
#   - дебаунс МЕЖДУ проверками: алерт уходит лишь после FAIL_THRESHOLD подряд
#     провалившихся прогонов; recovery-сообщение — при первом OK после алерта.
#     Это убирает парные 🚨/✅ при кратком флапе egress.
#
# Креды берутся из ~/vpn-watch/.env (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID) —
# отдельный файл, чтобы launchd мог запускать НЕинтерактивный shell и не тянуть
# powerlevel10k/oh-my-zsh (раньше через `zsh -ilc` сыпался gitstatus-спам в лог).
# Фоллбэк: если .env нет, берём из текущего окружения (как при старом zsh -ilc).

set -u

WATCH_DIR="${HOME}/vpn-watch"
COUNTER_FILE="${WATCH_DIR}/fails"      # счётчик подряд-провалов
NOTIFIED_FLAG="${WATCH_DIR}/notified"  # флаг «уже звонили в этом инциденте»

# Креды: сначала .env, иначе — что есть в env.
if [[ -r "${WATCH_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  source "${WATCH_DIR}/.env"
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "vpn-watch: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID не заданы" >&2
  echo "vpn-watch: положи их в ${WATCH_DIR}/.env (export VAR=...)" >&2
  exit 1
fi

VPN_HOST="${VPN_HOST:-185.251.88.228}"
VPN_WAN_IP="${VPN_WAN_IP:-${VPN_HOST}}"
SSH_TARGET="${SSH_TARGET:-root@${VPN_HOST}}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
TEST_URL="${TEST_URL:-https://api.ipify.org}"

# Анти-флуд параметры.
PING_TRIES="${PING_TRIES:-2}"             # попыток ping (каждая = 3 пакета)
EGRESS_TRIES="${EGRESS_TRIES:-3}"         # попыток egress-пробы
RETRY_DELAY="${RETRY_DELAY:-3}"           # пауза между попытками, сек
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"     # подряд-провалов до алерта

FAILS=()
EGRESS=""

# 1. Ping (macOS: -W в миллисекундах). Ретрай: PING_TRIES попыток.
ping_ok=0
for ((t = 1; t <= PING_TRIES; t++)); do
  if /sbin/ping -c 3 -W 2000 "${VPN_HOST}" >/dev/null 2>&1; then
    ping_ok=1
    break
  fi
  [[ "${t}" -lt "${PING_TRIES}" ]] && sleep "${RETRY_DELAY}"
done
[[ "${ping_ok}" -eq 0 ]] && FAILS+=("ping ${VPN_HOST}: хост не отвечает (${PING_TRIES}×3 пакета потеряны)")

# 2. ssh + egress через sing-box. Ретрай: EGRESS_TRIES попыток, успех = любая.
for ((t = 1; t <= EGRESS_TRIES; t++)); do
  EGRESS="$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
                -o StrictHostKeyChecking=accept-new \
                "${SSH_TARGET}" \
                "curl -fsS --max-time 8 --proxy socks5h://127.0.0.1:${SOCKS_PORT} ${TEST_URL}" \
            2>/dev/null || true)"
  EGRESS="${EGRESS//[$'\t\r\n ']}"
  # Чистый успех (что-то вернулось и это не WAN-IP) — выходим из ретрая.
  [[ -n "${EGRESS}" && "${EGRESS}" != "${VPN_WAN_IP}" ]] && break
  [[ "${t}" -lt "${EGRESS_TRIES}" ]] && sleep "${RETRY_DELAY}"
done

if [[ -z "${EGRESS}" ]]; then
  FAILS+=("egress: ssh+curl с ${VPN_HOST} ничего не вернул после ${EGRESS_TRIES} попыток (ssh down или sing-box down)")
elif [[ "${EGRESS}" == "${VPN_WAN_IP}" ]]; then
  FAILS+=("LEAK: egress IP == WAN_IP (${EGRESS}) — трафик идёт напрямую через WAN")
fi

# ── Анти-флуд: счётчик подряд-провалов + флаг «уже звонили» ──────────
mkdir -p "${WATCH_DIR}"
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
  echo 0 >"${COUNTER_FILE}"
  # Recovery только если в этом инциденте мы уже звонили о проблеме.
  if [[ -f "${NOTIFIED_FLAG}" ]]; then
    send_tg "✅ <b>vpn2 recovered</b>
<i>${TS}</i> (после $(cat "${NOTIFIED_FLAG}" 2>/dev/null || echo '?') провалов подряд)

Egress: <code>$(printf '%s' "${EGRESS}" | esc_html)</code>" || true
    rm -f "${NOTIFIED_FLAG}"
  fi
  exit 0
fi

echo "${TS} vpn-watch FAIL: ${FAILS[*]}" >&2

PREV=0
[[ -r "${COUNTER_FILE}" ]] && PREV="$(cat "${COUNTER_FILE}" 2>/dev/null || echo 0)"
CUR=$(( PREV + 1 ))
echo "${CUR}" >"${COUNTER_FILE}"

# Алерт только когда пересекли порог и ещё не звонили в этом инциденте.
if [[ "${CUR}" -ge "${FAIL_THRESHOLD}" && ! -f "${NOTIFIED_FLAG}" ]]; then
  echo "${CUR}" >"${NOTIFIED_FLAG}"
  BODY=""
  for f in "${FAILS[@]}"; do
    BODY+="$(printf '%s\n' "${f}" | esc_html)"
  done
  send_tg "🚨 <b>vpn2 dead-man alert</b>
<i>${TS}</i> (${CUR} провалов подряд ≥ порог ${FAIL_THRESHOLD})

<pre>${BODY}</pre>" || true
fi
exit 1
