###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 Ubuntu 22.04, n8n + Puppeteer + Whisper + FFmpeg
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive

# Fundamental environment
ENV HOME=/home/node \
    TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    NODE_PATH=/usr/lib/node_modules \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    PATH=/usr/local/lib/nodejs/bin:/opt/conda/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Create non-root user and n8n directory
RUN groupadd -r node \
 && useradd -r -g node -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# Install system deps, Chrome repo + Chrome, and xz-utils
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      apt-transport-https ca-certificates curl gnupg lsb-release wget xdg-utils \
      xz-utils tini python3-pip git \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
      libexpat1 libfontconfig1 libgbm1 libgtk-3-0 libnspr4 libnss3 \
      libpango-1.0-0 libpangocairo-1.0-0 libxcomposite1 libxcursor1 \
      libxdamage1 libxi6 libxrandr2 libxrender1 libxss1 libxtst6 \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      libcairo2 libfribidi0 libharfbuzz0b libthai0 libdatrie1 \
 && mkdir -p /usr/share/keyrings \
 && wget -qO - https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] \
      https://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

# Copy FFmpeg binaries & libs, refresh ld cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# Install Node.js 20 tarball (with npm) + n8n + Puppeteer community node
RUN curl -fsSL https://nodejs.org/dist/v20.19.4/node-v20.19.4-linux-x64.tar.xz -o node.tar.xz \
 && mkdir -p /usr/local/lib/nodejs \
 && tar -xJf node.tar.xz -C /usr/local/lib/nodejs --strip-components=1 \
 && rm node.tar.xz \
 && npm install -g n8n@1.104.0 puppeteer@23.11.1 n8n-nodes-puppeteer --legacy-peer-deps \
 && npm cache clean --force

# Install PyTorch (GPU wheels), Whisper + pre-download
RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir openai-whisper \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import whisper, os; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# Pre-create n8n cache dir (avoids EACCES on startup)
RUN mkdir -p "$HOME/.cache/n8n/public" \
 && chown -R node:node "$HOME/.cache"

# Prepare shared media dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# Verify FFmpeg linkage
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# Healthcheck endpoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:5678/healthz || exit 1

# Drop privileges, expose port & start n8n
USER node
EXPOSE 5678
ENTRYPOINT ["tini","--","n8n"]
CMD []
