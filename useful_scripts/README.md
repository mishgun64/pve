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
При вопросе про age-ключ вставляй существующий приватный ключ старого сервера, иначе бэкап оттуда не расшифровать.
Приватный age-ключ лежит в `/root/.config/sops/age/keys.txt` — сохрани его отдельно, без него бэкап бесполезен.
Ежедневный бэкап ставится в cron на 03:00 и всегда перезаписывает один и тот же файл `woodpecker/woodpecker_backup.tar.gz.enc`.
