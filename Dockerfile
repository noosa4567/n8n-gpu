###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 Ubuntu 22.04, PyTorch, n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive

ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    NODE_PATH=/usr/lib/node_modules \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PATH=/opt/conda/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1) Create non-root 'node' user, config & cache dirs
RUN groupadd -r node \
 && useradd -r -g node -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" "$HOME/.cache/n8n" "$HOME/.cache/puppeteer" \
 && chown -R node:node "$HOME"

# 2) Install tini, pip, git & all libs Puppeteer’s Chromium needs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini git python3-pip wget ca-certificates xdg-utils lsb-release \
      fonts-liberation libappindicator1 libasound2 libatk-bridge2.0-0 libatk1.0-0 \
      libc6 libcairo2 libcups2 libdbus-1-3 libexpat1 libfontconfig1 libgconf-2-4 \
      libgdk-pixbuf2.0-0 libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
      libpango-1.0-0 libpangocairo-1.0-0 libstdc++6 libx11-6 libx11-xcb1 \
      libxcb1 libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 \
      libxi6 libxrandr2 libxrender1 libxss1 libxtst6 libgbm1 \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy GPU-enabled FFmpeg & libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node.js, n8n CLI, Puppeteer 23.11.1 & community node — force Chromium download
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n@1.104.0 puppeteer@23.11.1 n8n-nodes-puppeteer --legacy-peer-deps \
 && npm explore puppeteer -- npm run install \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R node:node /usr/lib/node_modules

# 5) Install PyTorch/CUDA wheels, Whisper + tokenizer, pre-download model
RUN pip3 install --no-cache-dir --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 tiktoken openai-whisper \
 && mkdir -p "$WHISPER_MODEL_PATH" \
 && (python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
     || (sleep 5 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])")) \
 && chown -R node:node "$WHISPER_MODEL_PATH"

# 6) Shared dirs for your media
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# 7) Healthcheck for n8n
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 8) Drop to non-root & expose
USER node
EXPOSE 5678

# 9) Launch
ENTRYPOINT ["tini","--","n8n"]
CMD []
