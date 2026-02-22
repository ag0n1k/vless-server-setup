#!/usr/bin/env bash
set -euo pipefail

# === ПАРАМЕТРЫ ===
TUN_IF="${TUN_IF:-tun0}"                 # интерфейс OpenVPN
SB_CFG="${SB_CFG:-/etc/sing-box/config.json}"
TPROXY_PORT="${TPROXY_PORT:-7895}"       # локальный порт sing-box tproxy inbound
FWMARK="${FWMARK:-1}"
RT_TABLE="${RT_TABLE:-100}"

# детект исходящего интерфейса (в интернет)
PUBLIC_IFACE="${PUBLIC_IFACE:-$(ip route show default 0.0.0.0/0 | awk '{print $5; exit}')}"
if [[ -z "${PUBLIC_IFACE}" ]]; then
  echo "Cannot detect PUBLIC_IFACE. Set it manually: PUBLIC_IFACE=eth0 $0" >&2
  exit 1
fi

# === ЗАВИСИМОСТИ ===
apt-get update
apt-get install -y --no-install-recommends nftables jq iproute2

# === KERNEL / sysctl ===
# Для TPROXY обычно нужно отключить rp_filter, иначе возможны странные дропы обратного трафика
cat >/etc/sysctl.d/99-vpnclients-tproxy.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.${PUBLIC_IFACE}.rp_filter=0
net.ipv4.conf.${TUN_IF}.rp_filter=0
EOF
sysctl --system >/dev/null

# На всякий: модули для tproxy (если уже встроены — будет ok)
modprobe nf_tproxy_ipv4 2>/dev/null || true
modprobe xt_TPROXY 2>/dev/null || true
modprobe nf_tproxy_core 2>/dev/null || true

# === POLICY ROUTING (обязательно для TPROXY) ===
# Классическая схема: fwmark -> отдельная таблица -> local default на lo [page:2]
ip -4 rule add fwmark "${FWMARK}" lookup "${RT_TABLE}" pref 100 2>/dev/null || true
ip -4 route add local 0.0.0.0/0 dev lo table "${RT_TABLE}" 2>/dev/null || true

# === sing-box: добавляем TPROXY inbound и правило маршрутизации по inbound ===
if [[ ! -f "${SB_CFG}" ]]; then
  echo "sing-box config not found: ${SB_CFG}" >&2
  exit 1
fi

tmp="$(mktemp)"
jq \
  --argjson port "${TPROXY_PORT}" \
  '
  .inbounds = (.inbounds // []) |
  (if (.inbounds | map(.tag) | index("tproxy-in")) != null
   then .
   else .inbounds += [{
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "listen_port": $port
   }]
   end) |
  .route = (.route // {}) |
  .route.rules = (.route.rules // []) +
    [{"inbound":["tproxy-in"], "outbound":"proxy"}]
  ' "${SB_CFG}" > "${tmp}"

install -m 0600 "${tmp}" "${SB_CFG}"
rm -f "${tmp}"

# === nftables: перехват ТОЛЬКО с tun0 + защита от утечек ===
mkdir -p /etc/nftables.d

cat > /etc/nftables.d/vpnclients-tproxy.nft <<EOF
define TUN_IF = "${TUN_IF}"
define WAN_IF = "${PUBLIC_IFACE}"
define TPROXY_PORT = ${TPROXY_PORT}
define FWMARK = ${FWMARK}

# 1) Перехватываем TCP/UDP, пришедшие с OpenVPN (tun0), в sing-box tproxy.
table inet vpnclients_tproxy {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;

    # Не трогаем локальные/приватные назначения (по желанию можно убрать/добавить CIDR)
    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } accept

    iifname \$TUN_IF meta l4proto { tcp, udp } tproxy to :\$TPROXY_PORT meta mark set \$FWMARK accept
  }
}

# 2) Leak-guard: запрещаем прямой форвардинг из VPN в интернет (если sing-box упал — интернета нет, утечек нет).
table inet vpnclients_guard {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "${TUN_IF}" oifname "${PUBLIC_IFACE}" drop
  }

  # 3) Не даём снаружи подключаться к tproxy-порту (чтобы не превратить сервер в открытый прокси).
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "${PUBLIC_IFACE}" tcp dport ${TPROXY_PORT} drop
    iifname "${PUBLIC_IFACE}" udp dport ${TPROXY_PORT} drop
  }
}
EOF

# гарантируем include
NFT_MAIN="/etc/nftables.conf"
if [[ ! -f "${NFT_MAIN}" ]]; then
  cat > "${NFT_MAIN}" <<'EOF'
#!/usr/sbin/nft -f
include "/etc/nftables.d/*.nft"
EOF
else
  if ! grep -qE 'include\s+\"/etc/nftables\.d/\*\.nft\"' "${NFT_MAIN}"; then
    echo 'include "/etc/nftables.d/*.nft"' >> "${NFT_MAIN}"
  fi
fi

systemctl enable --now nftables
nft -f "${NFT_MAIN}"

# === рестарт сервисов ===
systemctl restart sing-box || true
systemctl restart openvpn-server@server.service || true

echo "OK."
echo "PUBLIC_IFACE=${PUBLIC_IFACE}"
echo "TPROXY_PORT=${TPROXY_PORT}"
echo "Marked packets (fwmark=${FWMARK}) route via table ${RT_TABLE} -> lo [page:2]"
echo "Only traffic entering via ${TUN_IF} is transparently proxied by sing-box tproxy inbound [web:114]"

