# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 • Pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 Ubuntu 22.04, n8n, Whisper, FFmpeg & Puppeteer
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/nvidia/nvidia:/usr/local/nvidia/nvidia.u18.04 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer

# 1) Create non-root 'node'@999 in 'video' group & prep its home
RUN groupadd -r node \
 && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# 2) Drop leftover NVIDIA APT lists (avoids hash mismatches)
RUN rm -f /etc/apt/sources.list.d/cuda* /etc/apt/sources.list.d/nvidia*

# 3) Install system libs for FFmpeg, Whisper audio I/O, Puppeteer **+ SDL2**
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini git curl ca-certificates gnupg \
      python3 python3-pip xz-utils \
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
      **libsdl2-2.0-0** \
 && rm -rf /var/lib/apt/lists/*

# 4) Copy in GPU-built FFmpeg and its libs, clean up old FriBidi
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN rm -f /usr/local/lib/libfribidi.so.0* && ldconfig

# 5) Install Node.js 20.x
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# 6) Prep Puppeteer cache dir
RUN mkdir -p /home/node/.cache/puppeteer

# 7) Globally install n8n, Puppeteer@24.14.0 (bundles Chrome 138), community node & ajv
RUN npm install -g --unsafe-perm \
      n8n@1.104.1 \
      puppeteer@24.14.0 \
      n8n-nodes-puppeteer@1.4.1 \
      ajv@8.17.1 \
      --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node /home/node/.cache/puppeteer "$(npm root -g)"

# 8) Install PyTorch/CUDA, Whisper & tokenizer, pre-download base model
RUN pip3 install --no-cache-dir --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir tiktoken openai-whisper==20240930 \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 9) Create runtime cache & media dirs, fix perms
RUN mkdir -p \
      "$HOME/.cache/n8n/public" \
      /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared \
 && chmod -R 770 /data/shared "$HOME/.cache"

# 10) Verify no missing FFmpeg libs
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "❌ unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 11) Switch to non-root & launch n8n
USER node
WORKDIR $HOME
EXPOSE 5678
ENTRYPOINT ["tini","--","n8n","start"]
CMD []
