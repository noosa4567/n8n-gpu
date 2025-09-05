# =========================
# Dockerfile n8n-gpu v12 (sidecar-only, fixed)
# - Removes local Chrome entirely (no google-chrome, no Chromium)
# - Installs puppeteer-core and n8n-nodes-puppeteer only
# - Prevents Chromium auto-download at build/run
# - Expects WS endpoint via env: PUPPETEER_BROWSER_WS_ENDPOINT
# =========================
FROM node:20-bullseye

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Australia/Brisbane \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PUPPETEER_BROWSER_WS_ENDPOINT=

# -------- System deps --------
RUN apt-get update && apt-get install -y --no-install-recommends \    ca-certificates \    curl \    wget \    gnupg2 \    git \    jq \    fonts-liberation \    xdg-utils \    libcups2 \    libnss3 \    libxss1 \    libasound2 \    libatk-bridge2.0-0 \    libgtk-3-0 \    libdrm2 \    libgbm1 \    libxshmfence1 \    libx11-xcb1 \    libxcb-dri3-0 \    libxcomposite1 \    libxdamage1 \    libxrandr2 \    libu2f-udev \    libvulkan1 \    unzip \    rsync \    procps \    tzdata \    python3 \    python3-pip \    ffmpeg \    ghostscript \  && rm -rf /var/lib/apt/lists/*

# -------- n8n + puppeteer stack --------
# Pin versions for stability
ENV N8N_VERSION=1.104.2 \    PUPPETEER_CORE_VERSION=24.15.0 \    N8N_PUPPETEER_NODES_VERSION=1.4.1 \    PUPPETEER_EXTRA_VERSION=3.3.6 \    PUPPETEER_STEALTH_VERSION=2.11.2

RUN npm config set puppeteer_skip_download true \ && npm install -g --unsafe-perm \      n8n@${N8N_VERSION} \      puppeteer-core@${PUPPETEER_CORE_VERSION} \      n8n-nodes-puppeteer@${N8N_PUPPETEER_NODES_VERSION} \      puppeteer-extra@${PUPPETEER_EXTRA_VERSION} \      puppeteer-extra-plugin-stealth@${PUPPETEER_STEALTH_VERSION}

# -------- Optional Python bits (CPU torch, whisper) --------
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel \ && pip3 install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu \      torch==2.4.0 \      torchaudio==2.4.0 \ && pip3 install --no-cache-dir openai-whisper==20231117

# App user & workspace
RUN useradd -m -u 999 node || true
USER node
WORKDIR /home/node

# Folders for caches and certs
RUN mkdir -p /home/node/.n8n /home/node/.cache /usr/local/lib/whisper_models
VOLUME ["/home/node/.n8n", "/home/node/.cache", "/usr/local/lib/whisper_models"]

ENV N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true \    N8N_VERSION_NOTIFICATIONS_ENABLED=false \    NODE_ENV=production

EXPOSE 5678
CMD ["n8n"]
