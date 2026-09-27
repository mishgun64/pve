---
# Monitoring Role Documentation
# ==========================

## Назначение
Устанавливает Node Exporter на целевые узлы для сбора метрик о производительности железа:
- Использование CPU и RAM
- Загрузка дисков (включая SSD/HDD отдельно)
- Сетевая статистика
- Контейнерная статистика (через Cgroup v2, если доступно)

## Параметры (из ansible/roles/monitoring/vars/main.yml)

| Параметр | Тип   | Значение по умолчанию | Описание                                   |
|----------|-------|------------------------|--------------------------------------------|
| port     | int   | 9100                   | Порт, на котором работает Node Exporter    |
| enabled  | bool  | true                   | Включить роль мониторинга или нет          |
| args     | str   | --collector.filesystem1s --collector.netfilter | Дополнительные флаги экспортера |

## Как использовать

### 1. Базовая установка

Просто запустите обычный плейбук:
```bash
ansible-playbook -i your_inventory inventory.ini your_service_config.yml
```

Роль `monitoring` уже включена в каждый сервисный плейбук (например, `nextcloud_config.yml`, `traefik_config.yml`).

### 2. Отключение мониторинга на каком-то узле

Если на конкретном сервере не нужно собирать метрики:
```yaml
# В ansible/roles/monitoring/vars/main.yml
node_exporter_enabled: false
```

Или через локальные переменные перед запуском:
```bash
ansible-playbook -i your_inventory inventory.ini \
  -e "node_exporter_enabled=false" your_service_config.yml
```

### 3. Настройка порта (если нужен другой порт)

```yaml
# В ansible/roles/monitoring/vars/main.yml или через -e
node_exporter_port: 9101
```

## Структура роли

```
ansible/roles/monitoring/
├── vars/
│   └── main.yml          # Параметры экспортера
└── tasks/
    └── main.yml          # Задачи установки и запуска
```

## Что устанавливает роль

1.  Устанавливает пакет `node_exporter` (Debian/Ubuntu) или через `yum` (RHEL/CentOS).
2.  Автоматически включает сервис `node_exporter` для автозагрузки.
3.  Настраивает сбор данных о файловых системах и сетевых интерфейсах по умолчанию.

## Примеры метрик

После установки вы сможете получить следующие данные:
- `node_cpu_seconds_total` — использование CPU по ядрам
- `node_memory_MemTotal_bytes` — общий объём памяти
- `node_filesystem_size_bytes` — размер файловых систем
- `node_network_receive_bytes_total` — сетевая статистика

## Следующие шаги

1.  **Проверка установки:** Запустите плейбук для одного из ваших VM/LXC и убедитесь, что сервис запущен:
    ```bash
    ansible all -m ping
    ansible all -a "systemctl status node_exporter"
    ```

2.  **Подключение Prometheus:** После установки на всех узлах можно развернуть Prometheus для сбора метрик (см. следующий шаг).

3.  **Cadvisor для Docker:** Если хотите видеть нагрузку на каждый контейнер отдельно, добавим роль `cadvisor` в ту же папку `monitoring`.
