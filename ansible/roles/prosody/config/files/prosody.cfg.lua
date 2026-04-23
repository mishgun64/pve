admins = { "admin@xmpp.mishgun.com" }
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
  "bosh";
  "websocket";
  "smacks";
  "csi_simple";

http_ports = { 5280 }
http_interfaces = { "*" }
https_ports = { 5281 }
https_interfaces = { "*" }

modules_disabled = {}
allow_registration = false

-- certmanager найдёт автоматически:
-- /etc/prosody/certs/mishgun.com/certificate.pem
-- /etc/prosody/certs/mishgun.com/privatekey.pem
certificates = "/etc/prosody/certs"

storage = "sql"
sql = {
  driver = "MySQL";
  database = "prosody";
  host = "mariadb";
  port = 3306;
  username = "prosody";
  password = Lua.os.getenv("MYSQL_PASSWORD");
}

VirtualHost "xmpp.mishgun.com"
  enabled = true

Component "conference.xmpp.mishgun.com" "muc"
  modules_enabled = { "muc_mam" }

consider_bosh_secure = true
cross_domain_bosh = true
consider_websocket_secure = true
cross_domain_websocket = true

log = {
  info = "*info";
  error = "*error";
}