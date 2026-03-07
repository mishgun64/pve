#!/usr/bin/env bash
set -euo pipefail

JENKINS_URL="http://192.168.1.200:8080"
TOKEN="pve-first-boot"

curl -fsS -X POST \
  "${JENKINS_URL}/generic-webhook-trigger/invoke?token=${TOKEN}"
