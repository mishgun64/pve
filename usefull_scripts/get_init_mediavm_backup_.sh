#!/usr/bin/env bash

#bash скрипт. создается папка ./init_config в этой папке создается файл .sops.yml с содержанием:
#creation_rules:
#  - age:
#      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMy5WqCB0OqW9WuzzHWVegy5oWFH1tRBZALxKOvkr8GB jenkins@control
#
#создается архив prowlarr_init_config.tar.gz в ./init_config из файлов:
#./prowlarr_config/*.db
#./prowlarr_config/*.db-wal
#./prowlarr_config/*.db-shm
#./prowlarr_config/config.xml
#
#создается архив radarr_init_config.tar.gz в ./init_config из файлов:
#./radarr_config/*.db
#./radarr_config/*.db-wal
#./radarr_config/*.db-shm
#./radarr_config/config.xml
#
#создается архив sonarr_anime_init_config.tar.gz в ./init_config из файлов:
#./sonarr_anime_config/*.db
#./sonarr_anime_config/*.db-wal
#./sonarr_anime_config/*.db-shm
#./sonarr_anime_config/config.xml
#
#создается архив sonarr_series_init_config.tar.gz в ./init_config из файлов:
#./sonarr_series_config/*.db
#./sonarr_series_config/*.db-wal
#./sonarr_series_config/*.db-shm
#./sonarr_series_config/config.xml
#
#создается архив seerr_init_config.tar.gz в ./init_config из файлов:
#./seerr_config/db/ весь каталог всесте с каталогом
#./seerr_config/settings.json
#
#создается архив emby_init_config.tar.gz в ./init_config из каталогов:
#./emby_config/config/
#./emby_config/data/
#
#перечень файлов в ./init_config шифруется при помощи sops (sops -e файл > файл.enc):
#prowlarr_init_config.tar.gz
#radarr_init_config.tar.gz
#sonarr_anime_init_config.tar.gz
#sonarr_series_init_config.tar.gz
#seerr_init_config.tar.gz
#emby_init_config.tar.gz

set -e

curl -LO https://github.com/getsops/sops/releases/download/v3.12.2/sops-v3.12.2.linux.amd64
mv sops-v3.12.2.linux.amd64 /usr/local/bin/sops
chmod +x /usr/local/bin/sops

BASE_DIR="./init_config"

mkdir -p "$BASE_DIR"

# 1. Создание .sops.yml
cat > "$BASE_DIR/.sops.yaml" << 'EOF'
creation_rules:
  - age:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMy5WqCB0OqW9WuzzHWVegy5oWFH1tRBZALxKOvkr8GB jenkins@control
EOF

# 2. Функция архивации
create_archive() {
  local name=$1
  shift
  local target="$BASE_DIR/${name}_init_config.tar.gz"

  tar -czf "$target" "$@"
}

# 3. Архивация сервисов
create_archive "prowlarr" \
  ./prowlarr_config/*.db \
  ./prowlarr_config/config.xml

create_archive "radarr" \
  ./radarr_config/*.db \
  ./radarr_config/config.xml

create_archive "sonarr_anime" \
  ./sonarr_anime_config/*.db \
  ./sonarr_anime_config/config.xml

create_archive "sonarr_series" \
  ./sonarr_series_config/*.db \
  ./sonarr_series_config/config.xml

create_archive "seerr" \
  ./seerr_config/db \
  ./seerr_config/settings.json

create_archive "emby" \
  ./emby_config/config \
  ./emby_config/data

create_archive "jellyfin" \
  ./jellyfin_config/*.xml \
  ./jellyfin_config/data

# 4. Шифрование всех архивов
for file in "$BASE_DIR"/*.tar.gz; do
  SOPS_CONFIG=./init_config/.sops.yaml sops -e "$file" > "$file.enc"
  rm "$file"
done

echo "Done"