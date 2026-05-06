# WDTT-клиенты для iPhone и macOS

Контекст: на vpn1 поднят WDTT-сервер (`roles/wdtt/`). С устройства,
сидящего за DPI с белым списком VK CDN, нужно достучаться до vpn1 через
VK TURN-relay так, чтобы DPI видел обычный VK-звонок. После туннеля
трафик попадает в `wdtt0` (10.66.66.0/24) → TPROXY → sing-box → vpnd.io.

Официальный клиент `amurcanov/proxy-turn-vk-android` существует только
для **Android**. Для iOS/macOS есть **community-форки**, ниже —
варианты с честной пометкой о качестве.

> ⚠️ Я (Claude) не проверял эти форки исходниками. Прежде чем доверять
> им трафик и токены VK-аккаунта — пройдись по коду или хотя бы
> посмотри issues/commits.

---

## Что нужно подготовить (общее)

Из `docs/wdtt-analysis.md` § «Установка»:

1. **Отдельный VK-аккаунт.** Не основной, не привязанный к карте.
   VK иногда банит за нестандартные сценарии звонков.
2. **Пустая VK-группа** (Сообщества → Создать).
3. **Активный групповой звонок** в этой группе:
   - заходишь в группу → Звонки → начать групповой звонок
   - в окне звонка: «Скопировать ссылку приглашения» → получишь
     `https://vk.com/call/join/<hash>`
   - **звонок НЕ закрывать** — хеш живёт пока комната активна
   - при выходе тапать «Просто завершить», НЕ «Завершить для всех»
4. **Координаты сервера vpn1**:
   - Host: `194.87.99.207`
   - Внешний порт WDTT (DTLS): `56000/udp`
   - Master-пароль (из `vault_wdtt_master_password`) — спросить у себя
     же из `ansible-vault view ansible/group_vars/all/vault.yml`

---

## iOS

### Вариант 1: `anton48/vk-turn-proxy-ios` (рекомендуется)

Репо: <https://github.com/anton48/vk-turn-proxy-ios>

Это форк WDTT под iOS, использует `NEPacketTunnelProvider` (VPN-расширение
iOS). Установка без джейла — только два пути:

1. **Apple Developer аккаунт ($99/год)**
   - Открыть проект в Xcode
   - Подписать своим Team ID
   - Собрать и установить через USB на iPhone
   - **Профиль живёт год**, не нужно перепеживать каждые 7 дней
2. **AltStore + бесплатный Apple ID**
   - Установить AltStore на Mac/PC: <https://altstore.io>
   - Спарить iPhone с Mac
   - Через AltServer установить .ipa из релиза форка
   - **Подпись живёт 7 дней**, AltStore делает auto-refresh когда iPhone в
     одной Wi-Fi-сети с Mac

Конфиг в приложении (типичный для WDTT):
- VK invite link: `https://vk.com/call/join/<hash>`
- Server endpoint: `194.87.99.207:56000`
- Tunnel password: `<vault_wdtt_master_password>`
- Streams (потоков): начни с 9, увеличивай до 18 если стабильно
- Captcha mode: WebView (ручной слайдер, надёжнее автоматики)

### Вариант 2: `kusha/ios-vpn-tun`

Репо: <https://github.com/kusha/ios-vpn-tun>

Альтернативный форк. Менее популярен, но ставится так же.

### Что НЕ работает на iOS

- iOS App Store: **никогда**, Apple не пропустит VPN, использующий
  чужую инфру VK без согласия VK
- TrollStore: только на iOS 14.0–16.6.1, на свежих iOS не сработает
- Sideloadly без Mac: можно, но лимит 3 sideloaded apps на бесплатном Apple ID

### Что делать с iOS-клиентом за DPI

Когда клиент уже установлен и работает:

1. На VPS уже работает sing-box с outbound через vpnd.io.
2. WDTT-туннель будет роутить **весь** трафик iPhone, включая 0.0.0.0/0.
3. Это значит iPhone будет видеть IP-адрес vpnd.io-ноды, не свой
   мобильный.
4. Если что-то на iPhone должно ходить мимо туннеля (банковские,
   локальные мессенджеры) — добавить в `Excluded Apps` в WDTT
   (вкладка «Исключения» в android-app, в iOS-форке должно быть
   аналогично).

---

