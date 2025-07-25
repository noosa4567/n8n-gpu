# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 PyTorch 2.1, n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/nvidia/nvidia:/usr/local/nvidia/nvidia.u18.04 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    PATH="/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:${PATH}"

# 1) Create node user (UID 999) in video group for GPU access & n8n config dir
RUN groupadd -r node \
 && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# 2) Disable NVIDIA/CUDA repos to prevent mirror sync issues during apt-get update
RUN rm -f /etc/apt/sources.list.d/cuda* /etc/apt/sources.list.d/nvidia*

# 3) Install system deps (added libfreetype6 for Chrome/FFmpeg font support)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini git curl ca-certificates gnupg python3-pip xz-utils \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      libx11-6 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 \
      libxrender1 libxss1 libxtst6 libxi6 libxcursor1 \
      libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdbus-1-3 libexpat1 \
      libfontconfig1 libgbm1 libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
      libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
      fonts-liberation lsb-release wget xdg-utils libfreetype6 \
 && rm -rf /var/lib/apt/lists/*

# 4) Install Google Chrome Stable (for Puppeteer)
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
     | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] \
     http://dl.google.com/linux/chrome/deb/ stable main" \
     > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

# 5) Copy GPU-enabled FFmpeg and libraries, rebuild linker cache, then remove conflicting libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig \
 && rm -f /usr/local/lib/libfontconfig* /usr/local/lib/libfreetype* /usr/local/lib/libpango* /usr/local/lib/libfribidi* \
 && ldconfig 

# 6) Install Node.js 20 & npm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# 7) Globally install n8n, Puppeteer (uses system Chrome), community node & ajv
RUN npm install -g \
      n8n@1.104.1 \
      puppeteer@24.15.0 \
      n8n-nodes-puppeteer \
      ajv@8.17.1 \
      --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node "$(npm root -g)"

# 8) Install Whisper & tokenizer, then pre-download "base" model (with retry; updated pin to valid latest)
RUN pip3 install --no-cache-dir tiktoken openai-whisper==20250625 \
 && pip3 cache purge \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && (python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" || \
     (sleep 5 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])")) \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 9) Pre-create & chown runtime dirs (n8n cache, Puppeteer cache, shared media)
RUN mkdir -p \
      "$HOME/.cache/n8n/public" \
      "$HOME/.cache/puppeteer" \
      /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared \
 && chmod -R 770 /data/shared "$HOME/.cache"

# 10) Verify FFmpeg linkage at build time
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️  unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 11) Initialize Conda for non-root 'node' user (sets up .bashrc with PATH and activation)
RUN su - node -c "/opt/conda/bin/conda init bash" \
 && chown node:node "$HOME/.bashrc"

# 12) Healthcheck for n8n readiness
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:5678/healthz || exit 1

# 13) Switch to non-root, expose port & start n8n in server ("start") mode
USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini","--","n8n","start"]
CMD []
