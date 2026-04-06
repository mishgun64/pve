#!/bin/bash

set -e

# Архивирование
tar -czf /home/docker/wg_config.tar.gz -C /home/docker wireguard_config

# Создание .sops.yml
cat > /home/docker/.sops.yaml << 'EOF'
creation_rules:
  - age:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMy5WqCB0OqW9WuzzHWVegy5oWFH1tRBZALxKOvkr8GB jenkins@control
EOF

# Шифрование
cd /home/docker
sops -e wg_config.tar.gz > wg_config.tar.gz.enc
rm wg_config.tar.gz
echo "Done: /home/docker/wg_config.tar.gz.enc"