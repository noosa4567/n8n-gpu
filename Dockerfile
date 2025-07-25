###############################################################################
# 1) Stage • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# 2) Stage • Runtime: CUDA 11.8 Ubuntu 22.04 + n8n, Puppeteer, Whisper, FFmpeg
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    TZ=Australia/Brisbane \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# 2.1) Create non-root “node” user
RUN useradd --create-home --shell /bin/bash --uid 1000 node

# 2.2) Install system deps (tini, git, curl, Python³, Puppeteer libs)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini \
      git \
      curl \
      ca-certificates \
      python3 \
      python3-pip \
      libnss3 libxss1 libasound2 libcups2 \
      libatk-bridge2.0-0 libgtk-3-0 \
      libxcomposite1 libxdamage1 libgbm1 \
      libpangocairo-1.0-0 libpango-1.0-0 \
      libxrandr2 libxrender1 libxi6 libxtst6 libxcursor1 \
      fonts-liberation \
      libfribidi0 libharfbuzz0b libthai0 libdatrie1 \
 && rm -rf /var/lib/apt/lists/*

# 2.3) Copy FFmpeg & libs from FFmpeg stage
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 2.4) Install Node.js 20.x (via NodeSource)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# 2.5) Globally install n8n, Puppeteer & community node
RUN npm install -g \
      n8n@latest \
      puppeteer@23.11.1 \
      n8n-nodes-puppeteer \
      --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node /usr/local/lib/node_modules

# 2.6) Install PyTorch (cu118), Whisper + tokenizer, pre-download “base”
RUN pip3 install --no-cache-dir \
      numpy==1.26.3 \
 && pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 \
 && pip3 install --no-cache-dir \
      tiktoken \
      openai-whisper \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && rm -rf /root/.cache \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 2.7) Pre-create n8n runtime dirs (avoid EACCES on startup)
RUN mkdir -p \
      "$HOME/.n8n" \
      "$HOME/.cache/n8n/public" \
      /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared

# 2.8) Healthcheck on n8n
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 2.9) Drop to non-root & expose + launch
USER node
WORKDIR $HOME
EXPOSE 5678
ENTRYPOINT ["tini","--","n8n"]
CMD ["start"]
