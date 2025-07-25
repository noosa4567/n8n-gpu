# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 Ubuntu 22.04 w/ n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 1) Create non-root "node" user (in "video" group for /dev/nvidia access) and .n8n dir
RUN groupadd -r node \
 && useradd -r -g node -G video -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# 2) Install runtime deps: tini, Python3, xz-utils, Puppeteer libs
# Disable NVIDIA repo to avoid mirror hash mismatches during apt-get update
RUN rm -f /etc/apt/sources.list.d/cuda.list /etc/apt/sources.list.d/nvidia.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip curl ca-certificates xz-utils \
      libnss3 libxss1 libasound2 libcups2 libatk-bridge2.0-0 libgtk-3-0 \
      libxkbcommon-x11-0 libxcomposite1 libxdamage1 libgbm1 \
      libpangocairo-1.0-0 libxrandr2 libxrender1 libxext6 libxi6 \
      libxtst6 libxcursor1 libgconf-2-4 libappindicator1 libfontconfig1 \
      fonts-liberation \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy GPU-enabled FFmpeg & libs, refresh linker cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node.js 20 (official tarball)
RUN curl -fsSL https://nodejs.org/dist/v20.19.4/node-v20.19.4-linux-x64.tar.xz -o node.tar.xz \
 && tar -xJf node.tar.xz -C /usr/local --strip-components=1 \
 && rm node.tar.xz

# 5) Switch to node, install n8n + Puppeteer locally (bundles its own Chromium)
USER node
WORKDIR /home/node
RUN npm init -y \
 && npm install n8n@latest puppeteer@23.11.1 n8n-nodes-puppeteer --legacy-peer-deps \
 && npm cache clean --force

# 6) Back to root: extract & install the Chrome sandbox helper
USER root
RUN SANDBOX=$(find /home/node/.cache/puppeteer -name chrome_sandbox -print -quit) \
 && if [ -n "$SANDBOX" ]; then \
      install -o root -g root -m 4755 "$SANDBOX" /usr/local/sbin/chrome-devel-sandbox; \
    fi

# 7) Install PyTorch/CUDA wheels, Whisper + tokenizer, pre-download "base" model
RUN python3 -m pip install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && python3 -m pip install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import whisper; whisper.load_model('base', download_root='${WHISPER_MODEL_PATH}')" \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 8) Pre-create cache & shared data dirs, chown everything to node
RUN mkdir -p "$HOME/.cache/n8n/public" /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared

# 9) Healthcheck for n8n readiness
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 10) Drop to non-root, expose port, wrap in tini, launch n8n
USER node
EXPOSE 5678
ENTRYPOINT ["tini","--","/home/node/node_modules/.bin/n8n"]
CMD []
