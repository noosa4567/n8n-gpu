###############################################################################
# Stage 1  •  pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2  •  Runtime: CUDA 11.8 PyTorch, n8n, Puppeteer & FFmpeg
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive

# Tell everything that HOME is /home/node, set timezone, paths, and extension settings
ENV HOME=/home/node \
    TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    NODE_PATH=/usr/lib/node_modules \
    N8N_CUSTOM_EXTENSIONS=/usr/lib/node_modules/n8n-nodes-puppeteer/dist

# 1) Create non-root "node" user & ensure ~/.n8n exists
RUN groupadd -r node \
 && useradd -r -g node -m -d $HOME -s /bin/bash node \
 && mkdir -p $HOME/.n8n \
 && chown -R node:node $HOME/.n8n

# 2) Install tini, pip, git, and all Puppeteer/Chromium runtime deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip git \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 libexpat1 libfontconfig1 libgbm1 \
      libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 \
      libxcomposite1 libxcursor1 libxdamage1 libxi6 libxrandr2 libxss1 libxtst6 \
      lsb-release wget xdg-utils \
 && rm -rf /var/lib/apt/lists/*

# 3) Bring in GPU-enabled FFmpeg binaries/libs, refresh linker cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node 20, then globally install n8n, Puppeteer & the community node
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g \
      n8n@1.104.0 \
      puppeteer@23.11.1 \
      n8n-nodes-puppeteer \
      --legacy-peer-deps \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R node:node /usr/lib/node_modules /home/node

# 5) Install Whisper + tokenizer
RUN pip3 install --no-cache-dir tiktoken openai-whisper

# 6) Pre-download the Whisper "base" model
RUN mkdir -p "$WHISPER_MODEL_PATH" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "$WHISPER_MODEL_PATH"

# 7) Prepare shared data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# 8) Verify FFmpeg linkage early
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 9) Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 10) Drop to non-root and expose port
USER node
EXPOSE 5678

# 11) Launch n8n via tini (pure upstream behavior)
ENTRYPOINT ["tini","--","n8n"]
CMD []
