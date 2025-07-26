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
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PATH="/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:${PATH}"

# 1) Create node@999 in video group & n8n home
RUN groupadd -r node \
 && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# 2) Drop any NVIDIA repo to avoid mirror mismatches
RUN rm -f /etc/apt/sources.list.d/cuda* /etc/apt/sources.list.d/nvidia*

# 3) Install system libs Puppeteer & FFmpeg need
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini git curl ca-certificates gnupg python3-pip xz-utils software-properties-common \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      libx11-6 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 \
      libxrender1 libxss1 libxtst6 libxi6 libxcursor1 \
      libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdbus-1-3 libexpat1 \
      libfontconfig1 libgbm1 libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
      libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
      fonts-liberation lsb-release wget xdg-utils libfreetype6 libatspi2.0-0 libgcc1 libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

# 4) Copy GPU-accelerated FFmpeg and update linker cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig \
 && rm -f /usr/local/lib/lib{asound,atk,atspi,cairo,cups,dbus,expat,fontconfig,gbm,glib,gtk,nspr,nss,pango,stdc++,x11,xcb,xcomposite,xcursor,xdamage,xext,xfixes,xi,xrandr,xrender,xss,xtst,harfbuzz,fribidi,thai,datrie,drm,wayland,EGL,GLES,glapi,va,vdpau,sndio,freetype}* \
 && ldconfig

# 5) Install Node.js 20.x
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# 6) Ensure Puppeteer cache dir exists
RUN mkdir -p /home/node/.cache/puppeteer

# 7) Globally install n8n, Puppeteer (download bundled Chromium), community node & ajv
# Updated to specify Puppeteer v24.14.0 (which pulls Chrome 138.0.7204.157) so it finds the Chrome it’s looking for
RUN npm install -g --unsafe-perm \
      n8n@1.104.1 \
      puppeteer@24.14.0 \  # Use Puppeteer v24.14.0 (Chrome 157) instead of 24.15.0
      n8n-nodes-puppeteer@1.4.1 \
      ajv@8.17.1 \
      --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node /home/node/.cache/puppeteer "$(npm root -g)"

# 8) Install Whisper & tokenizer, pre-download base model (with retry)
RUN pip3 install --no-cache-dir tiktoken openai-whisper==20250625 \
 && pip3 cache purge \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && (python3 -c "import whisper, os; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" || \
     (sleep 5 && python3 -c "import whisper, os; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])")) \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 9) Prepare runtime dirs & ownership
RUN mkdir -p \
      "$HOME/.cache/n8n/public" \
      /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared \
 && chmod -R 770 /data/shared "$HOME/.cache"

# 10) Sanity‐check FFmpeg linkage
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "❌ unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 11) Init Conda for non-root user
RUN su - node -c "/opt/conda/bin/conda init bash" \
 && chown node:node "$HOME/.bashrc"

# 12) Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:5678/healthz || exit 1

# 13) Final drop to non-root & launch
USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini","--","n8n","start"]
CMD []
