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
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64

# 1) Create non-root 'node' user (UID 999) in 'video' group & prep its home
RUN groupadd -r node \
 && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# 2) Remove NVIDIA/CUDA APT lists to avoid mirror mismatches
RUN rm -f /etc/apt/sources.list.d/cuda* /etc/apt/sources.list.d/nvidia*

# 3) Add PPA for modern Mesa to support Puppeteer Chrome GBM linkage
RUN apt-get update \
 && apt-get install -y --no-install-recommends software-properties-common \
 && add-apt-repository ppa:oibaf/graphics-drivers -y \
 && apt-get update

# 4) Install all dependencies (including libxv1 for FFmpeg audio decoding)
RUN apt-get install -y --no-install-recommends \
      tini git curl ca-certificates gnupg wget xz-utils \
      python3 python3-pip binutils \
      libsndio7.0 libasound2 libsdl2-2.0-0 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      libx11-6 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 \
      libxrender1 libxss1 libxtst6 libxi6 libxcursor1 libxv1 \
      libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdbus-1-3 libexpat1 \
      libfontconfig1 libgbm1 libegl1-mesa libgl1-mesa-dri libdrm2 \
      libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
      libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
      fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 libgcc1 libstdc++6 \
      libnvidia-egl-gbm1 \
 && rm -rf /var/lib/apt/lists/*

# 5) Fix Puppeteer GBM error by removing NVIDIA's bad libgbm.so.1
RUN rm -f /usr/local/nvidia/lib/libgbm.so.1 /usr/local/nvidia/lib64/libgbm.so.1

# 6) Pull in Bionic's libsndio6.1 for FFmpeg’s old dependency
RUN wget -qO /tmp/libsndio6.1.deb \
      http://security.ubuntu.com/ubuntu/pool/universe/s/sndio/libsndio6.1_1.1.0-3_amd64.deb \
 && dpkg -i /tmp/libsndio6.1.deb \
 && rm /tmp/libsndio6.1.deb

# 7) Copy in GPU-accelerated FFmpeg & its libs, strip out vendored libfribidi
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN rm -f /usr/local/lib/libfribidi.so.0* \
 && ldconfig

# 8) Install Node.js 20.x
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# 9) Prepare Puppeteer cache directory
RUN mkdir -p "$PUPPETEER_CACHE_DIR" \
 && chown node:node "$PUPPETEER_CACHE_DIR"

# 10) Globally install n8n, Puppeteer (Chrome 138), n8n-nodes-puppeteer, ajv
USER root
RUN npm install -g --unsafe-perm \
      n8n@1.104.1 \
      puppeteer@24.14.0 \
      n8n-nodes-puppeteer@1.4.1 \
      ajv@8.17.1 \
      --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node "$PUPPETEER_CACHE_DIR" "$(npm root -g)"

# 11) Install PyTorch CUDA, Whisper, tokenizer, and pre-download the "base" model
RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "$WHISPER_MODEL_PATH" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "$WHISPER_MODEL_PATH"

# 12) Pre-create & chown runtime dirs (n8n cache, shared media)
RUN mkdir -p \
      "$HOME/.cache/n8n/public" \
      /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared \
 && chmod -R 770 /data/shared "$HOME/.cache"

# 13) Sanity-check FFmpeg linkage
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "❌ unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 14) Drop to non-root user & start n8n
USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini","--","n8n","start"]
CMD []
