# Мониторинг (Prometheus + Alertmanager + Grafana)

Реализация [MONITORING-PLAN.md](../../../MONITORING-PLAN.md). Сервер мониторинга —
`control_node` (192.168.2.200), отдельного LXC/VM нет. Агенты — на «сервисных»
хостах.

```
[хосты] node_exporter:9100 (+cAdvisor:8081) ─┐
[PVE API] pve_exporter ───────────────────────┼─> Prometheus:9090 ──> Alertmanager:9093 ──> Telegram
[HTTP/TCP/ICMP] blackbox_exporter ────────────┘        └───────────> Grafana:3000 ──> https://grafana.mishgun.com
```

## Состав ролей

| Роль | Где | Что делает |
|---|---|---|
| `monitoring/agent` | `monitoring_agents` (docker_hosts + pve + control_node) | `prometheus-node-exporter` (apt, :9100) + cAdvisor (docker, :8081) на `monitoring_cadvisor` |
| `monitoring/server` | `monitoring_server` (control_node) | compose-стек в `/opt/monitoring` (Prometheus, Alertmanager, Grafana, blackbox, pve_exporter), nftables `monitoring_guard`, Grafana datasource + 4 дашборда |
| `monitoring/backup` | control_node | tar (без TSDB) → sops/age → `/srv/backups/monitoring` → `gdrive:monitoring` |
| `monitoring/restore` | control_node | скачать/взять архив → sha256 → sops -d → распаковать → `docker compose up -d` |

Плейбук целиком: `ansible/monitoring.yml`.
Пайплайны: `.woodpecker/monitoring_{agent,server,full,backup,restore}.yml`
(manual: `monitoring/agent`, `monitoring/server`, `monitoring/full`,
`monitoring/backup`, `monitoring/restore`; cron-задача — `Monitoring-backup`).

## Inventory (`ansible/hosts_prod`)

```yaml
monitoring_agents:      # node_exporter; БЕЗ pve_iso_server
  children: { docker_hosts: }
  hosts: { pve:, control_node: }
monitoring_cadvisor:    # cAdvisor; только docker-хосты + control
  children: { docker_hosts: }
  hosts: { control_node: }
monitoring_server:      # Prometheus/Alertmanager/Grafana/blackbox/pve_exporter
  hosts: { control_node: }
```

Новый LXC/VM с Docker → добавить в `docker_hosts`, и он автоматически попадёт
в `monitoring_agents`/`monitoring_cadvisor` (и в таргеты Prometheus).

## Секреты

Все секреты — в `ansible/roles/monitoring/server/files/secrets.enc.yml`
(sops + age, получатель — публичный SSH-ключ `jenkins@control`, как в остальных
ролях). В открытом виде в git/CI/чате значения НЕ передаются.

Заполнить (на машине с приватным ключом `jenkins@control`, обычно сам control).
Скрипты ниже не выводят секреты в терминал и не передают их в argv:

```bash
# 1) read-only PVE-пользователь + API-токен (по ssh с control на PVE).
#    Секрет пишется в /root/monitoring-pve-token.secret (0600), не печатается.
sudo useful_scripts/control/setup-pve-monitoring-token.sh
#    уже есть токен, но секрет неизвестен: --rotate (старый будет удалён)
#    проверить наличие: --check, запуск на самом PVE: --local

# 2) секреты в sops (Telegram bot_token/chat_id + PVE-токен из файла)
sudo useful_scripts/control/setup-monitoring-secrets.sh \
     --pve-token-file /root/monitoring-pve-token.secret
shred -u /root/monitoring-pve-token.secret

# проверить заполненность и посмотреть пароль Grafana
sudo useful_scripts/control/setup-monitoring-secrets.sh --check
sudo useful_scripts/control/setup-monitoring-secrets.sh --show-grafana-password
```

Вручную (эквивалент): `sops edit ansible/roles/monitoring/server/files/secrets.enc.yml`.

