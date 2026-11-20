# Services and Pipelines

Все ручные пайплайны запускаются с переменной `PIPELINE`;
ролевые пайплайны дополнительно принимают `ROLE` и `TARGET` (если не заданы — используются значения по умолчанию из раздела ниже).
Запуск ролей выполняется плейбуком `ansible/run_role.yml`, `full` — отдельным плейбуком сервиса.

`wp_cli.ps1` использует `woodpecker-cli`: бинарник должен быть в `PATH`, а сервер и токен — в конфиге CLI
(`woodpecker-cli` читает `WOODPECKER_SERVER`/`WOODPECKER_TOKEN` или свой конфиг-файл).

`wp_cli.sh` — bash-аналог для Linux/WSL: без аргументов открывает интерактивное меню (стрелки/цифры, Enter, Esc),
а с аргументами работает неинтерактивно: `wp_cli.sh <service> <pipeline>` (например `wp_cli.sh media backup`),
`wp_cli.sh list` — список всех сервисов и пайплайнов. Опции: `--repo`, `--branch`, `--var KEY=VALUE`,
`--dry-run`, `-y` (без подтверждения), `--no-install` (запрет автоустановки CLI).
Перед каждым запуском скрипт проверяет наличие `woodpecker-cli` и при отсутствии сам скачивает его с GitHub Releases
(версия подстраивается под сервер; установка в `/usr/local/bin` или `~/.local/bin`). Путь к бинарнику: `$WOODPECKER_CLI`.
Сервер: всегда `https://ci.mishgun.com` (задаётся скриптом, переопределение из окружения игнорируется).
Токен: `$WOODPECKER_TOKEN` или файл `~/.config/woodpecker/env` (chmod 600, строка `WOODPECKER_TOKEN=...`;
путь переопределяется `$WOODPECKER_ENV_FILE`, шаблон — `~/.config/woodpecker/env.example`). Сам токен: Web UI → User settings → Token.

## common

Базовые роли раскатываются на группу `docker_hosts` (VM/LXC с Docker-сервисами).

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| basic | `common/basic` | `common/basic` | `docker_hosts` | `Common Basic` |
| docker | `common/docker` | `common/docker` | `docker_hosts` | `Common Docker` |

Pipeline files: `.woodpecker/common_basic.yml`, `common_docker.yml`.
Дополнительно запускаются по push в `ansible/roles/common/basic/**` и `ansible/roles/common/docker/**`.

## pve

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| firewall | `pve/firewall` | `pve/firewall` | `pve` | `PVE Firewall` |

Pipeline file: `.woodpecker/pve_firewall.yml`.
Запускается по push в `ansible/roles/pve/firewall/**`.

## monitoring

Серверная часть мониторинга (Prometheus, Alertmanager, Grafana, blackbox_exporter,
pve_exporter) разворачивается на `control_node` в `/opt/monitoring`; агенты
(`node_exporter` + cAdvisor) — на группах `monitoring_agents` / `monitoring_cadvisor`.

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| agent | `monitoring/agent` | `monitoring/agent` | `monitoring_agents` | `Monitoring Agent` |
| server | `monitoring/server` | `monitoring/server` | `monitoring_server` | `Monitoring Server` |
| backup | `monitoring/backup` | `monitoring/backup` | `monitoring_server` | `Monitoring Backup` |
| restore | `monitoring/restore` | `monitoring/restore` | `monitoring_server` | `Monitoring Restore` |
| full | `monitoring/full` | — | — | `Monitoring Full` |

Pipeline files: `.woodpecker/monitoring_agent.yml`, `monitoring_server.yml`,
`monitoring_backup.yml`, `monitoring_restore.yml`, `monitoring_full.yml`.
`full` запускает `ansible/monitoring.yml` (сначала `monitoring/agent`, затем
`monitoring/server`). `server` расшифровывает `secrets.enc.yml` на раннере
(нужен `sops` + `SOPS_AGE_SSH_PRIVATE_KEY_FILE`); `backup`/`restore` выполняются
на самом control (rclone `gdrive:monitoring` + sops + ключ root) и в CI sops не
требуют. Плановый бэкап: cron `Monitoring-backup`.

