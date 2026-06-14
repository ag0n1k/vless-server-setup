# vless-server-setup

VPN-шлюз: OpenVPN + WireGuard + WDTT клиенты заходят на VPS, исходящий трафик
заворачивается через `sing-box` (TPROXY) на внешний прокси (VLESS/Reality
или Shadowsocks из коммерческой подписки). Идея — у пользователя обычный
VPN-клиент, выход в интернет — через прокси с маскировкой.

```
[OVPN-клиенты]   ──tun0───┐
[WG-клиенты]     ──wg0────┼──> nftables (TPROXY :7895) ──> sing-box ──> внешний proxy
[WDTT-клиенты]   ──wdtt0──┘    (DTLS через VK TURN
                                для жёстких whitelist'ов)
```

Стенд управляется через **Ansible**. Боевой хост: `vpn2` — `185.251.88.228`
(Ubuntu 26.04). См. `docs/wdtt-analysis.md` — отдельный анализ родственного
проекта WDTT (proxy через VK-инфру).

---

## Быстрый старт

### Требования (локально)

- `ansible-core ≥ 2.14` (`pip install ansible-core` или `brew install ansible`)
- `ansible-vault` (идёт с ansible-core)
- SSH-доступ root к VPS (ключ в `~/.ssh/`)

### Первый запуск

```bash
# 1. Скачать vk-turn-proxy бинарь (release, без сборки)
make build-wdtt
# → .local/vk-turn-proxy ~6.8 МБ
.local/vk-turn-proxy -h    # должно показать -listen и -connect флаги

# 2. Сделать vault.yml из шаблона
cp ansible/inventory/group_vars/all/vault.yml.example ansible/inventory/group_vars/all/vault.yml
$EDITOR ansible/inventory/group_vars/all/vault.yml
# Заполнить:
#   vault_subscription_urls   — URL подписки vpnd.io
#   vault_wdtt_peer_psks      — (опционально) PSK для WDTT-пиров

# 3. Зашифровать
echo 'мой-пароль-vault' > .vault_pass
chmod 600 .vault_pass
ansible-vault encrypt ansible/inventory/group_vars/all/vault.yml --vault-password-file=.vault_pass

# 4. Открыть в панели хостера (firewall VPS): UDP 56000 на вход

# 5. Проверка → план → применение
make check
make plan
make apply
```

`make plan` важен: на хост уже накатано (вручную) много правил —
Ansible не пересоздаёт PKI, не перегенерирует WG-ключи, не трогает
существующие сертификаты. Но он **подровняет**: server.conf, CCD-файлы,
nftables-таблицы (схлопнет дубли в одну `vpn_tproxy`), fail2ban jails,
sing-box config.json.

---

## Команды

| Команда | Что делает |
|---|---|
| `make check` | синтаксическая проверка playbooks |
| `make plan` | dry-run `site.yml` с diff'ом изменений |
| `make apply` | применить `site.yml` |
| `make status` | снимок состояния сервисов и текущей ноды (read-only) |
| `make refresh-nodes` | обновить `/etc/sing-box/nodes.json` из подписки |
| `make switch INDEX=2` | переключить sing-box на ноду #2 |
| `make switch NEXT=1` | следующая нода по кругу |
| `make switch NAME=Geneva` | по подстроке label |
| `make build-wdtt` | собрать `wdtt-server` бинарь локально в `.local/` |
| `make gen-password` | сгенерировать пароль 24 байта base64 |

Добавить клиента OVPN/WG:

```bash
# OVPN
ansible-playbook ansible/playbooks/add-ovpn-client.yml -e cn=newuser
# OVPN с iroute (site-to-site)
ansible-playbook ansible/playbooks/add-ovpn-client.yml \
  -e cn=router3 -e fixed_ip=10.88.0.20 -e iroute=192.168.3.0/24

# WG (ключи генерируются локально, на сервере остаётся только pubkey)
ansible-playbook ansible/playbooks/add-wg-peer.yml -e name=phone -e wg_ip=10.188.0.10
```

После добавления WG-пира playbook выводит pubkey и PSK — добавь их
в `ansible/state/wg_peers.yml` и `ansible/inventory/group_vars/all/vault.yml`,
закоммить, прогони `make apply`.

---

## Структура

```
ansible/
├── inventory/hosts.yml         — хост vpn2
├── group_vars/all/
│   ├── vars.yml                — открытые параметры (порты, подсети)
│   ├── vault.yml               — секреты (gitignore'd)
│   └── vault.yml.example       — шаблон
├── host_vars/vpn2/vars.yml     — параметры хоста (public ip, WAN iface)
├── state/
│   ├── ovpn_peers.yml          — список OVPN-клиентов и CCD
│   └── wg_peers.yml            — публичные ключи и AllowedIPs WG-пиров
├── playbooks/
│   ├── site.yml                — основной playbook
│   ├── status.yml              — read-only проверка
│   ├── refresh-nodes.yml       — обновить nodes.json
│   ├── switch-node.yml         — переключить ноду
│   ├── add-ovpn-client.yml     — выпустить OVPN-серт
│   └── add-wg-peer.yml         — выпустить WG-ключи
└── roles/
    ├── common/                 — apt, sysctl, базовый nftables include
    ├── fail2ban/               — sshd + openvpn jails
    ├── openvpn/                — PKI bootstrap (idempotent), server.conf, CCD, NAT
    ├── wireguard/              — wg0.conf из state/wg_peers.yml, NAT
    ├── wdtt/                   — wdtt-server (DTLS через VK TURN), wdtt0 интерфейс
    ├── singbox/                — config.json из current node, парсер подписки
    └── tproxy/                 — единая nft-таблица для tun0+wg0+wdtt0, leak-guard
```

---

## Гарантии идемпотентности и сохранности

Чтобы не сломать живой хост (продакшн с боевыми OVPN/WG-клиентами):

- **PKI** — `easyrsa init-pki` запускается только если `pki/ca.crt` отсутствует.
  Существующие клиентские ключи никогда не трогаются.
- **WG server priv key** — `wg genkey` запускается только если `server.key`
  отсутствует. Если pubkey в `host_vars` не совпадает с реальным — playbook
  предупреждает (но не перезаписывает).
- **sing-box config** — если `config.json` есть, он только патчится через
  `jq` (добавляются недостающие inbound/route-правила). Полная регенерация
  только при отсутствии файла.
- **`force: false`** на копировании ключей PKI.
- **TPROXY** — старые таблицы `vpnclients_tproxy`/`vpnclients_guard`/`wg_tproxy`
  удаляются и заменяются на единую `vpn_tproxy` + `vpn_guard`.
  Дубль `ip rule fwmark` чистится перед добавлением одного правила.

`make plan` показывает diff — всегда проверять перед `make apply`.

---

## Диагностика

```bash
# на стороне VPS
systemctl status openvpn-server@server sing-box wg-quick@wg0 fail2ban
ip rule | grep fwmark
nft list ruleset
fail2ban-client status sshd

# проверка прокси работает
curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
# должен показать IP текущей ноды (vpnd.io), а не 185.251.88.228
```

---

## Что НЕ управляется через Ansible

- Телеграм-бот для генерации одноразовых паролей — отсутствует
  (был в WDTT-проекте, тут не используется).
- Бэкапы PKI — в roadmap.