| Ключ | Как получить |
|---|---|
| `monitoring_grafana_admin_password` | уже сгенерирован (32 симв.); можно оставить. Если менять — без пробелов, `#`, `$` (формат dotenv `/opt/monitoring/.env`) |
| `monitoring_alertmanager_telegram_bot_token` | `@BotFather` → `/newbot` для `@pve_mg_monitoring_bot` (или `/token`) |
| `monitoring_alertmanager_telegram_chat_id` | `@userinfobot` для лички; для группы — `getUpdates` (число, у групп отрицательное) |
| `monitoring_pve_api_user` | `monitoring@pve` (realm PVE) |
| `monitoring_pve_token_name` | имя токена, напр. `prometheus` |
| `monitoring_pve_token_value` | секрет токена `monitoring@pve!prometheus` |

PVE-доступ (read-only, НЕ `root@pam!tf`). Это делает
`setup-pve-monitoring-token.sh`; вручную то же самое:

```bash
pveum user add monitoring@pve --comment "Prometheus monitoring (read-only)"
pveum user token add monitoring@pve prometheus --privsep 1
# privsep=1: у токена свои права, поэтому PVEAuditor выдаётся ТОКЕНУ:
pveum acl modify / --tokens 'monitoring@pve!prometheus' --roles PVEAuditor
# pveum показывает secret токена один раз — он и есть monitoring_pve_token_value
```

Если в секретах остались `CHANGE_ME` — роль `monitoring/server` падает до
изменений на хосте (защита от «поднялось, но не алертит»).

Grafana admin-пароль берётся из секрета при первом старте (`/opt/monitoring/.env`,
0600 root). Посмотреть: `sops -d .../secrets.enc.yml` или
`ssh control 'cat /opt/monitoring/.env'` (осторожно с shell history).
Смена `monitoring_grafana_admin_password` в секрете НЕ меняет пароль уже
созданной БД: нужен `docker exec grafana grafana cli admin reset-admin-password
'<новый>'` (или смена через UI).

## Порядок первого развёртывания

1. **Firewall на PVE** — входящие 9100/8081 от 192.168.2.200 (см. ниже).
   Без этого Prometheus увидит агентов как DOWN.
2. Заполнить секреты (см. выше), закоммитить `secrets.enc.yml` (он шифрован).
3. Pipeline `monitoring/agent` → node_exporter/cAdvisor на всех агентах.
4. Pipeline `monitoring/server` → стек на control.
5. Pipeline `traefik/config` (или push `traefik/config/**`) → маршрут
   `grafana.mishgun.com` (DNS-запись A → внешний адрес, как у остальных
   `*.mishgun.com`; сертификат из wildcard).
6. Завести cron `Monitoring-backup` в Woodpecker (repo settings → Crons).

## Firewall

### Агенты: PVE-firewall (входящие 9100/8081)

Правила лежат в зашифрованных `ansible/roles/<svc>/firewall/files/<vmid>.fw.enc`
и в `ansible/roles/pve/firewall/files/cluster.fw.enc` (сам гипервизор).
Нужно добавить в секцию `[RULES]` каждого гостя:

```
# monitoring: node_exporter/cAdvisor только с control_node
IN ACCEPT -source 192.168.2.200 -p tcp -dport 9100
IN ACCEPT -source 192.168.2.200 -p tcp -dport 8081
```

Для гипервизора (`cluster.fw.enc`) — только 9100.

Полуавтоматически (dry-run по умолчанию, запускать на control, где есть
приватный возрастной ключ и свежий checkout):

```bash
sudo useful_scripts/control/add-monitoring-fw-rules.sh          # показать diff
sudo useful_scripts/control/add-monitoring-fw-rules.sh --apply  # перешифровать .enc
# затем git diff / commit / push — сработают соответствующие *_firewall.yml
```

Вручную: `sops -d X.fw.enc > X.fw`, правка, `sops -e X.fw > X.fw.enc`,
удалить `X.fw` (он в `.gitignore`).

