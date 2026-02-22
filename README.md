# vless-server-setup

Here is simple server setup via scripts to setup OpenVPN server that routes all vpn traffic through VLESS proxy.

1. Setup server
2. Run vpn.sh
3. Run fail2bash.sh
4. Run vless.sh
5. Run trpoxy.sh

After, you also need to restart fail2ban:
```bash
nft delete table inet f2b-table 2>/dev/null || true
systemctl restart fail2ban
```

## Usefull commands

```
systemctl status sing-box.service

fail2ban-client  status openvpn-server
fail2ban-client  status sshd
```
