#!/bin/bash

JENKINS_SERVER="192.168.2.200:8080"
TOKEN="pve-webhook"

curl -X POST http://$JENKINS_SERVER/generic-webhook-trigger/invoke?token=$TOKEN \
-H "Content-Type: application/json" \
-d '{
  "event": "pve-first-boot",
  "node": "pve1",
  "host": "pve1.local"
}'
