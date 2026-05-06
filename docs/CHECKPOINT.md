# Checkpoint — состояние работ

**Последнее обновление:** 2026-05-06
**Последний коммит:** `7dacc93` (CHECKPOINT) → плюс новый WDTT-каркас (см. ниже)
**Push:** не было, коммиты только локально на `main`.
**Статус сервера 194.87.99.207:** не менялся, всё работает как было до 2026-05-05.

## Дополнение от 2026-05-06: WDTT-роль готова

Запрос: с iPhone/Mac заходить на vpn1 через мобильный оператор с
**белым списком VK CDN**. Решение — параллельный стек WDTT-сервер на
vpn1 (DTLS-эндпойнт 56000/udp + внутренний WG `wdtt0` 10.66.66.0/24).
Трафик после туннеля попадает в TPROXY → sing-box → vpnd.io
(как и хотел пользователь).

Что добавлено в репо:
- `ansible/roles/wdtt/` — роль с pre-flight assertions, скачиванием
  бинаря, systemd-юнитом, nft-фильтром «только из VK CDN»
- `ansible/state/wdtt_clients.yml` — список клиентов с per-client
  паролями (опционально)
- `vault.yml.example` обновлён: `vault_wdtt_master_password`,
  `vault_wdtt_client_passwords`, `vault_wg_peer_psks`
- `group_vars/all/vars.yml` — `tproxy_capture_ifaces` теперь включает
  `wdtt0` (трафик автоматически попадёт в sing-box после туннеля),
  плюс флаг `enable_wdtt: false` — роль выключена по умолчанию
- `playbooks/site.yml` — роль `wdtt` запускается только при
  `enable_wdtt=true`
- `docs/wdtt-clients.md` — инструкции по iOS (anton48-форк через
  AltStore или Apple Developer) и macOS (denny4-форк GUI или
  sicmundu-форк CLI)

Что **не сделано** и требует ручного шага перед apply:
1. **Собрать `wdtt-server` бинарь.** amurcanov не публикует Linux-сервер
   в Releases (только Android-app). Нужно:
   ```bash
   git clone https://github.com/amurcanov/proxy-turn-vk-android
   cd proxy-turn-vk-android/server
   go build -o wdtt-server
   sha256sum wdtt-server
   ```
   Бинарь залить куда-то достижимое (S3 / свой GH-Release / просто
   `scp` на vpn1 заранее), URL и sha256 — в `group_vars/all/vars.yml`:
   ```yaml
   wdtt_server_binary_url: "https://..."
   wdtt_server_binary_sha256: "abc123..."
   ```
2. **Уточнить флаги `wdtt-server`.** В `defaults/main.yml` я указал
   `wdtt_server_args` best-guess по wdtt-analysis.md. После сборки
   бинаря запустить `./wdtt-server --help`, сверить с моими `-listen`/
   `-wg-port`/`-wg-iface`/`-wg-subnet`/`-password-file`. Возможно
   флаги называются иначе — поправить в роли.
3. **Сгенерировать master-пароль:**
   ```bash
   openssl rand -base64 24
   ```
   В vault как `vault_wdtt_master_password`.
4. **Открыть UDP 56000 в firewall RuVDS** (внешний DTLS).
   `wdtt-internal-port` 56001 — внутренний, открывать снаружи не надо,
   роль и не пытается.
5. **Поставить флаг `enable_wdtt: true`** — либо в `host_vars/vpn1/vars.yml`,
   либо передать `-e enable_wdtt=true` при `make apply`.

Потенциальные проблемы которые увидим только при первом apply:
- **iptables vs nftables.** Если внутри `wdtt-server` есть hardcoded
  `iptables` вызовы для подъёма wdtt0 — на vpn1 это сработает через
  legacy-shim, но добавит ещё один источник правил. После apply надо
  проверить `iptables-save` и решить, чистить или нет.
