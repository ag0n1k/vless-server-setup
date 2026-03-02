#!/usr/bin/env bash
set -euo pipefail

# === INPUT ===
: "${CLIENT_NAME:?Usage: CLIENT_NAME=user2 SERVER_PUBLIC_IP=x.x.x.x ./gen-client.sh}"

# === OPTIONAL ===
: "${SERVER_PUBLIC_IP:=}"                     # если пусто — попробуем определить
: "${OVPN_PORT:=1194}"
: "${OVPN_PROTO:=udp}"                        # udp/tcp
: "${EASYRSA_DIR:=/etc/openvpn/easy-rsa}"      # where ./easyrsa + pki/
: "${SERVER_KEYS_DIR:=/etc/openvpn/server/keys}"
: "${OUT_DIR:=/root/ovpn-clients}"
: "${NOPASS:=1}"                              # 1 = nopass, 0 = спросит пароль на key
: "${CIPHER:=AES-256-GCM}"
: "${DATA_CIPHERS:=AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305}"
: "${AUTH:=SHA256}"

# === Helpers ===
die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need ip
need awk
need sed
need install
need mkdir
need chmod

if [[ $EUID -ne 0 ]]; then
  die "Run as root"
fi

PKI="${EASYRSA_DIR}/pki"
EASYRSA_BIN="${EASYRSA_DIR}/easyrsa"

CA_CRT="${PKI}/ca.crt"
CLIENT_CRT="${PKI}/issued/${CLIENT_NAME}.crt"
CLIENT_KEY="${PKI}/private/${CLIENT_NAME}.key"
TA_KEY="${SERVER_KEYS_DIR}/ta.key"

[[ -x "${EASYRSA_BIN}" ]] || die "easyrsa not found/executable: ${EASYRSA_BIN}"
[[ -f "${CA_CRT}" ]] || die "CA cert not found: ${CA_CRT}"
[[ -f "${TA_KEY}" ]] || die "tls-crypt key not found: ${TA_KEY}"

# detect server public ip if needed
if [[ -z "${SERVER_PUBLIC_IP}" ]]; then
  PUBLIC_IFACE="$(ip route show default 0.0.0.0/0 | awk '{print $5; exit}')"
  SERVER_PUBLIC_IP="$(ip -4 -o addr show dev "${PUBLIC_IFACE}" | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
fi
[[ -n "${SERVER_PUBLIC_IP}" ]] || die "SERVER_PUBLIC_IP is empty; set SERVER_PUBLIC_IP=x.x.x.x"

# Basic CN validation (avoid weird filenames and openssl CN issues)
if ! [[ "${CLIENT_NAME}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  die "CLIENT_NAME must match ^[A-Za-z0-9._-]{1,64}$"
fi

# refuse overwrite existing client material
if [[ -f "${CLIENT_CRT}" || -f "${CLIENT_KEY}" ]]; then
  die "Client already exists in PKI: ${CLIENT_NAME} (crt/key present). Use a new name or revoke first."
fi

mkdir -p "${OUT_DIR}"
OUT_OVPN="${OUT_DIR}/${CLIENT_NAME}.ovpn"

extract_cert_block() {
  # выдаёт только PEM сертификат (без easy-rsa 'Bag Attributes' и т.п.)
  sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$1"
}

# === Generate client cert/key ===
pushd "${EASYRSA_DIR}" >/dev/null
if [[ "${NOPASS}" == "1" ]]; then
  ./easyrsa --batch build-client-full "${CLIENT_NAME}" nopass
else
  ./easyrsa build-client-full "${CLIENT_NAME}"
fi
popd >/dev/null

[[ -f "${CLIENT_CRT}" ]] || die "Client cert not created: ${CLIENT_CRT}"
[[ -f "${CLIENT_KEY}" ]] || die "Client key not created: ${CLIENT_KEY}"

# === Build unified .ovpn ===
cat > "${OUT_OVPN}" <<EOF
client
dev tun
proto ${OVPN_PROTO}
remote ${SERVER_PUBLIC_IP} ${OVPN_PORT}

resolv-retry infinite
nobind
persist-key
persist-tun

remote-cert-tls server
auth ${AUTH}
cipher ${CIPHER}
data-ciphers ${DATA_CIPHERS}
verb 3

<ca>
$(cat "${CA_CRT}")
</ca>

<cert>
$(extract_cert_block "${CLIENT_CRT}")
</cert>

<key>
$(cat "${CLIENT_KEY}")
</key>

<tls-crypt>
$(cat "${TA_KEY}")
</tls-crypt>
EOF

chmod 0600 "${OUT_OVPN}"

echo "OK: ${OUT_OVPN}"
echo "Tip: copy to client device securely (scp/sftp)."

