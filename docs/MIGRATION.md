# Миграция: shell-скрипты → Ansible (первый прогон)

Документ для **одного раза** — при приведении живого хоста
`194.87.99.207` к мастер-ветке (`main`). Описывает что playbook сделает,
что НЕ сделает, и команды по шагам.

> **Состояние сервера на момент анализа (2026-05-05):**
> 7 OVPN-клиентов в PKI, 2 WG-пира (giga, hopper), sing-box на ноде
> ch-3-tun.vpnd.io, ~70 ГБ/день через `giga`. Любая перетряска
> рестартует сервисы → клиенты переподключатся.

---

## Конфликтов с текущим OpenVPN/WG нет

Проверка по слоям:

| Слой | Сейчас | После apply | Конфликт? |
|---|---|---|---|
| Порты UDP | 1194 (OVPN), 51820 (wg0) | + 56000 (vk-turn-proxy), 51821 (wg1, only-localhost) | нет |
| Подсети | 10.88/24, 10.188/24, 192.168.1/24, 192.168.2/24 | + 10.66.66/24 (wg1) | нет |
| Интерфейсы | tun0, wg0 | + wg1 | нет (wg1 новый) |
| OVPN-клиенты | 7 в PKI, hopper/giga имеют CCD | те же 7, CCD идентичный | нет |
| WG-пиры на wg0 | giga, hopper | те же | нет |
| sing-box | tproxy:7895, текущая нода ch-3-tun | тот же конфиг, патч idempotent | нет |
| fail2ban | sshd+openvpn jails | идентично | нет |

PKI и WG-приватные ключи **не пересоздаются**: в роли стоят `creates:`
проверки, существующее не трогается.

---

## Что изменится (плановое)

### nftables (главный кусок diff'а)

Будут **удалены и пересозданы** таблицы (через `flush ruleset` в
`/etc/nftables.conf`):

- `vpnclients_tproxy`, `vpnclients_guard`, `wg_tproxy` — наследие от
  `trpoxy.sh`. Заменяются единой `vpn_tproxy` + `vpn_guard`. Поведение
  идентичное, без дублей.
- `openvpn_extra`, `openvpn_c2c` — содержали `tun0→tun0 accept`
  (client-to-client) и icmp accept. Функционал перенесён в `openvpn_filter`.
- `openvpn_filter`, `openvpn_nat` — пересоздаются с тем же содержанием.
- `wg_nat` — пересоздаётся.
- **Новые**: `wdtt_input` (только если `enable_wdtt: true`).
- `f2b-table` — flush'нется, пересоздастся fail2ban'ом при следующем
  бане. Окно ~секунды без активного банлиста, не критично.

### `/etc/openvpn/server/server.conf`

```diff
-dh /etc/openvpn/server/keys/dh.pem
+dh none
-# mssfix 1360                       (закомментировано → удалится)
-#route 192.168.1.0 ... 10.88.0.12   (закомментировано → удалится)
-#route 192.168.2.0 ... 10.88.0.13   (закомментировано → удалится)
```

DH не нужен, потому что все cipher'ы ECDHE/AEAD. После рестарта
`openvpn-server@server` клиенты переподключатся (~5 сек прерывания).

### `/etc/wireguard/wg0.conf`

```diff
-PostUp   = iptables -A FORWARD -i %i -j ACCEPT; ... -t nat -A POSTROUTING -o eth0 -j MASQUERADE
-PostDown = iptables -D FORWARD -i %i -j ACCEPT; ... -t nat -D POSTROUTING -o eth0 -j MASQUERADE
```

PostUp/PostDown с iptables уходят — NAT теперь через nftables `wg_nat`.

**ВАЖНО:** наш handler делает `wg syncconf`, а **НЕ** `wg-quick down/up`.
`syncconf` обновляет peers без drop сессий, но **не вызывает PostDown** —
старые iptables-правила MASQUERADE останутся болтаться в legacy-iptables-
shim. Они дублируют nftables-правило (двойной masquerade — идемпотентно,
но грязно).

Чистится отдельным одноразовым playbook'ом после apply (см. шаги ниже).

### `/etc/sing-box/config.json`