Также убедиться, что с control доступен PVE API `https://192.168.2.2:8006`
(для pve_exporter; обычно открыт для LAN).

### control: nftables (роль `monitoring/server`)

Фрагмент `/etc/nftables.d/monitoring.nft`, таблица `inet monitoring_guard`
(приоритет -14, применяется инкрементально `nft -f`, БЕЗ `flush ruleset`).
Тот же фрагмент (те же порты/источники) ставит `setup-control.sh` при
bootstrap/пересборке control — при изменении правил синхронизировать оба места:

| Порт | Кто ходит |
|---|---|
| 3000 Grafana | Traefik: `192.168.2.3` и outer `192.168.4.3` (`monitoring_grafana_proxy_sources`) + `monitoring_admin_sources` |
| 9090 Prometheus | `monitoring_admin_sources` |
| 9093 Alertmanager | `monitoring_admin_sources` |
| 9100/8081 (сам control) | только docker-сети `172.16.0.0/12` |

IPv6 для этих портов закрыт. Prometheus/Alertmanager наружу не выставляются.
Дополнительно порты публикуются Docker'ом не на `0.0.0.0`, а на LAN-IP
`monitoring_bind_address` (192.168.2.200): nftables input не видит DNAT-трафик
Docker, поэтому привязка к конкретному адресу — вторая линия защиты от
доступа с WAN/VPN интерфейсов.

## Проверка

```bash
# агенты
curl -s http://192.168.2.4:9100/metrics | head
curl -s http://192.168.2.4:8081/metrics | head
# сервер (с LAN-админа)
curl -s http://192.168.2.200:9090/api/v1/targets | grep -c '"health":"up"'
curl -s http://192.168.2.200:9093/-/healthy
curl -s http://192.168.2.200:3000/api/health
# pve_exporter изнутри compose-сети
ssh root@192.168.2.200 'docker exec prometheus wget -qO- "http://pve_exporter:9221/pve?target=192.168.2.2" | head'
```

Grafana: `https://grafana.mishgun.com` (и `http://192.168.2.200:3000` из LAN),
user `admin`, пароль из секрета. Дашборды: Node Exporter Full, Cadvisor,
Blackbox, Prometheus Overview.

Тест алерта: погасить контейнер на docker-хосте → через ~15 мин
(`ContainerDown`: last_seen > 10m + for 5m) сообщение в Telegram.

## Переменные (основные)

`ansible/roles/monitoring/server/defaults/main.yml`:

| Переменная | По умолчанию | Комментарий |
|---|---|---|
| `monitoring_dir` | `/opt/monitoring` | каталог стека и bind-mount данных |
| `prometheus_retention` | `15d` | TSDB; следить за местом на control |
| `monitoring_bind_address` | `{{ ansible_host }}` (192.168.2.200) | адрес публикации портов стека (не 0.0.0.0) |
| `prometheus_scrape_interval` | `15s` | evaluate/global |
| `*_image` | пиннинг версий | см. ниже |
| `grafana_root_url` | `https://grafana.mishgun.com` | `GF_SERVER_ROOT_URL` |
| `pve_api_host` | `192.168.2.2` | target для pve_exporter |
| `blackbox_*_targets` | списки | HTTP/TCP/ICMP-пробы |
| `monitoring_admin_sources` | `192.168.1.0/24`, `192.168.2.0/24` | синхронизировать с `CONTROL_GUARD_SSH_SOURCES` |
| `monitoring_grafana_proxy_sources` | `192.168.2.3`, `192.168.4.3` | адреса Traefik LXC (внутренний + outer), которым открыт порт 3000 |
| `monitoring_manage_firewall` | `true` | ставить ли `monitoring.nft` |

`monitoring/agent`: `node_exporter_args` (доп. флаги), `cadvisor_image`,
`cadvisor_port`, `cadvisor_enabled`.

Версии (обновлять осознанно, меняя defaults):

