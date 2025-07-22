#!/usr/bin/env bash
set -e

# Ensure the config directory exists
mkdir -p /home/node/.n8n

# Install Puppeteer + community nodes into ~/.n8n
# (add any future community nodes here)
npm install \
  --prefix /home/node/.n8n \
  --no-optional \
  puppeteer n8n-nodes-puppeteer --legacy-peer-deps

# delegate to n8n (defaults to server mode)
exec n8n "$@"
