# Services and Pipelines

## media

| Pipeline | PIPELINE | ROLE | TARGET |
|---|---|---|---|
| config | `media/config` | `media_vm/config` | `media_vm` |
| backup | `media/backup` | `media_vm/backup` | `media_vm` |
| restore | `media/restore` | `media_vm/restore` | `media_vm` |
| full | `media/full` | — | — |

## nextcloud

| Pipeline | PIPELINE | ROLE | TARGET |
|---|---|---|---|
| config | `nextcloud/config` | `nextcloud/config` | `nextcloud_vm` |
| backup | `nextcloud/backup` | `nextcloud/backup` | `nextcloud_vm` |
| restore | `nextcloud/restore` | `nextcloud/restore` | `nextcloud_vm` |
| full | `nextcloud/full` | — | — |

## pvpgn

| Pipeline | PIPELINE | ROLE | TARGET |
|---|---|---|---|
| config | `pvpgn/config` | `pvpgn/config` | `pvpgn_lxc` |
| backup | `pvpgn/backup` | `pvpgn/backup` | `pvpgn_lxc` |
| restore | `pvpgn/restore` | `pvpgn/restore` | `pvpgn_lxc` |
| full | `pvpgn/full` | — | — |

## traefik

| Pipeline | PIPELINE | ROLE | TARGET |
|---|---|---|---|
| config | `traefik/config` | `traefik/config` | `traefik_lxc` |
| backup | `traefik/backup` | `traefik/backup` | `traefik_lxc` |
| restore | `traefik/restore` | `traefik/restore` | `traefik_lxc` |
| full | `traefik/full` | — | — |

## valheim

| Pipeline | PIPELINE | ROLE | TARGET |
|---|---|---|---|
| config | `valheim/config` | `valheim/config` | `valheim_lxc` |
| backup | `valheim/backup` | `valheim/backup` | `valheim_lxc` |
| restore | `valheim/restore` | `valheim/restore` | `valheim_lxc` |
| full | `valheim/full` | — | — |

## wireguard

| Pipeline | PIPELINE | ROLE | TARGET |
|---|---|---|---|
| config | `wireguard/config` | `wireguard/config` | `wg_lxc` |
| full | `wireguard/full` | — | — |