```
prom/prometheus:v3.16.0
prom/alertmanager:v0.35.0
grafana/grafana:13.3.1
prom/blackbox-exporter:v0.29.1
prompve/prometheus-pve-exporter:3.12.0
gcr.io/cadvisor/cadvisor:v0.55.1
```

## Бэкап / восстановление

`monitoring/backup`:

- останавливает `grafana` на время архивации (`grafana.db` — sqlite);
- архивирует `/opt/monitoring` **без** `data/prometheus` (флаг
  `monitoring_backup_include_tsdb: true` — включить TSDB);
- шифрует `sops/age`, кладёт `monitoring_ДД_ММ_ГГГГ_ЧЧ_ММ.tar.gz.enc` + `.sha256`
  в `/srv/backups/monitoring` (0700);
- загружает в `gdrive:monitoring`, проверяет размер, ротирует локально и на
  Drive (`monitoring_backup_keep: 5`; имя совместимо с
  `useful_scripts/control/cleanup_backups.sh`).

`monitoring/restore` берёт самый новый локальный архив, иначе последний с
Google Drive (или `-e monitoring_restore_archive=/path/file.enc`), проверяет
sha256, защищается от path traversal, распаковывает в `/opt`, поднимает стек.

При пересборке control_node `useful_scripts/control/setup-control.sh` тоже
восстанавливает стек из последнего `gdrive:monitoring` (если `/opt/monitoring`
отсутствует) и применяет nftables-гард `monitoring_guard`; роль остаётся
источником истины по конфигам/compose.
Расшифровка идёт на control приватным ключом `monitoring_restore_sops_key`
(по умолчанию `/root/.ssh/id_ed25519` — тот же ключ, что age-получатель
`jenkins@control`).

## Известные ограничения

- **Valheim/WireGuard (UDP)** — blackbox TCP/ICMP их не проверяет; доступность
  = «хост жив» (ICMP/node_exporter) + контейнер running (cAdvisor).
- **ContainerDown** срабатывает и на осознанно остановленный контейнер
  (cAdvisor долго помнит `container_last_seen`). На время плановых работ алерт
  мьютить в Alertmanager; при шуме от одноразовых контейнеров — исключить их
  по `name` в `prometheus/alerts/containers.yml`.
- **cAdvisor** качается с `gcr.io`. Если registry недоступен с хоста —
  переопределить `cadvisor_image` на зеркало (`-e cadvisor_image=...`) или
  использовать textfile-collector (п.12 плана).
- **ICMP в blackbox** требует raw-сокет: в compose он запущен root с
  `cap_add: NET_RAW` и `ping_group_range`; при жёстких seccomp/apparmor
  профилях на хосте ICMP-проба может не работать (остальные пробы работают).
- Графики хостов используют label `instance` = имя из inventory (не IP).

## Траблшутинг

```bash
cd /opt/monitoring && docker compose ps
docker compose logs --tail=100 prometheus
docker compose logs --tail=100 alertmanager
docker compose logs --tail=100 grafana
# конфиги до применения
docker run --rm --entrypoint promtool -v /opt/monitoring/prometheus:/etc/prometheus:ro \
  prom/prometheus:v3.16.0 check config /etc/prometheus/prometheus.yml
nft list table inet monitoring_guard
```

- `targets` DOWN у всех агентов → firewall на PVE (9100/8081) или агент не
  развёрнут (`monitoring/agent`).
- `pve` job DOWN → неверный токен/права (`PVEAuditor`) или недоступен 8006.
- Telegram молчит → `alertmanager` logs: `chat not found` (chat_id),
  `Unauthorized` (bot_token). Проверить `sops -d secrets.enc.yml`.
- Grafana отдаёт 502 через Traefik → контейнер не поднялся или nftables
  `monitoring_guard` не пропускает Traefik (`monitoring_grafana_proxy_sources`:
  192.168.2.3/192.168.4.3) — проверить `nft list table inet monitoring_guard`.