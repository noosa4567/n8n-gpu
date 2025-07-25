# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 Ubuntu 22.04, PyTorch, n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

# avoid interactive prompts
ARG DEBIAN_FRONTEND=noninteractive

# preserve your timezone, home dir, whisper model path
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable

###############################################################################
# 1) Create node user (UID 999) in video group for GPU access & n8n config dir
###############################################################################
RUN groupadd -r node \
 && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

###############################################################################
# 2) Install system deps:
#    • tini (PID 1)
#    • Python tooling
#    • all XCB/libs that ffmpeg + Chrome need (including libxcb-shape0)
#    • Chrome Puppeteer dependencies
###############################################################################
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini git curl ca-certificates gnupg \
      python3 python3-pip \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      libxcb1 libxcb-shm0 libxcb-render0 libxcb-shape0 libxcb-xfixes0 \
      libx11-6 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 \
      libxrender1 libxss1 libxtst6 libxi6 libxcursor1 \
      libatk-bridge2.0-0 libatk1.0-0 libcups2 libgtk-3-0 \
      libpangocairo-1.0-0 libpango-1.0-0 libfontconfig1 \
      fonts-liberation libfribidi0 libharfbuzz0b libthai0 libdatrie1 \
 && rm -rf /var/lib/apt/lists/*

###############################################################################
# 3) Copy GPU-enabled FFmpeg and libraries, rebuild linker cache
###############################################################################
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

###############################################################################
# 4) Install Google Chrome Stable (for Puppeteer)
###############################################################################
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
     | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] \
     http://dl.google.com/linux/chrome/deb/ stable main" \
     > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

###############################################################################
# 5) Install Node.js 20 & npm
###############################################################################
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

###############################################################################
# 6) Globally install n8n, Puppeteer (uses system Chrome), community node & ajv
#    Adding ajv peer ensures express-openapi-validator loads correctly.
###############################################################################
RUN npm install -g \
      n8n@latest \
      puppeteer@23.11.1 \
      n8n-nodes-puppeteer \
      ajv@8.17.1 \
      --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node "$(npm root -g)"

###############################################################################
# 7) Install PyTorch/CUDA wheels, Whisper & tokenizer, then pre-download model
###############################################################################
RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir tiktoken openai-whisper==20240930 \
 && mkdir -p "$WHISPER_MODEL_PATH" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && rm -rf /root/.cache \
 && chown -R node:node "$WHISPER_MODEL_PATH"

###############################################################################
# 8) Pre-create & chown runtime dirs (n8n cache, Puppeteer cache, shared media)
###############################################################################
RUN mkdir -p \
      "$HOME/.cache/n8n/public" \
      "$HOME/.cache/puppeteer" \
      /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared

###############################################################################
# 9) Verify FFmpeg linkage at build time
###############################################################################
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️  Unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

###############################################################################
# 10) Healthcheck for n8n readiness
###############################################################################
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:5678/healthz || exit 1

###############################################################################
# 11) Switch to non-root, expose port & start n8n in server ("start") mode
###############################################################################
USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini","--","n8n","start"]
CMD []
