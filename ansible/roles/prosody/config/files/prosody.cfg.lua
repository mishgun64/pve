admins = { "admin@xmpp.mishgun.com" }

modules_enabled = {
    "roster";
    "saslauth";
    "tls";
    "disco";

    -- Presence / client sync
    "carbons";
    "smacks";

    -- MUC (группы)
    "muc";
    "muc_mam";

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

-- File upload лимиты
http_upload_file_size_limit = 50 * 1024 * 1024

-- MUC настройки
Component "conference.mishgun.com" "muc"
  name = "Chat Rooms"
  modules_enabled = { "muc_mam" }

-- Upload endpoint
Component "upload.mishgun.com" "http_upload"

-- TLS (Traefik завершает TLS, но Prosody всё равно нужен)
c2s_require_encryption = false