# useful_scripts — control node (x86, Debian 13 trixie)

## Первичная настройка control node

```bash
curl -fsSL https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/setup-control.sh | sudo bash
```

## Бэкап Woodpecker CI на Google Drive (разово / вручную)

```bash
curl -fsSL https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/backup-woodpecker.sh | sudo bash
```

Скрипт настройки интерактивный: доступ к Google Drive он настраивает сам (мастер rclone), отдельный `rclone config` запускать не нужно.
В качестве age-ключа для sops используется **SSH-ключ root** (`/root/.ssh/id_ed25519`, публичный — `id_ed25519.pub`).
Чтобы расшифровать бэкап, скрипт настройки должен получить тот же приватный SSH-ключ root, что и на старом узле; ключ не должен быть защищён паролем (иначе расшифровка в cron/восстановлении не сработает).
Ежедневный бэкап ставится в cron на 03:00 и всегда перезаписывает один и тот же файл `woodpecker/woodpecker_backup.tar.gz.enc`.

Скрипт также ставит системный часовой пояс `Europe/Moscow` (MSK, +0300) — от него зависят время в логах и запуск cron в 03:00 по Москве. Тот же пояс прокидывается в контейнеры Woodpecker: в `/opt/woodpecker/.env` есть `TIMEZONE=Europe/Moscow`, в `docker-compose.yml` в оба сервиса добавлено `TZ: ${TIMEZONE}` (функция `ensure_woodpecker_tz` идемпотентно доставляет это и в уже установленную инсталляцию, и в восстановленную из бэкапа). Без этого сервер работал в UTC, и cron-задачи Woodpecker срабатывали со сдвигом на 3 часа.

## Cron-задачи Woodpecker (плановые бэкапы)

Отдельно от системного cron хоста, в самом Woodpecker есть cron-задачи, которые запускают пайплайны из `.woodpecker/`. Задачи создаются в настройках репозитория (repo settings → Crons), **имя задачи должно точно совпадать** с фильтром `cron:` в конфиге пайплайна:

| Cron-задача | Pipeline-файл | Шаги |
| --- | --- | --- |
| `Media-backup` | `.woodpecker/media_vm_backup.yml` | `media_vm/backup` → `media_vm` |
| `Nextcloud-backup` | `.woodpecker/nextcloud_backup.yml` | `nextcloud/backup` → `nextcloud_vm` |
| `Traefik-backup` | `.woodpecker/traefik_backup.yml` | `traefik/backup` → `traefik_lxc` |
| `Valheim-backup` | `.woodpecker/valheim_backup.yml` | `valheim/backup` → `valheim_lxc` |

В каждом из этих файлов два независимых условия `when`: `event: manual` + `evaluate: PIPELINE == "..."` (ручной запуск через `wp_cli`) и `event: cron` + `cron: "<имя задачи>"` (расписание). Нельзя объединять их в один блок: `evaluate` опирается на переменную `PIPELINE`, которой при cron-событии нет, и тогда пайплайн молча пропускается.

## rclone (Google Drive)

Бэкапы уходят на Google Drive через rclone, поэтому рабочий конфиг rclone обязателен.

- Каталог `/root/.config/rclone` — `0700`, конфиг `/root/.config/rclone/rclone.conf` — `0600 root:root`. Перед любой перезаписью конфига рядом остаётся `rclone.conf.bak`.
- Если remote уже работает, `setup-control.sh` ничего не спрашивает. Иначе предлагает меню:
  1. импорт готового `rclone.conf` из `/home/pi/.config/rclone/rclone.conf`;
  2. импорт готового `rclone.conf` по указанному пути;
  3. интерактивный мастер OAuth — спрашивает `client_id`, `client_secret` (ввод без эха), `scope` (по умолчанию `drive`) и опционально `root_folder_id`; затем rclone печатает ссылку: на вопрос «Use auto config?» отвечай `n`, открой ссылку в браузере и вставь код подтверждения в терминал;
  4. service account JSON — путь к файлу, ключ копируется в `/root/.config/rclone/sa.json`; папку (или диск) на Drive нужно расшарить на email сервис-аккаунта;
  0. прервать установку.
- `client_id` можно не вводить — тогда используется встроенный client_id rclone (у него общие лимиты Google; свой client_id делается на `console.cloud.google.com`). `client_secret` нигде не печатается и не передаётся в командную строку rclone — только пишется в конфиг (0600).
- Обхода «продолжить без rclone» нет: даётся 5 попыток настройки (каждая печатает причину отказа rclone), затем скрипт прерывает установку с `exit 1`.
- Повторный запуск `setup-control.sh` безопасен: если `/opt/woodpecker/.env` уже есть, восстановление и переустановка пропускаются (`.env`, compose и volume не трогаются), выполняется только `docker compose up -d`.
- `backup-woodpecker.sh` проверяет конфиг, remote и `rclone lsd` до дорогой работы (docker tar, sops); при `rc=1` подсказывает запустить `sudo /root/setup-control.sh`.
- Проверки идут с короткими таймаутами (быстрый fail), а сама передача файла — с ретраями и запасом (`--retries 3 --low-level-retries 10 --contimeout 30s --timeout 300s`): на медленном канале до Google TLS-хендшейк не укладывается в 10 с и загрузка без ретраев падает.
- Копия в `/var/backups/woodpecker/woodpecker_backup.tar.gz.enc` — только страховка от потери прогона при неудачной загрузке (удаляется после успешной загрузки). Восстановление всегда идёт с Drive, а не из этого каталога.

