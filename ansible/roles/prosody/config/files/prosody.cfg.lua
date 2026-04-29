-- Community-модули ищутся в этой директории (монтируется в docker-compose)
plugin_paths = { "/usr/lib/prosody/community-modules" }

admins = { "admin@mishgun.com" }
network_backend = "epoll"

modules_enabled = {
  -- Базовые
  "roster";
  "saslauth";
  "tls";
  "carbons";
  "pep";
  "private";
  "blocklist";
  "vcard4";
  "vcard_legacy";
  "version";
  "uptime";
  "time";
  "ping";
  "register";
  "admin_adhoc";
  "admin_shell";

  -- Мобильные клиенты
  -- ВНИМАНИЕ: используются community-версии из plugin_paths (заменяют встроенные)
  "smacks";           -- Возобновление сессии при обрыве (XEP-0198) [community: mod_smacks]
  "csi_simple";       -- Оптимизация трафика для фоновых клиентов (XEP-0352)
  "cloud_notify";     -- Push-уведомления (XEP-0357) [community: mod_cloud_notify]

  -- История сообщений
  -- ВНИМАНИЕ: используется community-версия из plugin_paths (заменяет встроенную)
  "mam";              -- Архив личных сообщений (XEP-0313) [community: mod_mam]

  -- Передача файлов
  "http";             -- Нужен для http_file_share
  "http_file_share";  -- Загрузка файлов (XEP-0363)

  -- Безопасность и стабильность
  "limits";           -- Защита от флуда
  "log_auth";         -- Логирование неудачных попыток входа [community: mod_log_auth]
                      -- Пишет в лог строки вида: "Failed authentication attempt (noauth)"
                      -- CrowdSec парсит эти строки для блокировки брутфорса

  -- Инвайты (community-модули)
  "invites";          -- Генерация инвайт-ссылок (XEP-0401) [community: mod_invites]
  "invites_adhoc";    -- Управление инвайтами через XMPP-клиент [community: mod_invites_adhoc]
  "invites_register"; -- Регистрация по инвайт-ссылке [community: mod_invites_register]

  -- vCard в конференциях
  "vcard_muc";        -- Показывает vCard участников в MUC [community: mod_vcard_muc]

  -- Ростер
  "roster_all";       -- Автоматически добавляет всех пользователей домена в ростер [community: mod_roster_all]

  -- Мониторинг
  "prometheus";       -- Метрики для Grafana/Prometheus

  -- Администрирование
  "announce";         -- Рассылка от администратора всем пользователям
  "disco";
}

modules_disabled = {
  -- Федерация (S2S)
  "dialback";
  -- BOSH и WebSocket
  "bosh";
  "websocket";
}

-- Регистрация через обычную форму отключена — только по инвайтам
allow_registration = false

-- Федерация отключена
s2s_ports = {}
c2s_require_encryption = true

storage = "sql"
sql = {
  driver = "MySQL";
  database = "prosody";
  host = "mariadb";
  port = 3306;
  username = "prosody";
  password = Lua.os.getenv("MYSQL_PASSWORD");
}

-- Архив сообщений
archive_expires_after = "4y"
default_archive_policy = true

-- Передача файлов (HTTP Upload)
-- Нужен reverse proxy (nginx) на 443 -> 5280

http_ports = { 5280 }
http_interfaces = { "*" }
http_file_share_size_limit = 20 * 1024 * 1024  -- 20 MB максимальный размер файла
http_file_share_expires_after = "4w"            -- Файлы хранятся 4 недели
http_host = "upload.mishgun.com"
http_external_url = "https://upload.mishgun.com"

-- Защита от флуда
limits = {
  c2s = {
    rate = "10kb/s";
    burst = "30kb";
  };
}

-- Smacks (возобновление сессии)
smacks_max_unacked_stanzas = 5
smacks_hibernation_time = 300  -- 5 минут ожидания переподключения

-- Инвайты: базовый URL для генерации ссылок
-- Клиент сформирует ссылку вида: https://mishgun.com/invite/<token>
invites_url = "https://mishgun.com/invite/{invite}"

VirtualHost "mishgun.com"
  enabled = true
  c2s_ports = { 5222 }
  ssl = {
    key = "/etc/prosody/certs/mishgun.com/privatekey.pem";
    certificate = "/etc/prosody/certs/mishgun.com/certificate.pem";
  }

Component "conference.mishgun.com" "muc"
  modules_enabled = {
    "muc_mam";      -- История в конференциях
    "muc_listing";  -- Публичный список конференций (XEP-0423) [community: mod_muc_listing]
                    -- Список доступен через HTTP: http://localhost:5280/muc_listing
  }
  muc_log_by_default = true
  max_history_messages = 1000

-- Метрики Prometheus (доступны на http://localhost:5280/metrics)
-- Закрой этот эндпоинт на firewall или nginx, наружу не выставлять

log = {
    { levels = { "debug" }, to = "console" };
}