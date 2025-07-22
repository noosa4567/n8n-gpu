#!/usr/bin/env bash
set -e

# 0) ensure ~/.n8n exists
mkdir -p /home/node/.n8n
chown node:node /home/node/.n8n

# 1) Install Puppeteer + the community node into ~/.n8n
#    (so they won't stomp on n8n's own deps)
npm install --prefix /home/node/.n8n \
    --no-optional \
    puppeteer n8n-nodes-puppeteer --legacy-peer-deps

# 2) fix ownership
chown -R node:node /home/node/.n8n

# 3) launch n8n
exec n8n "$@"