Секреты (Telegram bot_token/chat_id, PVE-токен, пароль Grafana) — в
sops-файле роли; первичная настройка — скриптами
`useful_scripts/control/setup-pve-monitoring-token.sh` и
`setup-monitoring-secrets.sh`. Подробности: `ansible/roles/monitoring/README.md`.

## media

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `media/config` | `media_vm/backup;media_vm/config;media_vm/restore` | `media_vm` | `Media Config` |
| backup | `media/backup` | `media_vm/backup` | `media_vm` | `Media Backup` |
| restore | `media/restore` | `media_vm/restore` | `media_vm` | `Media Restore` |
| firewall | `media_vm/firewall` | `media_vm/firewall` | `pve` | `Media Firewall` |
| full | `media/full` | — | — | `Media Full` |

Pipeline files: `.woodpecker/media_vm_config.yml`, `media_vm_backup.yml`, `media_vm_restore.yml`, `media_vm_firewall.yml`, `media_vm_full.yml`.
`full` запускает `ansible/media.yml` (common/basic, common/docker, media_vm/init_config, media_vm/config, media_vm/firewall, media_vm/restore).
Роль `media_vm/init_config` (расшифровка sops-архивов стартовых конфигов) запускается только из `ansible/media.yml`, отдельного пайплайна у неё нет. В пайплайне `media/config` (`run_role.yml`) шаги копирования/распаковки init-конфигов пропускаются, если расшифрованных архивов нет.
Плановый бэкап: cron `Media-backup`.

## nextcloud

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `nextcloud/config` | `nextcloud/config` | `nextcloud_vm` | `Nextcloud Config` |
| backup | `nextcloud/backup` | `nextcloud/backup` | `nextcloud_vm` | `Nextcloud Backup` |
| restore | `nextcloud/restore` | `nextcloud/restore` | `nextcloud_vm` | `Nextcloud Restore` |
| firewall | `nextcloud/firewall` | `nextcloud/firewall` | `pve` | `Nextcloud Firewall` |
| full | `nextcloud/full` | — | — | `Nextcloud Full` |

Pipeline files: `.woodpecker/nextcloud_config.yml`, `nextcloud_backup.yml`, `nextcloud_restore.yml`, `nextcloud_firewall.yml`, `nextcloud_full.yml`.
`full` запускает `ansible/nextcloud_config.yml` (common/basic, common/docker, common/monitoring, nextcloud/config, nextcloud/firewall).
Бэкапы хранятся на `control_node` в `/srv/backups/nextcloud` (шифрование sops). Плановый бэкап: cron `Nextcloud-backup`.

## pvpgn

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `pvpgn/config` | `pvpgn/config` | `pvpgn_lxc` | `PvPGN Config` |
| backup | `pvpgn/backup` | `pvpgn/backup` | `pvpgn_lxc` | `PvPGN Backup` |
| restore | `pvpgn/restore` | `pvpgn/restore` | `pvpgn_lxc` | `PvPGN Restore` |
| firewall | `pvpgn/firewall` | `pvpgn/firewall` | `pve` | `PvPGN Firewall` |
| full | `pvpgn/full` | — | — | `PvPGN Full` |

Pipeline files: `.woodpecker/pvpgn_config.yml`, `pvpgn_backup.yml`, `pvpgn_restore.yml`, `pvpgn_firewall.yml`, `pvpgn_full.yml`.
`full` запускает `ansible/pvpgn.yml` (common/basic, common/docker, pvpgn/backup, pvpgn/config, pvpgn/firewall, pvpgn/restore).

