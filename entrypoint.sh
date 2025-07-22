#!/usr/bin/env bash
set -e

# if puppeteer/node modules not yet in the mounted .n8n, install them
if [ ! -d "/home/node/.n8n/node_modules/n8n-nodes-puppeteer" ]; then
  echo "🔧 Installing Puppeteer & community nodes into ~/.n8n"
  npm install --prefix /home/node/.n8n \
    puppeteer n8n-nodes-puppeteer --legacy-peer-deps
  chown -R node:node /home/node/.n8n
fi

# hand off to n8n under tini
exec tini -- n8n "$@"
