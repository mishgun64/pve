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
- Копия в `/var/backups/woodpecker/woodpecker_backup.tar.gz.enc` — только страховка от потери прогона при неудачной загрузке (удаляется после успешной загрузки). Восстановление всегда идёт с Drive, а не из этого каталога.

## Проверки

Статический тест без docker/rclone/root:

```bash
bash useful_scripts/tests/check.sh
```
