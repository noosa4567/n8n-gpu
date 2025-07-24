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
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    PATH=/usr/local/lib/nodejs/bin:/opt/conda/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1) Create non-root user, n8n dir & cache
RUN groupadd -r node \
 && useradd -r -g node -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" "$HOME/.cache/n8n/public" \
 && chown -R node:node "$HOME"

# 2) Copy GPU-enabled FFmpeg; strip old GBM; update cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/*.so*   /usr/local/lib/
RUN rm -f /usr/local/lib/libgbm* \
 && ldconfig

# 3) System libraries + Google Chrome
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
 && wget -qO - https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/googlechrome-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/googlechrome-keyring.gpg] \
      http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

# 4) Node 20 via tarball + global n8n & Puppeteer
RUN curl -fsSL https://nodejs.org/dist/v20.19.4/node-v20.19.4-linux-x64.tar.xz -o node.tar.xz \
 && mkdir -p /usr/local/lib/nodejs \
 && tar -xJf node.tar.xz -C /usr/local/lib/nodejs --strip-components=1 \
 && ln -s /usr/local/lib/nodejs/bin/{node,npm,npx} /usr/bin/ \
 && rm node.tar.xz \
 && npm install -g n8n@1.104.0 puppeteer@23.11.1 n8n-nodes-puppeteer --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node /usr/local/lib/nodejs

# 5) PyTorch/CUDA, Whisper + tokenizer, pre-download base model
RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "$WHISPER_MODEL_PATH" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "$WHISPER_MODEL_PATH"

# 6) Shared data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# 7) Verify FFmpeg
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 8) Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 9) Use non-root & expose
USER node
EXPOSE 5678

# 10) Start n8n via tini
ENTRYPOINT ["tini","--","n8n"]
CMD []
