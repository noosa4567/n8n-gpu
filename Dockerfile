###############################################################################
# Stage 1 • prebuilt GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8, PyTorch 2.1, n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive

# 0) Make sure home is correct for Puppeteer cache, npm, .n8n, etc.
ENV HOME=/home/node \
    TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    NODE_PATH=/home/node/.n8n/node_modules \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer

# 1) Create non-root user & initial directories
RUN groupadd -r node \
 && useradd -r -g node -m -d /home/node -s /bin/bash node \
 && mkdir -p /home/node/.n8n /home/node/.cache/puppeteer /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /home/node

# 2) Install tini, pip, git & all system deps for headless Chrome + FFmpeg
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip git \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
      libexpat1 libfontconfig1 libgbm1 libgtk-3-0 libnspr4 libnss3 \
      libpango-1.0-0 libpangocairo-1.0-0 libxcomposite1 libxcursor1 \
      libxdamage1 libxi6 libxrandr2 libxss1 libxtst6 lsb-release wget xdg-utils \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy GPU-enabled FFmpeg from builder
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node.js 20 & n8n CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n@1.104.0 \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R node:node /usr/lib/node_modules

# 5) Install Whisper & pre-download model (single-line, no heredoc)
RUN pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import whisper; whisper.load_model('base', download_root='${WHISPER_MODEL_PATH}')" \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 6) Verify FFmpeg linkage
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 7) Health-check
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 8) Switch to non-root for Puppeteer install
USER node

# 9) Install Puppeteer 23.11.1 + n8n-nodes-puppeteer into your ~/.n8n
RUN npm install --prefix /home/node/.n8n \
      puppeteer@23.11.1 n8n-nodes-puppeteer --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node /home/node/.n8n /home/node/.cache/puppeteer

# 10) Expose & launch
EXPOSE 5678
ENTRYPOINT ["tini","--","n8n"]
CMD []
