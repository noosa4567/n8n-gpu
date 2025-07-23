#!/usr/bin/env bash
set -e

# Ensure config dir exists
mkdir -p /home/node/.n8n

# Install Puppeteer & community nodes into ~/.n8n
npm install \
  --prefix /home/node/.n8n \
  --no-optional \
  puppeteer n8n-nodes-puppeteer --legacy-peer-deps

# Hand off to n8n (no args → server mode)
exec n8n "$@"