- **wdtt0 как WG-интерфейс.** wdtt-server поднимает его сам
  (через netlink? через wg-quick?). Если через wg-quick —
  `/etc/wireguard/wdtt0.conf` появится снаружи. Если через netlink —
  интерфейс будет только в runtime, не в конфиге.
- **TPROXY на wdtt0.** Чтобы захват сработал, интерфейс должен
  существовать **до** того как nftables-таблица применится. Порядок
  ролей в `site.yml`: `wdtt` идёт **до** `tproxy` — норм.

Когда вернёшься к этому: сначала собрать бинарь и залить, потом
`make plan -e enable_wdtt=true` — увидишь весь ожидаемый diff.

---

## Где мы остановились

Подготовлен Ansible-каркас (`ansible/` + `Makefile` + `docs/MIGRATION.md`).
Старые скрипты переехали в `legacy/`. На боевом хосте ещё ничего не
прогонялось — это следующий шаг при возвращении.

## Что готово в репо

- 6 ролей: `common`, `fail2ban`, `openvpn`, `wireguard`, `singbox`, `tproxy`
- 6 плейбуков: `site.yml`, `status.yml`, `refresh-nodes.yml`,
  `switch-node.yml`, `add-ovpn-client.yml`, `add-wg-peer.yml`
- State в YAML:
  - `ansible/state/ovpn_peers.yml` — 7 текущих CN с CCD-настройками для
    `hopper`/`giga`
  - `ansible/state/wg_peers.yml` — 2 пира с pubkeys и AllowedIPs
- `ansible/group_vars/all/vault.yml.example` — шаблон для секретов
- `Makefile`, `ansible.cfg`, `.gitignore`, `.editorconfig`
- `README.md` переписан под Ansible-flow
- `docs/MIGRATION.md` — что произойдёт при первом `make apply` поверх
  живого хоста, чек-лист до/после
- `legacy/README.md` — почему старые скрипты остались как документация

YAML-валидность всех 30 ansible-файлов проверена локально.
`ansible-playbook --syntax-check` локально не запускался — ansible не
установлен на этой машине; запустится в первую очередь следующей сессией.

## Что НЕ сделано (по убыванию приоритета)

1. **Vault-инициализация.** Файл `ansible/group_vars/all/vault.yml` ещё
   не создан и не зашифрован. Без него `make plan` упадёт на
   `vault_subscription_urls is undefined`. Заготовка действий — в
   `README.md → Быстрый старт → Первый запуск` (шаги 1–3).
   Subscription URL для подстановки уже известен и подсмотрен из
   bash_history сервера: `https://vpnd.io/subscription/ss/89983b93becd88694ca2ccc9ee2556a4ad0733e560d3cb8e44179b09e39113c7/?ru=1`
   (это секрет, поэтому в репо в открытом виде НЕ кладём — только в vault).

2. **`ansible-playbook --syntax-check`.** Прогнать локально после установки
   ansible-core. Команда: `make check`.

3. **`make plan` поверх боевого хоста.** Прогнать в первую очередь — это
   read-only, ничего не меняет. Прочитать diff. Ожидаемые changes:
   - `server.conf` — смена `dh dh.pem` → `dh none` + удаление закомментированных
     строк (требует рестарт `openvpn-server@server`, ~5 сек reconnect клиентов)
   - nftables — удалятся `vpnclients_tproxy`, `vpnclients_guard`, `wg_tproxy`,
     добавятся `vpn_tproxy` + `vpn_guard` (поведение идентичное, дубли
     схлопываются)
   - `wg0.conf` — уберутся `PostUp/PostDown` с iptables (NAT уйдёт в
     `wg_nat` nft-таблицу). Может потребовать `wg-quick down/up wg0`,
     что отрубит пиров на ~10 сек.
   - `ip rule` — удалятся 2 из 3 дублей `fwmark 0x1 lookup tproxy`
   - `f2b` jails — должны быть identical (diff пустой)
   - `sing-box` config — должен быть identical (diff пустой, текущий уже
     совпадает с тем что генерит шаблон)
   Подробный гайд: `docs/MIGRATION.md`.

