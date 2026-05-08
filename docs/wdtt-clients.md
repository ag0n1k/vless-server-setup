# WDTT-клиенты для iPhone, macOS, Android

Контекст: на vpn1 поднят `vk-turn-proxy` сервер (`roles/wdtt/`), который
слушает 56000/udp DTLS-эндпойнт и форвардит распакованный WG-payload
на локальный `wg1` (10.66.66.0/24). С устройства, сидящего за DPI с
белым списком VK CDN, нужно поднять WireGuard-туннель, инкапсулированный
в DTLS+TURN через VK CDN.

Топология на стороне устройства:

```
[iPhone/Mac/Android]
     │
     ▼  WireGuard endpoint = 127.0.0.1:9000
[локальный vk-turn-proxy клиент / форк]
     │  принимает WG-пакеты, инкапсулирует в DTLS, шлёт через TURN
     ▼
[VK TURN relay]
     │
     ▼  UDP/56000
[vpn1:56000 vk-turn-proxy сервер]
     │
     ▼  127.0.0.1:51821
[wg1 на vpn1] → TPROXY → sing-box → vpnd.io → интернет
```

Upstream-проект: <https://github.com/cacggghp/vk-turn-proxy> v1.8.x.

---

## Что нужно подготовить (общее)

1. **VK-аккаунт** (рекомендуется отдельный) и пустая VK-группа.
2. **Активный групповой звонок** в этой группе:
   - заходишь в группу → Звонки → начать групповой звонок
   - «Скопировать ссылку приглашения» → `https://vk.com/call/join/<hash>`
   - **звонок НЕ закрывать** — ссылка валидна, пока никто не нажмёт
     «Завершить для всех»
3. **Координаты vpn1**:
   - host: `194.87.99.207`
   - external port: `56000/udp`
4. **WG-конфиг для wg1**, сгенерированный на твоей машине:
   ```bash
   ansible-playbook ansible/playbooks/add-wdtt-peer.yml \
     -e name=myiphone -e wg_ip=10.66.66.10
   # → .local-peers/wdtt/myiphone.conf + pubkey/PSK для state/vault
   ```

---

## iOS — `nullcstring/turnbridge`

Репо: <https://github.com/nullcstring/turnbridge>

Это клиент iOS, рекомендованный самим cacggghp в README. Использует
`NEPacketTunnelProvider` (VPN-расширение iOS), без джейла.

**Установка** (без App Store):

1. **Apple Developer аккаунт ($99/год)** — открыть проект в Xcode,
   подписать своим Team ID, собрать и установить через USB. Профиль
   живёт год, потом перепеподписывать.
