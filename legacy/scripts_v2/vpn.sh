#!/usr/bin/env bash
set -euo pipefail

### === Настройки (можно переопределить через env) ===
: "${OVPN_PORT:=1194}"
: "${OVPN_PROTO:=udp}"                  # udp (рекомендуется) или tcp
: "${VPN_CIDR:=10.88.0.0/24}"
: "${VPN_NETMASK:=255.255.255.0}"
: "${VPN_DNS1:=1.1.1.1}"
: "${VPN_DNS2:=1.0.0.1}"
: "${CLIENT_NAME:=client1}"
: "${SERVER_PUBLIC_IP:=}"               # если пусто — попробуем определить автоматически

### === Проверки ===
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if ! command -v ip >/dev/null 2>&1; then
  echo "iproute2 not found (?)" >&2
  exit 1
fi

PUBLIC_IFACE="$(ip route show default 0.0.0.0/0 | awk '{print $5; exit}')"
if [[ -z "${PUBLIC_IFACE}" ]]; then
  echo "Can't detect default interface." >&2
  exit 1
fi

if [[ -z "${SERVER_PUBLIC_IP}" ]]; then
  # 1) пробуем взять IPv4 с интерфейса по умолчанию
  SERVER_PUBLIC_IP="$(ip -4 -o addr show dev "${PUBLIC_IFACE}" | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
fi
if [[ -z "${SERVER_PUBLIC_IP}" ]]; then
  # 2) если не вышло — пробуем через внешний сервис (можно удалить этот блок, если нельзя curl наружу)
  if command -v curl >/dev/null 2>&1; then
    SERVER_PUBLIC_IP="$(curl -4fsS https://api.ipify.org || true)"
  fi
fi
if [[ -z "${SERVER_PUBLIC_IP}" ]]; then
  echo "SERVER_PUBLIC_IP is empty. Set it like: SERVER_PUBLIC_IP=x.x.x.x $0" >&2
  exit 1
fi

echo "Public interface: ${PUBLIC_IFACE}"
echo "Server public IP: ${SERVER_PUBLIC_IP}"
echo "VPN subnet:       ${VPN_CIDR}"
echo "Client profile:   ${CLIENT_NAME}.ovpn"

### === Пакеты ===
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends openvpn easy-rsa nftables ca-certificates curl

### === Пути ===
OVPN_DIR="/etc/openvpn"
OVPN_SERVER_DIR="/etc/openvpn/server"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
KEYS_DIR="${OVPN_SERVER_DIR}/keys"

SERVER_CONF="${OVPN_SERVER_DIR}/server.conf"
CLIENT_OVPN="/root/${CLIENT_NAME}.ovpn"

mkdir -p "${OVPN_SERVER_DIR}" "${KEYS_DIR}"

if [[ -e "${SERVER_CONF}" ]]; then
  echo "ERROR: ${SERVER_CONF} already exists. Refusing to overwrite." >&2
  exit 1
fi