Должен быть **identical**: текущий конфиг уже имеет `tproxy-in` и
правило `inbound:[tproxy-in] outbound:proxy`. Наш `jq`-патч
идемпотентно проверяет наличие, не дублирует. Diff = пустой.

### Юниты systemd

- `sing-box.service` — наш юнит в `/etc/systemd/system/` переопределит
  пакетный из apt (`/lib/systemd/system/`). Содержание идентичное,
  но systemd увидит изменение источника → `daemon-reload` + restart.
  Активные TCP-сессии через прокси разорвутся. HTTPS retransmit, не
  критично.
- `vk-turn-proxy.service` — **новый** (если включён wdtt).
- `wg-quick@wg1.service` — **новый** (если включён wdtt).

---

## Пошаговая инструкция

### 0. Подготовка локально

```bash
cd /Users/ag0n1k/work/github/vless-server-setup
git status                          # должно быть clean на ветке main
git log --oneline -3
# 32b2105 wdtt: переключиться на правильный апстрим cacggghp...
# a5ac3e7 wdtt: включить роль по умолчанию...
# ccd68a0 ansible: добавить опциональную роль wdtt...

# Если ansible не установлен:
brew install ansible        # macOS
# pip install --user ansible-core
```

### 1. Скачать vk-turn-proxy бинарь

```bash
make build-wdtt
# → .local/vk-turn-proxy ~6.8 МБ
.local/vk-turn-proxy -h     # должно показать -listen и -connect
```

### 2. Vault

⚠️ **КРИТИЧНО: PSK для wg0 пиров надо обязательно достать с сервера.**
Сейчас giga и hopper подключены по WG **с PSK**. Если apply сгенерит
wg0.conf без PSK — handshake сломается и оба site-to-site линка
(LAN1 192.168.1.0/24 и LAN2 192.168.2.0/24) отвалятся. Pre-flight
в роли wireguard это поймает, но только если ты дашь ему правильные
PSK.

```bash
# 2.1. Достать PSK для всех текущих wg0-пиров с сервера
ssh root@194.87.99.207 \
  'awk "/^\\[Peer\\]/{pub=psk=\"\"} /^PublicKey/{pub=\$3} /^PresharedKey/{print pub,\$3}" \
    /etc/wireguard/wg0.conf'
# → oNhNWNriK5WPshCsDIeUwcYlPHT+pHBsbZcdRXgR0nk= <psk_giga>
# → YDoa/IQksOFO4jkyVsetK2VYNnO8At16j8KceRYR/3M= <psk_hopper>

# 2.2. Достать subscription URL (тоже из bash_history)
ssh root@194.87.99.207 'grep -oE "https://vpnd.io[^ \"]+" /root/.bash_history | head -1'

# 2.3. Создать и заполнить vault
cp ansible/inventory/group_vars/all/vault.yml.example ansible/inventory/group_vars/all/vault.yml
$EDITOR ansible/inventory/group_vars/all/vault.yml
```

Минимум для первого apply:
```yaml
vault_subscription_urls: >-
  https://vpnd.io/subscription/ss/<токен>/?ru=1

vault_wg_peer_psks:
  "oNhNWNriK5WPshCsDIeUwcYlPHT+pHBsbZcdRXgR0nk=": "<psk_giga>"
  "YDoa/IQksOFO4jkyVsetK2VYNnO8At16j8KceRYR/3M=": "<psk_hopper>"

# wdtt-peer'ы (wg1) пока пустые — ничего не отвалится, потому
# что wdtt_peers тоже пустой. Заполнишь после первого apply.
vault_wdtt_peer_psks: {}
```

```bash
# 2.4. Зашифровать
echo 'твой-долгий-vault-пароль' > .vault_pass
chmod 600 .vault_pass
ansible-vault encrypt ansible/inventory/group_vars/all/vault.yml --vault-password-file=.vault_pass
```

> **Что бывает если забыть PSK для wg0:** pre-flight assertion в
> `roles/wireguard/tasks/main.yml` упадёт ДО того как сгенерится
> новый wg0.conf, с подсказкой какой именно pubkey не хватает.
> То есть нельзя случайно убить giga/hopper.

