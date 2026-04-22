-- Основные настройки
admins = { "admin@mishgun.com" }
network_backend = "epoll"

-- Модули
modules_enabled = {
  "roster";
  "saslauth";
  "tls";
  "dialback";
  "disco";
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
  "bosh";
  "websocket";
  "smacks";
  "csi_simple";
}

modules_disabled = {}

-- Разрешить регистрацию (отключи после создания пользователей)
allow_registration = false

-- TLS
ssl = {
  key = "/etc/prosody/certs/mishgun.com.key";
  certificate = "/etc/prosody/certs/mishgun.com.crt";
}

-- База данных MariaDB
storage = "sql"
sql = {
  driver = "MySQL";
  database = "prosody";
  host = "mariadb";
  port = 3306;
  username = "prosody";
  password = os.getenv("MYSQL_PASSWORD");
}

-- Виртуальный хост
VirtualHost "mishgun.com"
  enabled = true

-- Компонент для групповых чатов (MUC)
Component "conference.mishgun.com" "muc"
  modules_enabled = { "muc_mam" }

-- BOSH
consider_bosh_secure = true
cross_domain_bosh = true

-- WebSocket
consider_websocket_secure = true
cross_domain_websocket = true

log = {
  info = "/var/log/prosody/prosody.log";
  error = "/var/log/prosody/prosody.err";
}