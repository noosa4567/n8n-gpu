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
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    NODE_PATH=/usr/lib/node_modules \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# 1) Create non-root “node” user and n8n config dir
RUN groupadd -r node \
 && useradd -r -g node -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME/.n8n"

# 2) Install tini, pip, git, gnupg, Puppeteer & Chrome deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip git gnupg \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
      fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
      libexpat1 libfontconfig1 libgbm1 libgtk-3-0 libnspr4 libnss3 \
      libpango-1.0-0 libpangocairo-1.0-0 libxcomposite1 libxcursor1 \
      libxdamage1 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      lsb-release wget xdg-utils \
      libcairo2 libfribidi0 libharfbuzz0b libthai0 libdatrie1 \
 && wget -q -O - https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/googlechrome-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/googlechrome-keyring.gpg] \
     http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy FFmpeg + ffprobe + libs, then update linker cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node.js 20, n8n CLI, Puppeteer & community node globally
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n@1.104.0 \
 && npm install -g puppeteer@23.11.1 n8n-nodes-puppeteer --legacy-peer-deps \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R node:node /usr/lib/node_modules

# 5) Install PyTorch GPU wheels + Whisper + tokenizer; pre-download base model
RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "$WHISPER_MODEL_PATH" \
 && python3 - << 'PYTHON'
import os, whisper
whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])
PYTHON
 && chown -R node:node "$WHISPER_MODEL_PATH"

# 6) Prepare shared data directories
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# 7) Verify FFmpeg linkage
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 8) Healthcheck
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 9) Drop to non-root and expose port
USER node
EXPOSE 5678

# 10) Launch n8n via tini
ENTRYPOINT ["tini","--","n8n"]
CMD []
