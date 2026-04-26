admins = { "admin@mishgun.com" }
network_backend = "epoll"

modules_enabled = {
  "roster";
  "saslauth";
  "tls";
  "http";
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
  "admin_shell";
  "smacks";
  "csi_simple";
}

http_ports = { 5280 }
http_interfaces = { "*" }
https_ports = { 5281 }
https_interfaces = { "*" }

modules_disabled = {}
allow_registration = false

storage = "sql"
sql = {
  driver = "MySQL";
  database = "prosody";
  host = "mariadb";
  port = 3306;
  username = "prosody";
  password = Lua.os.getenv("MYSQL_PASSWORD");
}

VirtualHost "mishgun.com"
  enabled = true
  ssl = {
    key = "/etc/prosody/certs/mishgun.com/privatekey.pem";
    certificate = "/etc/prosody/certs/mishgun.com/certificate.pem";
  }

Component "conference.mishgun.com" "muc"
  modules_enabled = { "muc_mam" }

consider_bosh_secure = true
cross_domain_bosh = true
consider_websocket_secure = true
cross_domain_websocket = true

log = {
  info = "*info";
  error = "*error";
}