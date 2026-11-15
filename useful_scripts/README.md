# useful_scripts — control node (x86, Debian 13 trixie)

## Первичная настройка control node

```bash
curl -fsSL https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/setup-control.sh | sudo bash
```

## Бэкап Woodpecker CI на Google Drive (разово / вручную)

```bash
curl -fsSL https://raw.githubusercontent.com/mishgun64/pve/main/useful_scripts/backup-woodpecker.sh | sudo bash
```

Скрипт настройки интерактивный: понадобится `rclone config` (remote `gdrive:`, тип drive) — без него бэкапы на Drive не работают.
В качестве age-ключа для sops используется **SSH-ключ root** (`/root/.ssh/id_ed25519`, публичный — `id_ed25519.pub`).
Чтобы расшифровать бэкап, скрипт настройки должен получить тот же приватный SSH-ключ root, что и на старом узле; ключ не должен быть защищён паролем (иначе расшифровка в cron/восстановлении не сработает).
Ежедневный бэкап ставится в cron на 03:00 и всегда перезаписывает один и тот же файл `woodpecker/woodpecker_backup.tar.gz.enc`.
