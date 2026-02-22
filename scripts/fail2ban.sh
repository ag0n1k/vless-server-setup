#!/usr/bin/env bash
set -euo pipefail

# --- tunables ---
: "${OVPN_PORT:=1194}"
: "${OVPN_PROTO:=udp}"          # udp or tcp
: "${OVPN_LOG:=/var/log/openvpn/openvpn.log}"

: "${SSH_MAXRETRY:=2}"
: "${SSH_FINDTIME:=10m}"
: "${SSH_BANTIME:=72h}"

: "${OVPN_MAXRETRY:=6}"
: "${OVPN_FINDTIME:=10m}"
: "${OVPN_BANTIME:=6h}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends fail2ban

mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d

# --- global defaults: prefer nftables ---
cat >/etc/fail2ban/jail.d/00-defaults.local <<'EOF'
[DEFAULT]
# Use nftables (Ubuntu uses nftables by default)
banaction = nftables-multiport[blocktype=drop]
banaction_allports = nftables-allports[blocktype=drop]

# Reduce noise from local/private nets
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
EOF

# --- sshd jail ---
cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
maxretry = ${SSH_MAXRETRY}
findtime = ${SSH_FINDTIME}
bantime  = ${SSH_BANTIME}
EOF

# --- OpenVPN filter (classic OpenVPN community server logs) ---
cat >/etc/fail2ban/filter.d/openvpn-server.local <<'EOF'
[Definition]
# Matches common OpenVPN auth/TLS failures that include source IP
failregex =
  ^.*TLS Error: incoming packet authentication failed from \[AF_INET\]<HOST>:[0-9]+.*$
  ^.*TLS Error: incoming packet authentication failed from <HOST>:[0-9]+.*$
  ^.*<HOST>:[0-9]{4,5} TLS Auth Error:.*$
  ^.*<HOST>:[0-9]{4,5} VERIFY ERROR:.*$
  ^.*<HOST>:[0-9]{4,5} TLS Error: TLS handshake failed.*$
  ^.*TLS Error: TLS key negotiation failed to occur within .* seconds.*\[AF_INET\]<HOST>:[0-9]+.*$

ignoreregex =
EOF

# --- OpenVPN jail ---
cat >/etc/fail2ban/jail.d/openvpn-server.local <<EOF
[openvpn-server]
enabled  = true
filter   = openvpn-server
port     = ${OVPN_PORT}
protocol = ${OVPN_PROTO}
logpath  = ${OVPN_LOG}

# File-based logs => polling is safe and predictable
backend  = polling

maxretry = ${OVPN_MAXRETRY}
findtime = ${OVPN_FINDTIME}
bantime  = ${OVPN_BANTIME}
EOF

# Ensure log exists so fail2ban can start cleanly (OpenVPN may create it later)
mkdir -p "$(dirname "${OVPN_LOG}")"
touch "${OVPN_LOG}"
chmod 0644 "${OVPN_LOG}"

systemctl enable --now fail2ban
systemctl restart fail2ban

echo "Fail2Ban status:"
fail2ban-client status || true
echo
echo "Jail list:"
fail2ban-client status | sed -n 's/.*Jail list:\s*//p' || true
echo
echo "OpenVPN jail (if enabled):"
fail2ban-client status openvpn-server || true