4. **`make apply`.** Только после внимательного прочтения diff'а от
   `make plan`. Делать в окно низкой активности (по статусу OVPN — пока
   `IphoneOlga` оффлайн и `hopper` неактивен, например ночью).

5. **Бэкап PKI и WG-ключей перед apply.** Хотя playbook их не должен
   трогать (`force: false`, `creates:`), стоит снять копию перед первым
   прогоном:
   ```bash
   ssh root@194.87.99.207 'tar czf /root/vpn-backup-$(date +%F).tgz \
     /etc/openvpn /etc/wireguard /etc/sing-box /etc/fail2ban'
   scp root@194.87.99.207:/root/vpn-backup-*.tgz ./.local-backups/
   ```

6. **Проверочный smoke-test** после apply:
   - `make status` — все 4 сервиса в `active`
   - `ssh root@194.87.99.207 'curl -s --proxy socks5h://127.0.0.1:1080 https://api.ipify.org'`
     → IP должен совпадать с одной из нод vpnd.io, не с 194.87.99.207
   - `wg show` — handshake у обоих пиров (giga был активен, hopper нет)
   - OVPN active — `cat /var/log/openvpn/status.log` показывает живые сессии

7. **Push в origin.** Только когда apply прошёл успешно и smoke-test зелёный.
   Тогда: `git push origin main`. Сейчас — НЕ пушить, репо может ещё
   потребовать правок после первого dry-run.

## Возможные подводные камни (заметки на берегу)

- **`switch-node.yml` mode=name.** Использует `range(_nodes | length)` +
  `zip` — синтаксис проверен по YAML, но логика не прогонялась. Если в
  бою упадёт — фолбэк через `--index` или ручной `ansible-vault edit`
  + `make apply`.
- **sing-box apt-package.** На боевом хосте `sing-box` стоит из
  apt-репозитория SagerNet (есть `config.json.dpkg-dist`). Роль
  `singbox` тоже пытается через apt; если репо ещё не подключён в
  /etc/apt/sources.list.d — задача `apt: name=sing-box` упадёт, и
  сработает fallback-блок (`ignore_errors: true` → выкачка с github).
  В worst case — добавить таску `apt_repository` с SagerNet ключом.
- **`tproxy` роль удаляет старые таблицы перед созданием новой.** В
  момент между `nft delete table` и `nft -f` (handler reload nftables)
  есть микро-окно, когда правил TPROXY нет → клиенты получат прямой
  выход через WAN на пару секунд. Если это критично — до apply снести
  правила вручную после fail2ban-стопа, чтобы не было ничего
  лишнего слетающего по `vpn_guard.input`.
- **`vault.yml` в `.gitignore`.** Если случайно сделаешь `git add -f
  ansible/group_vars/all/vault.yml` — закоммитишь зашифрованное (что
  ОК), но привычка нехорошая.

## Команды для возобновления

```bash
cd /Users/ag0n1k/work/github/vless-server-setup
git status                              # должно быть clean (на коммите 6e1c291)
git log --oneline -5                    # последний — ansible refactor

# Установить ansible если ещё нет
pip install --user ansible-core
# или brew install ansible

# Заполнить vault и зашифровать
cp ansible/group_vars/all/vault.yml.example ansible/group_vars/all/vault.yml
$EDITOR ansible/group_vars/all/vault.yml
echo 'pick-a-strong-password' > .vault_pass && chmod 600 .vault_pass
ansible-vault encrypt ansible/group_vars/all/vault.yml --vault-password-file=.vault_pass

# Бэкап перед чем-либо
ssh root@194.87.99.207 'tar czf /root/vpn-backup-$(date +%F).tgz /etc/openvpn /etc/wireguard /etc/sing-box /etc/fail2ban'

# Проверки
make check
make status     # read-only
make plan       # dry-run, читать diff внимательно

# Если всё ОК
make apply
```
