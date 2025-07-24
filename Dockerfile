###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 Ubuntu 22.04, PyTorch, n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive

# 0) Base environment
ENV HOME=/home/node \
    TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    NODE_PATH=/usr/lib/node_modules

# 1) Create non-root node user & n8n config dir
RUN groupadd -r node \
 && useradd -r -g node -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# 2) Install tini, pip, git, Puppeteer prerequisites (for bundled Chromium)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip git \
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
 && rm -rf /var/lib/apt/lists/*

# 3) Copy GPU-enabled FFmpeg & libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node.js 20 (tarball), n8n and Puppeteer (bundled Chromium)
RUN curl -fsSL https://nodejs.org/dist/v20.19.4/node-v20.19.4-linux-x64.tar.xz -o node.tar.xz \
 && tar -xJf node.tar.xz -C /usr/local --strip-components=1 \
 && rm node.tar.xz \
 && ln -s /usr/local/bin/npm /usr/bin/npm \
 && ln -s /usr/local/bin/npx /usr/bin/npx \
 && npm install -g n8n@latest puppeteer@23.11.1 n8n-nodes-puppeteer --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node /usr/local/lib/node_modules

# 5) Install PyTorch/CUDA wheels, Whisper + tokenizer, pre-download model
RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && (python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
     || (sleep 5 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])")) \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 6) Pre-create n8n’s cache so startup can't fail mkdir
RUN mkdir -p "$HOME/.cache/n8n/public" \
 && chown -R node:node "$HOME/.cache"

# 7) Shared media dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# 8) Fail-fast if FFmpeg libs unresolved
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 9) Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 10) Drop privileges & expose port
USER node
EXPOSE 5678

# 11) Launch n8n
ENTRYPOINT ["tini","--","n8n"]
CMD []
