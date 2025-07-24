###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 Ubuntu 22.04, PyTorch, n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive

ENV HOME=/home/node \
    TZ=Australia/Brisbane \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 1) System dependencies: tini, git, xz-utils, python3-pip, Puppeteer libs
RUN apt-get update && apt-get install -y --no-install-recommends \
      tini \
      git \
      xz-utils \
      curl \
      ca-certificates \
      python3 \
      python3-pip \
      libnss3 \
      libxss1 \
      libasound2 \
      libcups2 \
      libatk-bridge2.0-0 \
      libgtk-3-0 \
      libxcomposite1 \
      libxdamage1 \
      libgbm1 \
      libpangocairo-1.0-0 \
      libpango-1.0-0 \
      libxrandr2 \
      libxrender1 \
      libxi6 \
      libxtst6 \
      libxcursor1 \
      fonts-liberation \
      libfribidi0 \
      libharfbuzz0b \
      libthai0 \
      libdatrie1 \
 && rm -rf /var/lib/apt/lists/*

# 2) Copy GPU-enabled FFmpeg + libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 3) Install Node.js 20 + npm via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# 4) Globally install n8n, Puppeteer (bundled Chromium) & community node
RUN npm install -g \
      n8n@latest \
      puppeteer@23.11.1 \
      n8n-nodes-puppeteer \
      --legacy-peer-deps \
 && npm cache clean --force

# 5) Whisper + PyTorch (GPU) + tiktoken + pre-download “base” model
RUN pip3 install --no-cache-dir numpy==1.26.3 \
 && pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 \
 && pip3 install --no-cache-dir \
      tiktoken \
      openai-whisper==20240930 \
 # now pull down the base model into our shared path
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && rm -rf /root/.cache \
 # ensure node user can read it
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 6) Create non-root user & pre-create all runtime dirs (avoid any EACCES)
RUN useradd -m -u 1000 -s /bin/bash node \
 && mkdir -p \
      "$HOME/.n8n" \
      "$HOME/.cache/n8n/public" \
      /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared

# 7) Healthcheck on n8n HTTP endpoint
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 8) Switch to non-root, expose port, launch under tini
USER node
WORKDIR /home/node
EXPOSE 5678
ENTRYPOINT ["tini","--","n8n"]
CMD []
