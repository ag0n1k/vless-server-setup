#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# check-proxy.sh
# Проверяет реальный IP и IP через прокси.
# Если прокси не работает / IP совпадают / утечка — сигнализирует.
#
# Exit codes:
#   0 = всё ок, прокси работает
#   1 = прокси сломан (нужна смена ноды)
# ═══════════════════════════════════════════════════════════════

: "${SOCKS_PORT:=1080}"
: "${SOCKS_HOST:=127.0.0.1}"
: "${TIMEOUT:=8}"
: "${IP_CHECK_URL:=https://api.ipify.org}"   # можно заменить на https://ifconfig.me

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info() { echo -e "        $*"; }

# ─── Получить IP ───────────────────────────────────────────────
get_real_ip() {
  curl -4 -fsSL \
    --max-time "${TIMEOUT}" \
    --connect-timeout "${TIMEOUT}" \
    "${IP_CHECK_URL}" 2>/dev/null || true
}

get_proxy_ip() {
  curl -4 -fsSL \
    --max-time "${TIMEOUT}" \
    --connect-timeout "${TIMEOUT}" \
    --proxy "socks5h://${SOCKS_HOST}:${SOCKS_PORT}" \
    "${IP_CHECK_URL}" 2>/dev/null || true
}

# ─── Проверить sing-box жив ли ────────────────────────────────
check_singbox() {
  systemctl is-active sing-box >/dev/null 2>&1
}

# ─── Валидация IP (простая) ───────────────────────────────────
is_valid_ip() {
  [[ "${1}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# ══════════════════════════════════════════════════════════════
echo "──────────────────────────────────────────"
echo " Proxy health check  $(date '+%Y-%m-%d %H:%M:%S')"
echo "──────────────────────────────────────────"

NEED_SWITCH=0
REASON=""

# 1) sing-box запущен?
if check_singbox; then
  ok "sing-box is running"
else
  fail "sing-box is NOT running"
  NEED_SWITCH=1
  REASON="sing-box is down"
fi

# 2) Реальный IP
echo
info "Checking real IP..."
REAL_IP="$(get_real_ip)"

if is_valid_ip "${REAL_IP}"; then
  ok "Real IP:  ${REAL_IP}"
else
  fail "Cannot determine real IP (no internet?)"
  REAL_IP=""
fi

# 3) IP через прокси
echo
info "Checking proxy IP (socks5h://${SOCKS_HOST}:${SOCKS_PORT})..."
PROXY_IP="$(get_proxy_ip)"

if is_valid_ip "${PROXY_IP}"; then
  ok "Proxy IP: ${PROXY_IP}"
else
  fail "Cannot get IP through proxy (timeout or connection refused)"
  PROXY_IP=""
  NEED_SWITCH=1
  REASON="${REASON:+${REASON}; }proxy returned no IP"
fi

# 4) Сравнение
echo
if [[ -n "${REAL_IP}" && -n "${PROXY_IP}" ]]; then
  if [[ "${REAL_IP}" == "${PROXY_IP}" ]]; then
    fail "IP leak detected: proxy IP == real IP (${REAL_IP})"
    fail "Traffic is NOT going through proxy!"
    NEED_SWITCH=1
    REASON="${REASON:+${REASON}; }IP leak (real==proxy)"
  else
    ok "IPs differ — traffic is routed through proxy"
    info "  real  → ${REAL_IP}"
    info "  proxy → ${PROXY_IP}"
  fi
fi

# 5) Итог
echo
echo "──────────────────────────────────────────"
if [[ "${NEED_SWITCH}" -eq 0 ]]; then
  ok "PROXY OK — no action needed"
  echo "──────────────────────────────────────────"
  exit 0
else
  fail "PROXY BROKEN — switch node needed"
  info "Reason: ${REASON}"
  echo "──────────────────────────────────────────"
  exit 1
fi

