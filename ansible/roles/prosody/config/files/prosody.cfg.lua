admins = { "admin@mishgun.com" }

modules_enabled = {
    "roster";
    "saslauth";
    "tls";
    "disco";
    "admin_shell";

    -- Presence / client sync
    "carbons";
    "smacks";

    -- Message archive
    "mam";

    -- Push / modern clients
    "pep";
    "vcard4";
    "vcard_legacy";

    -- File upload
    "http_upload";

    -- Security / extras
    "ping";
    "lastactivity";
}

allow_registration = false

VirtualHost "mishgun.com"

-- MUC (группы)
Component "conference.mishgun.com" "muc"
  name = "Chat Rooms"
  modules_enabled = { "muc_mam" }

-- Upload
Component "upload.mishgun.com" "http_upload"

http_upload_file_size_limit = 50 * 1024 * 1024

-- Traefik делает TLS
c2s_require_encryption = false

legacy_ssl_ports = { 5223 }