### 3. Открыть UDP 56000 в RuVDS

В панели хостера → Firewall/Security → разрешить вход на UDP 56000.
**Это вручную, я автоматизировать не могу.**

### 4. Бэкап

```bash
mkdir -p .local-backups
ssh root@194.87.99.207 \
  'tar czf /root/vpn-backup-$(date +%F-%H%M).tgz /etc/openvpn /etc/wireguard /etc/sing-box /etc/fail2ban /etc/nftables.conf /etc/nftables.d/'
scp root@194.87.99.207:/root/vpn-backup-*.tgz .local-backups/
```

### 5. Dry-run

```bash
make check                  # синтаксис
make plan 2>&1 | tee /tmp/ansible-plan.log
```

Прочитай `/tmp/ansible-plan.log`. Должно быть:
- много `changed` в nftables (правила удалятся и пересоздадутся)
- 1× `changed` в `/etc/openvpn/server/server.conf` (dh none)
- 1× `changed` в `/etc/wireguard/wg0.conf` (без PostUp/PostDown)
- 1× `created` для `/etc/wireguard/wg1.conf`
- 1× `created` для `vk-turn-proxy.service`
- остальное должно быть `ok` (idempotent)

Если что-то выглядит подозрительно — **остановись**, спроси.

### 6. Apply

```bash
make apply
```

Время: ~3-5 минут. В процессе:
- OVPN-клиенты переподключаются 1 раз (рестарт `openvpn-server@server`)
- WG-сессии **не рвутся** (через `wg syncconf`)
- sing-box рестартанётся 1 раз (TCP-соединения разорвутся, переподключатся)
- vk-turn-proxy и wg1 поднимутся первый раз

### 7. Чистка legacy iptables

```bash
ansible-playbook ansible/playbooks/cleanup-legacy-iptables.yml \
  --vault-password-file=.vault_pass
```

Удалит висящие `iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE`
и `iptables -A FORWARD -[io] wg0 -j ACCEPT` от старого wg0 PostUp.
Сессии WG не трогает.

### 8. Проверки

```bash
make status        # сервисы должны быть active

ssh root@194.87.99.207 '
  echo "=== ip rule (должна быть ОДНА fwmark) ==="
  ip rule | grep fwmark | wc -l
  echo "=== nft tables ==="
  nft list ruleset | grep "^table" | sort
  echo "=== ovpn клиенты ==="
  cat /var/log/openvpn/status.log | grep CLIENT_LIST
  echo "=== wg ==="
  wg show
  echo "=== прокси работает? ==="
  curl -sf --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
'
```

Ожидаемое:
- `ip rule | wc -l` = 1 (раньше было 3)
- nft tables: `vpn_tproxy`, `vpn_guard`, `openvpn_filter`, `openvpn_nat`,
  `wg_nat`, `wdtt_input`, `f2b-table` (если успел fail2ban что-то записать)
- ovpn клиенты: те же что и до apply (могут переподключиться с новыми
  Connected Since)
- wg show: peer'ы giga + hopper (handshake живой) и wg1 (peers пустой
  пока нет WDTT-клиентов)
- proxy IP: nodes.vpnd.io, **не** 194.87.99.207

---

## Откат

Если что-то пошло не так:

```bash
# Восстановить конфиги из бэкапа
scp .local-backups/vpn-backup-*.tgz root@194.87.99.207:/root/
ssh root@194.87.99.207 '
  cd /
  tar xzf /root/vpn-backup-*.tgz
  systemctl restart openvpn-server@server wg-quick@wg0 sing-box fail2ban
  nft flush ruleset
  nft -f /etc/nftables.conf
'
```

Или git: `git checkout 1fb70db -- scripts/ scripts_v2/` и `bash trpoxy.sh`
(но это шаг назад, и придётся вручную).

---

## После успеха — следующие шаги (для другого захода)

1. WDTT-клиенты на iPhone/Mac — см. `docs/wdtt-clients.md`
2. Создать отдельную VK-группу и активный звонок
3. `make` `add-wdtt-peer` для каждого устройства
4. Push в `origin` (но сначала убедиться что vault.yml не уехал в коммит)
