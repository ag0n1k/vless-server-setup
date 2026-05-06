# Checkpoint — состояние работ

**Последнее обновление:** 2026-05-06
**Последний коммит:** `6e1c291` (ansible: переход с shell-скриптов…)
**Push:** не было, коммит только локально на `main`.
**Статус сервера 194.87.99.207:** не менялся, всё работает как было до 2026-05-05.

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