### === Easy-RSA (PKI) ===
rm -rf "${EASYRSA_DIR}"
mkdir -p "${EASYRSA_DIR}"
cp -a /usr/share/easy-rsa/* "${EASYRSA_DIR}/"

cd "${EASYRSA_DIR}"
./easyrsa --batch init-pki
./easyrsa --batch build-ca nopass
./easyrsa --batch gen-dh
./easyrsa --batch build-server-full server nopass
./easyrsa --batch build-client-full "${CLIENT_NAME}" nopass
./easyrsa --batch gen-crl

# tls-crypt ключ
openvpn --genkey --secret "${KEYS_DIR}/ta.key"

# Копируем ключи/серты на место
install -m 0644 "${EASYRSA_DIR}/pki/ca.crt"                 "${KEYS_DIR}/ca.crt"
install -m 0644 "${EASYRSA_DIR}/pki/dh.pem"                 "${KEYS_DIR}/dh.pem"
install -m 0644 "${EASYRSA_DIR}/pki/issued/server.crt"      "${KEYS_DIR}/server.crt"
install -m 0600 "${EASYRSA_DIR}/pki/private/server.key"     "${KEYS_DIR}/server.key"
install -m 0644 "${EASYRSA_DIR}/pki/crl.pem"                "${KEYS_DIR}/crl.pem"
chmod 0644 "${KEYS_DIR}/ta.key"

### === Конфиг сервера OpenVPN ===
cat > "${SERVER_CONF}" <<EOF
port ${OVPN_PORT}
proto ${OVPN_PROTO}
dev tun

user nobody
group nogroup
persist-key
persist-tun

topology subnet
server ${VPN_CIDR%/*} ${VPN_NETMASK}

# Full-tunnel + DNS
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${VPN_DNS1}"
push "dhcp-option DNS ${VPN_DNS2}"

# Crypto (OpenVPN 2.5+)
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256

# PKI
ca ${KEYS_DIR}/ca.crt
cert ${KEYS_DIR}/server.crt
key ${KEYS_DIR}/server.key
dh ${KEYS_DIR}/dh.pem
crl-verify ${KEYS_DIR}/crl.pem

tls-crypt ${KEYS_DIR}/ta.key

# Надёжность/сервис
keepalive 10 120
explicit-exit-notify 1

# Логи
verb 3
status /var/log/openvpn/status.log
log-append /var/log/openvpn/openvpn.log
EOF

mkdir -p /var/log/openvpn
chown -R root:root /var/log/openvpn
chmod 0755 /var/log/openvpn

### === IP forwarding ===
cat > /etc/sysctl.d/99-openvpn.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

### === nftables (NAT + forward для tun0) ===
# Не трогаем существующие ruleset'ы: создаём отдельный include-файл
mkdir -p /etc/nftables.d

cat > /etc/nftables.d/openvpn.nft <<EOF
table inet openvpn_filter {
  chain forward {
    type filter hook forward priority 0; policy accept;

    # Разрешаем форвардинг из VPN наружу и ответы обратно
    iifname "tun0" oifname "${PUBLIC_IFACE}" accept
    iifname "${PUBLIC_IFACE}" oifname "tun0" ct state established,related accept
  }
}

table ip openvpn_nat {
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    oifname "${PUBLIC_IFACE}" ip saddr ${VPN_CIDR} masquerade
  }
}
EOF

# Подключаем include в основной конфиг nftables (если ещё не подключён)
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

### === Запуск OpenVPN ===
systemctl enable --now openvpn-server@server.service
systemctl --no-pager --full status openvpn-server@server.service || true

### === Генерация client .ovpn (всё встроено) ===
extract_pem_block() {
  local begin="$1" end="$2" file="$3"
  awk "/${begin}/{flag=1} flag{print} /${end}/{flag=0}" "${file}"
}

CA_CRT="${KEYS_DIR}/ca.crt"
CLIENT_CRT="${EASYRSA_DIR}/pki/issued/${CLIENT_NAME}.crt"
CLIENT_KEY="${EASYRSA_DIR}/pki/private/${CLIENT_NAME}.key"
TA_KEY="${KEYS_DIR}/ta.key"

if [[ ! -f "${CLIENT_CRT}" || ! -f "${CLIENT_KEY}" ]]; then
  echo "Client cert/key not found for ${CLIENT_NAME}" >&2
  exit 1
fi

cat > "${CLIENT_OVPN}" <<EOF
client
dev tun
proto ${OVPN_PROTO}
remote ${SERVER_PUBLIC_IP} ${OVPN_PORT}

resolv-retry infinite
nobind
persist-key
persist-tun

remote-cert-tls server
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3

<ca>
$(cat "${CA_CRT}")
</ca>

<cert>
$(extract_pem_block "BEGIN CERTIFICATE" "END CERTIFICATE" "${CLIENT_CRT}")
</cert>

<key>
$(cat "${CLIENT_KEY}")
</key>

<tls-crypt>
$(cat "${TA_KEY}")
</tls-crypt>
EOF

chmod 0600 "${CLIENT_OVPN}"

echo
echo "DONE."
echo "Server config:   ${SERVER_CONF}"
echo "Client profile:  ${CLIENT_OVPN}"
echo "OpenVPN listen:  ${OVPN_PROTO}/${OVPN_PORT} on ${SERVER_PUBLIC_IP}"

