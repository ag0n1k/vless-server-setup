# Миграция: shell-скрипты → Ansible

Документ для одного раза — при первом прогоне `make apply` поверх живого
хоста `194.87.99.207`. Описывает что playbook сделает с существующим
состоянием и что проверить **до** и **после**.

## Что точно не изменится

- PKI OpenVPN (`/etc/openvpn/easy-rsa/pki/`) — `easyrsa init-pki` не запустится,
  потому что `creates: pki/private` сработает.
- Серверные сертификаты `ca.crt`, `server.crt`, `server.key`, `ta.key` — копия
  идёт с `force: false`, существующие останутся.
- WireGuard `server.key` — генерация под `creates: /etc/wireguard/server.key`.
- sing-box `nodes.json` — обновляется только если файла нет; если есть —
  оставляем (для обновления — `make refresh-nodes`).
- sing-box `current-node.json` — не трогаем (это runtime-state).

## Что изменится (ожидаемо)

### `/etc/openvpn/server/server.conf`
- В существующей версии стоит `dh /etc/openvpn/server/keys/dh.pem`.
- Новая роль ставит `dh none` — потому что все cipher'ы ECDHE/AEAD,
  DH не используется.
- **Эффект**: после рестарта `openvpn-server@server` клиенты переподключатся.
  Один цикл reconnect (~5 сек). Если кто-то на видеосозвоне — заметит.
- Решение: запускать `make apply` в окно низкой активности.

### nftables
- Ансибл удалит таблицы `vpnclients_tproxy`, `vpnclients_guard`, `wg_tproxy`
  и создаст единую `vpn_tproxy` + `vpn_guard`.
- Эффект: TPROXY работает идентично, но без дублей. `iptables`-rules
  из старого `wg0.conf PostUp` тоже исчезнут после ребута wg-quick.

### `wg0.conf`
- Текущий `wg0.conf` использует `iptables ... MASQUERADE` в PostUp/PostDown.
- Новый шаблон `wg0.conf.j2` **без** PostUp/PostDown — NAT делается
  через nftables-таблицу `wg_nat`.
- Эффект: при `wg-quick reload` старые iptables-правила останутся в legacy
  ip-tables compat shim'е, могут потребовать ручной чистки.
  Альтернатива: `wg-quick down wg0 && wg-quick up wg0` (момент даунтайма
  для пиров).

### CCD
- Существующие `/etc/openvpn/ccd/{hopper,giga}` идентичны тем, что генерит
  шаблон → diff пустой.
- Для пиров `IphoneOlga`, `IpadOlga`, `iphone`, `m5`, `client1` CCD не создаётся
  (state.fixed_ip не задан).

### fail2ban
- Конфиги совпадают с текущим state — diff пустой.

### sing-box
- `config.json` будет пропатчен `jq`'ом так, чтобы tproxy-inbound и
  правило `tproxy-in → proxy` присутствовали. Сейчас они УЖЕ есть → diff пустой.
- Если в течение жизни хоста кто-то запускал `parse.sh` или `switch.sh` —
  они переписывают `config.json` целиком, теряя tproxy-inbound. Новый
  playbook `switch-node.yml` всегда сохраняет tproxy-inbound (см.
  `roles/singbox/tasks/main.yml: jq`-патч после генерации).

## Чек-лист перед `make apply`

```bash
# 1. убедиться что vault.yml зашифрован и пароль есть
ls -la ansible/group_vars/all/vault.yml .vault_pass

# 2. dry-run
make plan 2>&1 | tee /tmp/plan.log

# 3. посмотреть какие задачи будут "changed"
grep -E '(changed|TASK|RUNNING)' /tmp/plan.log

# 4. убедиться что openvpn-restart планируется только если server.conf реально меняется
grep -A2 'openvpn-server' /tmp/plan.log
```

## После `make apply`

```bash
# проверить сервисы
make status

# проверить что трафик ходит через прокси
ssh root@194.87.99.207 'curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org'
# IP должен НЕ совпадать с 194.87.99.207

# проверить количество ip rule для fwmark (должно быть ровно 1)
ssh root@194.87.99.207 'ip rule | grep -c fwmark'
```

## Если что-то пошло не так

- Конфиги бэкапятся (`backup: true` в шаблонах) — рядом лежит `.YYYY-MM-DD@...~` файл.
- Восстановление: `mv /etc/openvpn/server/server.conf.~* /etc/openvpn/server/server.conf && systemctl restart openvpn-server@server`.
- nftables — `nft list ruleset > /tmp/before.nft` снять до прогона; восстановить через `nft -f /tmp/before.nft`.