## Пользователи и доступ по SSH

Скрипт создаёт две учётки с разным уровнем доверия:

| Учётка | Роль | sudo | SSH-ключи | `/home/pi` |
| --- | --- | --- | --- | --- |
| `pi` | интерактивная работа человеком | да, с паролем | да | да |
| `piweb` | процесс Pi Web и веб-агент | нет | нет | нет |

Разделение нужно потому, что Pi Web — это удалённый shell (`/api/terminal`, `node-pty`) и агент с ключами провайдеров в том же процессе: компрометация UI раньше давала полный контроль над учёткой `pi` с `NOPASSWD: ALL`.

- Публичный ключ root добавляется в `/root/.ssh/authorized_keys` — root может залогиниться сам к себе по ключу.
- Для `pi` создаётся `/home/pi/.ssh/authorized_keys` (`0700`/`0600`, `pi:pi`). Ключ скрипт спрашивает интерактивно (валидация через `ssh-keygen -l`), `Enter` — взять тот же ключ, что у root.
- `sudo` ставится из apt; `pi` добавляется в группу `sudo` и в `/etc/sudoers.d/90-pi`. Правило — `ALL=(ALL:ALL) ALL` (**с паролем**, без `NOPASSWD`): процесс Pi Web больше не работает от `pi`, поэтому беспарольный sudo не нужен ни одной автоматизации. После записи файл проверяется `visudo -cf`, при ошибке удаляется и установка прерывается — битый sudoers не остаётся на диске.
- `piweb` создаётся с shell `/usr/sbin/nologin`, пароль блокируется (`passwd -l`), домашний каталог `0700`. Скрипт явно убирает `piweb` из групп `sudo`, `docker`, `adm`, `systemd-journal` и удаляет `/home/piweb/.ssh`, если он есть.
- Пароли `root` и `pi` задаются интерактивно (дважды, без эха). Пароль передаётся только через stdin `chpasswd` — в аргументах командной строки его нет.
- Все пользователи, которые могут залогиниться (UID 0 или 1000–60000 и реальный shell), кроме `root`, `pi` и `piweb`, показываются списком с запросом подтверждения и затем удаляются (`pkill -KILL -u` + `userdel --remove`, при неудаче — `userdel` без домашнего каталога).

## pi agent и Pi Web

