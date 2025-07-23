#!/usr/bin/env bash
set -e

# 1) Install any community nodes into the mounted ~/.n8n
npm install --prefix /home/node/.n8n \
    --no-optional \
    n8n-nodes-puppeteer --legacy-peer-deps

# 2) Fix ownership so the node user can read them
chown -R node:node /home/node/.n8n/node_modules

# 3) Finally exec n8n as the node user
exec gosu node n8n "$@"