## macOS

### Вариант 1: `denny4-user/vk-turn-proxy-macos-gui` (с UI)

Репо: <https://github.com/denny4-user/vk-turn-proxy-macos-gui>

GUI-приложение под macOS, поднимает свой `utun`-интерфейс через
`NetworkExtension`. Подпись разработчика обычно отсутствует — Gatekeeper
будет ругаться, обходится через:

```bash
# Снять карантин с .app
xattr -dr com.apple.quarantine /Applications/VK\ Turn\ Proxy.app

# Если не помогает — Settings → Privacy & Security → "Open Anyway"
```

После запуска: те же поля что и на iOS-клиенте.

### Вариант 2: `sicmundu/vk-turn-proxy-macos` (CLI)

Репо: <https://github.com/sicmundu/vk-turn-proxy-macos>

CLI-демон без UI. Запускается через:

```bash
brew install go
git clone https://github.com/sicmundu/vk-turn-proxy-macos
cd vk-turn-proxy-macos
go build -o vkturn
sudo ./vkturn \
  --vk "https://vk.com/call/join/<hash>" \
  --peer 194.87.99.207:56000 \
  --password '<master_password>' \
  --workers 18
```

Преимущество: можно завернуть в `launchd`-юнит и автозапуск.
Недостаток: исключения по приложениям не настроишь — туннель глобальный.

### Вариант 3: запустить Android-клиент на macOS через эмулятор

Самый «честный» путь, потому что использует официальное приложение
amurcanov:

```bash
brew install --cask android-studio
# создать эмулятор API 30+, поставить WDTT.apk туда
```

Грубо, медленно, не для постоянного использования. Только если форки
ломаются.

---

## Тестирование подключения

После того как клиент подключён:

```bash
# 1. На клиенте: проверить что внешний IP — это vpnd.io-нода
curl https://api.ipify.org
# ожидаем IP, отличный от 194.87.99.207 и от мобильного оператора

# 2. На клиенте: проверить что доступ к VPS-у работает
ssh root@10.66.66.1   # внутренний адрес vpn1 в wdtt0-сети
# ожидаем sshd на vpn1

# 3. На сервере (через ssh): убедиться что WDTT-сессия пришла
ssh root@194.87.99.207
ip addr show wdtt0
journalctl -u wdtt-server -n 50
```

---

## Если что-то ломается

| Симптом | Где смотреть |
|---|---|
| Подключение зависает на «Получение кредов» | звонок VK закрыт / хеш мёртв — пересоздай |
| Капча в бесконечном цикле | переключи на WebView-режим (ручной слайдер) |
| `Quota Exceeded` (486) | VK-кредиты протухли, клиент сделает auto-refresh; если не помогает — пересоздай хеш |
| `journalctl -u wdtt-server` показывает `connection refused` от 56001 | wdtt-server не смог поднять wdtt0; проверь capabilities в systemd-юните |
| iPhone подключился, но интернета нет | TPROXY-роль не подхватила wdtt0; проверь `nft list table inet vpn_tproxy` — там должна быть строка про `iifname "wdtt0"` |
| Скорость 0 | UDP/56000 заблокирован у vps-провайдера или у мобильного оператора. Проверь firewall RuVDS-панели |

---

## Безопасность

- Master-пароль `vault_wdtt_master_password` — единственная защита от
  чужих коннектов на 56000/udp. Даже зная IP сервера, без пароля
  никто не сможет получить WG-конфиг через `GETCONF`.
- nft-фильтр в `roles/wdtt/tasks/main.yml` дополнительно ограничивает
  входящие коннекты только из VK CDN-сетей. Если кто-то попадёт по
  серверу не через VK — DTLS-handshake даже не начнётся.
- `InsecureSkipVerify` в DTLS — это by design (self-signed cert на
  сервере), но это значит MITM на участке `client ↔ VK relay ↔ vpn1`
  возможен. Доверие держится на пароле — поэтому он должен быть
  длинный и неугадываемый.

---

## Ссылки

- Анализ архитектуры WDTT: [`docs/wdtt-analysis.md`](./wdtt-analysis.md)
- Серверная роль: [`ansible/roles/wdtt/`](../ansible/roles/wdtt/)
- Оригинальный (Android) проект: <https://github.com/amurcanov/proxy-turn-vk-android>
