#!/usr/bin/env bash
set -e

# ensure the config dir exists and is owned by node
mkdir -p /home/node/.n8n
chown node:node /home/node/.n8n

# install Puppeteer + community node(s) into ~/.n8n
# any future community nodes can be added here too
npm install \
  --prefix /home/node/.n8n \
  --no-optional \
  puppeteer n8n-nodes-puppeteer --legacy-peer-deps

# fix ownership again
chown -R node:node /home/node/.n8n

# finally exec n8n (defaults to server mode)
exec n8n "$@"
