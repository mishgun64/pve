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

Скрипт также ставит системный часовой пояс `Europe/Moscow` (MSK, +0300) — от него зависят время в логах и запуск cron в 03:00 по Москве.

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

Скрипт создаёт рабочего пользователя `pi` (домашний каталог `/home/pi`, shell `/bin/bash`) и настраивает доступ:

- Публичный ключ root добавляется в `/root/.ssh/authorized_keys` — root может залогиниться сам к себе по ключу.
- Для `pi` создаётся `/home/pi/.ssh/authorized_keys` (`0700`/`0600`, `pi:pi`). Ключ скрипт спрашивает интерактивно (валидация через `ssh-keygen -l`), `Enter` — взять тот же ключ, что у root.
- `sudo` ставится из apt; `pi` добавляется в группу `sudo` и в `/etc/sudoers.d/90-pi` (`NOPASSWD: ALL`, режим `0440`). После записи файл проверяется `visudo -cf`, при ошибке удаляется и установка прерывается — битый sudoers не остаётся на диске.
- Пароли `root` и `pi` задаются интерактивно (дважды, без эха). Пароль передаётся только через stdin `chpasswd` — в аргументах командной строки его нет.
- Все пользователи, которые могут залогиниться (UID 0 или 1000–60000 и реальный shell), кроме `root` и `pi`, показываются списком с запросом подтверждения и затем удаляются (`pkill -KILL -u` + `userdel --remove`, при неудаче — `userdel` без домашнего каталога).

## pi agent и PI WEB

- **pi agent**: требует Node.js ≥ 22.19. Если подходящего Node нет, ставится официальный бинарный дистрибутив с `nodejs.org` (latest-v22.x) в `/usr/local` с обязательной проверкой `sha256sum`; затем `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`. Если `pi` уже стоит — предлагается `pi update`. Официальный `https://pi.dev/install.sh` не используется: он интерактивен и без tty не умеет ставить Node.
- **PI WEB** — [jmfederico/pi-web](https://github.com/jmfederico/pi-web) (пакет `@jmfederico/pi-web`):
  - ставится глобально: `npm install -g --allow-scripts=node-pty @jmfederico/pi-web@latest` (`--allow-scripts=node-pty` разрешает install-скрипт только `node-pty`, нужный для терминалов; на npm < 12 флага нет — там скрипты разрешены по умолчанию). На Linux `node-pty` собирается из исходников, поэтому дополнительно ставится `build-essential python3`.
  - регистрируется не вручную, а своим CLI: `pi-web install --host 127.0.0.1 --port 8504`. Он создаёт **два per-user systemd-сервиса** — `pi-web.service` (web/API) и `pi-web-sessiond.service` (долгоживущие сессии).
  - всё выполняется от пользователя `pi` в его user-контексте (`XDG_RUNTIME_DIR=/run/user/<uid>`, `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus`, `bash -lc`) — без этого `systemctl --user` не работает. Дополнительно включается `loginctl enable-linger pi`, чтобы сервисы жили после логаута и перезагрузки.
  - `PATH` с глобальным npm-prefix дописывается в `/home/pi/.profile` (не в `.bashrc`): сервисы запускаются через `-lc` и `.bashrc` не читают. Без этого `pi-web` не найдёт `pi`, SDK которого он переиспользует.
  - Встроенной авторизации нет (README проекта: «Do not expose PI WEB directly to the public internet»), поэтому слушает только `127.0.0.1:8504`. Наружу — Tailscale/SSH-туннель/nginx с auth, не `0.0.0.0`.
  - Управление: `sudo -u pi -i pi-web status|logs|restart|update|doctor`. Если `pi-web install` не смог поднять user-сервисы, установка не валится — печатаются команды для ручного повтора `pi-web doctor` /
    `pi-web install`, а в финале отражается только факт наличия `pi-web`.
  - Порт/хост вынесены в `PI_WEB_HOST`/`PI_WEB_PORT`, пакет — в `PI_WEB_NPM_PACKAGE`.

## Проверки

Статический тест без docker/rclone/root:

```bash
bash useful_scripts/tests/check.sh
```
