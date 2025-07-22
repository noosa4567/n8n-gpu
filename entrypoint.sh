#!/usr/bin/env bash
set -e

# ensure config dir exists
mkdir -p /home/node/.n8n
chown node:node /home/node/.n8n

# install Puppeteer + community package(s) into ~/.n8n
npm install --prefix /home/node/.n8n \
  --no-optional \
  puppeteer n8n-nodes-puppeteer --legacy-peer-deps

# fix ownership
chown -R node:node /home/node/.n8n

# exec n8n with any args (default is just ["n8n"])
exec n8n "$@"
