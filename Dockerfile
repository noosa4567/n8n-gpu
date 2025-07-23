###############################################################################
# 0) Tell everything that the home dir is /home/node
###############################################################################
ENV HOME=/home/node

###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 PyTorch, n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    NODE_PATH=/home/node/.n8n/node_modules \
    # Ensure Puppeteer uses its bundled Chromium
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# 1) Create non-root "node" user and n8n config dir
RUN groupadd -r node \
 && useradd -r -g node -m -d /home/node -s /bin/bash node \
 && mkdir -p /home/node/.n8n \
 && chown -R node:node /home/node/.n8n

# 2) Install tini, pip, git & all required libs for FFmpeg + Puppeteer/Chromium
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip git \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
      # Puppeteer deps:
      fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
      libexpat1 libfontconfig1 libgbm1 libgtk-3-0 libnspr4 libnss3 \
      libpango-1.0-0 libpangocairo-1.0-0 libxcomposite1 libxcursor1 \
      libxdamage1 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      lsb-release wget xdg-utils \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy GPU-enabled FFmpeg & libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node.js 20 & the n8n CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n@1.104.0 \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

# 5) Install Whisper, then pre-download the "base" model
RUN pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 6) Prep shared data directories
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# 7) Fail-fast if FFmpeg libs are broken
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️ Unresolved FFmpeg libraries" >&2 && exit 1) \
     || echo "✅ FFmpeg libraries OK"

# 8) Healthcheck for n8n
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 9) Drop to non-root & install Puppeteer + Puppeteer community node
USER node
RUN npm install --prefix /home/node/.n8n \
      puppeteer@23.11.1 \
      n8n-nodes-puppeteer \
      --legacy-peer-deps

EXPOSE 5678

# 10) Launch n8n under tini in default server mode
ENTRYPOINT ["tini","--","n8n"]
CMD []
