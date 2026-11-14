# Services and Pipelines

## media

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `media/config` | `media_vm/backup, media_vm/config, media_vm/restore` | `media_vm` | `Media Config` |
| backup | `media/backup` | `media_vm/backup` | `media_vm` | `Media Backup` |
| restore | `media/restore` | `media_vm/restore` | `media_vm` | `Media Restore` |
| full | `media/full` | — | — | `Media Full` |

## nextcloud

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `nextcloud/config` | `nextcloud/config` | `nextcloud_vm` | `Nextcloud Config` |
| backup | `nextcloud/backup` | `nextcloud/backup` | `nextcloud_vm` | `Nextcloud Backup` |
| restore | `nextcloud/restore` | `nextcloud/restore` | `nextcloud_vm` | `Nextcloud Restore` |
| full | `nextcloud/full` | — | — | `Nextcloud Full` |

## pvpgn

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `pvpgn/config` | `pvpgn/config` | `pvpgn_lxc` | `PvPGN Config` |
| backup | `pvpgn/backup` | `pvpgn/backup` | `pvpgn_lxc` | `PvPGN Backup` |
| restore | `pvpgn/restore` | `pvpgn/restore` | `pvpgn_lxc` | `PvPGN Restore` |
| full | `pvpgn/full` | — | — | `PvPGN Full` |

## traefik

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `traefik/config` | `traefik/config` | `traefik_lxc` | `Traefik Config` |
| backup | `traefik/backup` | `traefik/backup` | `traefik_lxc` | `Traefik Backup` |
| restore | `traefik/restore` | `traefik/restore` | `traefik_lxc` | `Traefik Restore` |
| full | `traefik/full` | — | — | `Traefik Full` |

## valheim

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `valheim/config` | `valheim/config` | `valheim_lxc` | `Valheim Config` |
| backup | `valheim/backup` | `valheim/backup` | `valheim_lxc` | `Valheim Backup` |
| restore | `valheim/restore` | `valheim/restore` | `valheim_lxc` | `Valheim Restore` |
| full | `valheim/full` | — | — | `Valheim Full` |

## wireguard

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `wireguard/config` | `wireguard/config` | `wg_lxc` | `WireGuard Config` |
| full | `wireguard/full` | — | — | `WireGuard Full` |

## santa_bot

Telegram bot [Santa_Bobot](https://github.com/mishgun64/Santa_Bobot) in a Docker container on LXC 148 (`santa-bot`, `192.168.2.11`).

| Pipeline | PIPELINE | ROLE | TARGET | MESSAGE |
|---|---|---|---|---|
| config | `santa_bot/config` | `santa_bot/config` | `santa_bot_lxc` | `Santa Bot Config` |
| backup | `santa_bot/backup` | `santa_bot/backup` | `santa_bot_lxc` | `Santa Bot Backup` |
| restore | `santa_bot/restore` | `santa_bot/restore` | `santa_bot_lxc` | `Santa Bot Restore` |
| full | `santa_bot/full` | — | — | `Santa Bot Full` |

Pipeline files: `.woodpecker/santa_bot_config.yml`, `santa_bot_backup.yml`, `santa_bot_restore.yml`, `santa_bot_full.yml`.

The bot token (`santa_bot_token`) is not stored in the repository. Provide it either through the encrypted `ansible/roles/santa_bot/config/files/secrets.enc.yml` or as an extra var (see `ansible/roles/santa_bot/README.md`).
