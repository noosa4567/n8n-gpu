#!/usr/bin/env bash
set -e

# (No need to switch user. We're already 'node'.)

# Delegate to n8n’s binary under tini:
exec "$@"