2. **AltStore + бесплатный Apple ID** — установить AltStore на Mac/PC
   (<https://altstore.io>), спарить iPhone, через AltServer установить
   .ipa из релиза `turnbridge`. Подпись живёт 7 дней, AltStore делает
   auto-refresh когда iPhone в одной Wi-Fi с Mac.

**Конфиг в приложении:**
- WG-конфиг: импортировать `.local-peers/wdtt/myiphone.conf` (QR или
  файл)
- VK invite link: `https://vk.com/call/join/<hash>`
- TURN server: `194.87.99.207:56000`
- Streams: 9 или 18 (увеличивай до 18 если канал стабильный)
- Captcha: WebView (ручной слайдер) надёжнее автоматики

---

## macOS — `denny4-user/vk-turn-proxy-macos-gui`

Репо: <https://github.com/denny4-user/vk-turn-proxy-macos-gui>

GUI-клиент под macOS, поднимает `utun`-интерфейс через
`NetworkExtension`. Подпись разработчика отсутствует — Gatekeeper
ругается, обходится так:

```bash
# Снять карантин с .app
xattr -dr com.apple.quarantine /Applications/VK\ Turn\ Proxy.app

# Если не помогает — System Settings → Privacy & Security → "Open Anyway"
```

После запуска: те же поля что и на iOS-клиенте.

### Альтернатива: CLI на macOS

В `client/main.go` репо cacggghp есть кросс-платформенный клиент Go.
Можно собрать сам:

```bash
git clone https://github.com/cacggghp/vk-turn-proxy
cd vk-turn-proxy/client
go build -o vk-turn-client
sudo ./vk-turn-client \
  -peer 194.87.99.207:56000 \
  -vk "https://vk.com/call/join/<hash>" \
  -listen 127.0.0.1:9000 \
  -workers 18
# в WG-app на маке: импортируй .local-peers/wdtt/mymac.conf,
# Endpoint должен быть = 127.0.0.1:9000 (это уже в conf'е по умолчанию)
```

Преимущество CLI — можно завернуть в `launchd`-юнит и запускать
автоматически.

---

## Android (если понадобится)

Из README cacggghp — три рекомендуемых клиента:

1. **<https://github.com/samosvalishe/turn-proxy-android>** — Material 3
   UI, авто-апдейты, Kotlin. Любимый автора cacggghp.
2. **<https://github.com/MYSOREZ/vk-turn-proxy-android>** — простой клиент.
3. **<https://github.com/kiper292/wireguard-turn-android>** — интегрирован
   в WireGuard (одно приложение).

Установка — APK из Releases, разрешить установку из неизвестных
источников.

---

## Тестирование подключения

После того как клиент подключён:

```bash
# 1. На клиенте: внешний IP должен быть от vpnd.io-ноды
curl https://api.ipify.org
# ожидаем IP ноды vpnd.io (ch-3-tun.vpnd.io / uk-2 / au-1 — текущая
# из make status), не 194.87.99.207 и не мобильный.

# 2. На клиенте: доступ к VPS-сети
ping 10.66.66.1   # это wg1 на vpn1
ssh root@10.66.66.1   # если хочется SSH через туннель

# 3. На сервере (через ssh): проверка handshake
ssh root@194.87.99.207
wg show wg1
journalctl -u vk-turn-proxy -n 20
```

---

## Если что-то ломается

| Симптом | Где смотреть |
|---|---|
| Подключение зависает на «Получение кредов» | VK-звонок закрыт / хеш мёртв — пересоздай |
| Капча в бесконечном цикле | переключи на WebView-режим (ручной слайдер) |
| `Quota Exceeded` (486) от TURN | VK-кредиты протухли, клиент сам ротирует; если не помогает — пересоздай хеш |
| `journalctl -u vk-turn-proxy` показывает `connection refused` от 51821 | wg1 не поднялся — `systemctl status wg-quick@wg1` |
| Клиент подключился, но интернета нет | TPROXY не подхватил wg1; проверь `nft list table inet vpn_tproxy` — должна быть строка про `iifname "wg1"` |
| Скорость 0 | UDP/56000 заблокирован у RuVDS или на стороне мобильного оператора (даже в VK CDN — фильтр по портам) |

---

## Безопасность

- **Master-пароля нет.** Аутентификация — только через WG (пары
  ключей + опционально PSK). Если кто-то получит твой WG `peer.conf`
  и поднимет его на своём устройстве — у него будет доступ. Не теряй
  `.local-peers/wdtt/*.conf`.
- **51821/udp на vpn1 не достижим снаружи** — закрыт nftables-DROP'ом
  (`iifname eth0 udp dport 51821 drop` в `wdtt_input`). Только через
  локальный `vk-turn-proxy` на 127.0.0.1.
- **56000/udp принимает только от VK CDN-сетей** (`set vk_cdn_v4`
  в `wdtt_input`). Open-internet сканеры на 56000 получат drop.
- **InsecureSkipVerify в DTLS** — это by design (self-signed), но это
  значит MITM на участке `client ↔ VK relay ↔ vpn1` теоретически
  возможен. WG-handshake поверх DTLS снимает эту проблему: даже
  если кто-то проксирует пакеты, без приватного ключа клиента
  валидной WG-сессии не будет.

---

## Ссылки

- Upstream сервер+клиент: <https://github.com/cacggghp/vk-turn-proxy>
- Релиз сервера: <https://github.com/cacggghp/vk-turn-proxy/releases>
- iOS клиент: <https://github.com/nullcstring/turnbridge>
- macOS клиент: <https://github.com/denny4-user/vk-turn-proxy-macos-gui>
- Android клиент: <https://github.com/samosvalishe/turn-proxy-android>
- Историческая версия архитектуры (amurcanov): [`docs/wdtt-analysis.md`](./wdtt-analysis.md)
- Серверная роль: [`ansible/roles/wdtt/`](../roles/wdtt/)