## traefik

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `traefik/config` | `traefik/config` | `traefik_lxc` | `Traefik Config` |
| backup | `traefik/backup` | `traefik/backup` | `traefik_lxc` | `Traefik Backup` |
| restore | `traefik/restore` | `traefik/restore` | `traefik_lxc` | `Traefik Restore` |
| firewall | `traefik/firewall` | `traefik/firewall` | `pve` | `Traefik Firewall` |
| full | `traefik/full` | — | — | `Traefik Full` |

Pipeline files: `.woodpecker/traefik_config.yml`, `traefik_backup.yml`, `traefik_restore.yml`, `traefik_firewall.yml`, `traefik_full.yml`.
`full` запускает единый `ansible/traefik.yml` (common/basic, common/docker, traefik/backup, traefik/config, traefik/firewall, traefik/restore).
Бэкапы (acme.json, acme-dns, crowdsec) хранятся на `control_node` в `/srv/backups`, шифрование sops, хранится 5 последних. Плановый бэкап: cron `Traefik-backup`.

## valheim

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `valheim/config` | `valheim/config` | `valheim_lxc` | `Valheim Config` |
| backup | `valheim/backup` | `valheim/backup` | `valheim_lxc` | `Valheim Backup` |
| restore | `valheim/restore` | `valheim/restore` | `valheim_lxc` | `Valheim Restore` |
| firewall | `valheim/firewall` | `valheim/firewall` | `pve` | `Valheim Firewall` |
| full | `valheim/full` | — | — | `Valheim Full` |

Pipeline files: `.woodpecker/valheim_config.yml`, `valheim_backup.yml`, `valheim_restore.yml`, `valheim_firewall.yml`, `valheim_full.yml`.
`full` запускает `ansible/valheim.yml` (common/basic, common/docker, valheim/backup, valheim/config, valheim/firewall, valheim/restore).
Плановый бэкап: cron `Valheim-backup`.

## santa_bot

Telegram bot [Santa_Bobot](https://github.com/mishgun64/Santa_Bobot) в Docker-контейнере на LXC 148 (`santa-bot`, `192.168.2.11`).

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `santa_bot/config` | `santa_bot/config` | `santa_bot_lxc` | `Santa Bot Config` |
| backup | `santa_bot/backup` | `santa_bot/backup` | `santa_bot_lxc` | `Santa Bot Backup` |
| restore | `santa_bot/restore` | `santa_bot/restore` | `santa_bot_lxc` | `Santa Bot Restore` |
| firewall | `santa_bot/firewall` | `santa_bot/firewall` | `pve` | `Santa Bot Firewall` |
| full | `santa_bot/full` | — | — | `Santa Bot Full` |

Pipeline files: `.woodpecker/santa_bot_config.yml`, `santa_bot_backup.yml`, `santa_bot_restore.yml`, `santa_bot_firewall.yml`, `santa_bot_full.yml`.
`full` запускает `ansible/santa_bot.yml` (common/basic, common/docker, santa_bot/backup, santa_bot/config, santa_bot/firewall, santa_bot/restore).

The bot token (`santa_bot_token`) is not stored in the repository. Provide it either through the encrypted `ansible/roles/santa_bot/config/files/secrets.enc.yml` or as an extra var (see `ansible/roles/santa_bot/README.md`).

## wireguard

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| firewall | `wireguard/firewall` | `wireguard/firewall` | `pve` | `WireGuard Firewall` |

Pipeline file: `.woodpecker/wireguard_firewall.yml`.
Пайплайнов `wireguard/config` и `wireguard/full` пока нет — конфигурация сервера выполняется плейбуком `ansible/wireguard_server_config.yml` вручную.

## Прочие

| Pipeline | PIPELINE | Pipeline file | Описание |
|---|---|---|---|
| security | `security/gitleaks` | `.woodpecker/security.yml` | сканирование секретов |
| terraform | `terraform` | `.woodpecker/terraform.yml` | Terraform |