- **pi agent**: требует Node.js ≥ 22.19. Если подходящего Node нет, ставится официальный бинарный дистрибутив с `nodejs.org` (latest-v22.x) в `/usr/local` с обязательной проверкой `sha256sum`; затем `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`. Если `pi` уже стоит — предлагается `pi update`. Официальный `https://pi.dev/install.sh` не используется: он интерактивен и без tty не умеет ставить Node.
- **Pi Web** — [agegr/pi-web](https://github.com/agegr/pi-web) (пакет `@agegr/pi-web`):
  - ставится не глобально, а в отдельный каталог `/opt/pi-web` (`npm install --omit=dev --allow-scripts=node-pty @agegr/pi-web@latest` **от root**). Отдельный каталог нужен потому, что пакет предоставляет бинарник `pi-web`, и глобальная установка конфликтует с другими реализациями того же имени. `--allow-scripts=node-pty` разрешает install-скрипт только `node-pty` (на npm < 12 флага нет — там скрипты разрешены по умолчанию). На Linux `node-pty` собирается из исходников, поэтому дополнительно ставится `build-essential python3`; после установки скрипт проверяет, что модуль загружается. Каталог принадлежит `root:root` и не writable для `piweb`: иначе компрометация UI = правка кода своего же сервиса (персистентность).
  - запускается **system-level** юнитом `/etc/systemd/system/pi-web.service` (`User=piweb`, `WorkingDirectory=/opt/pi-web`, `Environment=PI_CODING_AGENT_DIR=/home/piweb/.pi/agent`, `Restart=on-failure`, `enable`). Своего установщика сервисов у Pi Web нет, поэтому unit пишется скриптом.
  - юнит содержит блок хардненинга: `NoNewPrivileges=yes`, пустые `CapabilityBoundingSet`/`AmbientCapabilities`, `ProtectSystem=strict` + `ReadWritePaths=/home/piweb /srv/work/piweb`, `InaccessiblePaths=-/home/pi`, `PrivateTmp`, `PrivateDevices`, `ProtectProc=invisible`, `RestrictNamespaces`, `SystemCallFilter=@system-service`, `UMask=0077`. `ProtectHome` не используется (иначе скрылся бы и `/home/piweb`); `MemoryDenyWriteExecute` не ставится — ломает JIT V8.
  - `piweb` работает с настройками агента из `/home/piweb/.pi/agent` (`0700`), plugin-data — `/home/piweb/.pi-web` (`0700`), рабочие каталоги — `/srv/work/piweb` (`0750`). Переменная `PIWEB_WORK_DIR` задаёт последний. При миграции с прежней одноюзерской схемы переносятся только `settings.json`, `models*.json`, `auth.json`, `mcp*.json`, `AGENTS.md` и `service.env`; `sessions/`, `ssh-remote-memories/`, `trust.json` и `npm/` не копируются (история с cwd из `/home/pi`, привязка trust к путям, SSH-заметки). Из `settings.json` веб-агента вырезается пакет `npm:pi-ssh-remote` — у `piweb` не должно быть SSH.
  - единственная запись внутри `/opt/pi-web` — `.next/cache`, отдаётся `piweb` отдельным `install -d`.
  - обновления Pi Web выполняются от root: `sudo npm --prefix /opt/pi-web install --omit=dev --no-fund --no-audit --allow-scripts=node-pty @agegr/pi-web@latest && sudo systemctl restart pi-web`. Штатный `/api/app-update` внутри UI после разделения не работает — так и задумано.
  - адрес выбирается интерактивно: LAN-адрес машины (определяется через `ip route get 1.1.1.1`, по умолчанию) или `127.0.0.1` для доступа только через SSH-туннель. `0.0.0.0` не используется — бинд на конкретный интерфейс держит порт вне других сетей.
  - **Порт задаётся переменной `PORT`**, а не `PI_WEB_PORT`: Pi Web читает только `PORT` (и флаг `-p`), поэтому `Environment=PI_WEB_PORT=...` в юните игнорируется и сервер молча слушает 30141.
  - **Домен за reverse proxy обязателен в `PI_WEB_ALLOWED_HOSTS`.** Pi Web пропускает запрос, только если `Host` — это `localhost`, `*.localhost`, IP-литерал либо значение из `PI_WEB_ALLOWED_HOSTS`; для домена без этой настройки страница открывается, но все POST отвечают `403 Untrusted API request`. Скрипт спрашивает домены и пишет `Environment=PI_WEB_ALLOWED_HOSTS=...`. Пример: `PI_WEB_ALLOWED_HOSTS=pi.mishgun.com` при обращении через traefik.
  - при бинде на не-loopback адрес включается **пароль**: `PI_WEB_PASSWORD` (логин `pi` / пароль, плюс Basic Auth для API). Пароль спрашивается без эха, Enter — сгенерировать случайный, и хранится в `/home/piweb/.config/pi-web/password` (`0600`). В юнит пароль не попадает: он лежит в `/home/piweb/.config/pi-web/service.env` (`0600`, владелец `piweb` — `EnvironmentFile` читает systemd от root), подключаемом через `EnvironmentFile=`.
  - **Важно:** даже с паролем пароль и трафик по HTTP не шифруются — только доверенная LAN, VPN или HTTPS reverse proxy. Порт дополнительно закрывается nftables: таблица `piweb_guard` в `/etc/nftables.d/piweb.nft` (подключается из `/etc/nftables.conf`) пускает к `PORT` только loopback и адреса из `PIWEB_ALLOWED_SRC` (по умолчанию `192.168.1.0/24` — хост traefik). `PIWEB_ALLOWED_SRC="-"` отключает этот шаг.
  - Если выбрано `127.0.0.1`, работать с любой машины так:
    `ssh -N -L 30141:127.0.0.1:30141 pi@<host>`, затем `http://127.0.0.1:30141`.
  - Управление: `systemctl status|restart pi-web`, логи — `journalctl -u pi-web -f`. Сменить адрес/порт/домены: поправить `Environment=PI_WEB_HOSTNAME`/`PORT`/`PI_WEB_ALLOWED_HOSTS` в `/etc/systemd/system/pi-web.service` и `systemctl daemon-reload && systemctl restart pi-web`.
  - Порт/хост/каталог/пакет вынесены в `PI_WEB_PORT`, `PI_WEB_HOST` (пустой = спросить), `PI_WEB_DIR`, `PI_WEB_BIN`, `PI_WEB_PKG`; учётки — `AGENT_USER_NAME` (`pi`) и `WEB_USER_NAME` (`piweb`).
  - наружу — через Traefik: роутер `piweb` в `ansible/roles/traefik/config/files/traefik/dynamic/piweb.yml` (`Host(\`pi.mishgun.com\`)`, `crowdsec@file` + security-заголовки + `rateLimit` + `inFlightReq`).
  - после запуска скрипт печатает результат `systemd-analyze security pi-web.service` и проверяет границы: `piweb` не видит `/home/pi`, не пишет в `/opt/pi-web`, не может `sudo -n true`.

## Проверки

Статический тест без docker/rclone/root:

```bash
bash useful_scripts/tests/check.sh
```
