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
  "smacks";           -- Возобновление сессии при обрыве (XEP-0198)
  "csi_simple";       -- Оптимизация трафика для фоновых клиентов (XEP-0352)
  "cloud_notify";     -- Push-уведомления (XEP-0357)

  -- История сообщений
  "mam";              -- Архив личных сообщений (XEP-0313)

  -- Передача файлов
  "http";             -- Нужен для http_file_share
  "http_file_share";  -- Загрузка файлов (XEP-0363)

  -- Безопасность и стабильность
  "limits";           -- Защита от флуда

  -- Мониторинг
  "prometheus";       -- Метрики для Grafana/Prometheus

  -- Администрирование
  "announce";         -- Рассылка от администратора всем пользователям
}

modules_disabled = {
  -- Федерация (S2S)
  "dialback";
  "disco";
  -- BOSH и WebSocket
  "bosh";
  "websocket";
}

allow_registration = false

-- Федерация отключена
s2s_ports = {}

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
archive_expires_after = "4w"
default_archive_policy = true

-- Передача файлов (HTTP Upload)
-- Нужен reverse proxy (nginx) на 443 -> 5280
http_ports = { 5280 }
http_interfaces = { "127.0.0.1" }  -- Только локально, снаружи через nginx
http_file_share_size_limit = 20 * 1024 * 1024  -- 20 MB максимальный размер файла
http_file_share_expires_after = "4w"            -- Файлы хранятся 4 недели

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

VirtualHost "mishgun.com"
  enabled = true
  c2s_ports = { 5222 }
  ssl = {
    key = "/etc/prosody/certs/mishgun.com/privatekey.pem";
    certificate = "/etc/prosody/certs/mishgun.com/certificate.pem";
  }

Component "conference.mishgun.com" "muc"
  modules_enabled = {
    "muc_mam";    -- История в конференциях
  }
  muc_log_by_default = true
  max_history_messages = 1000

-- Метрики Prometheus (доступны на http://localhost:5280/metrics)
-- Закрой этот эндпоинт на firewall или nginx, наружу не выставлять

log = {
  info = "*info";
  error = "*error";
}