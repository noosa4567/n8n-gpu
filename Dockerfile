# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 ── pull a proven, GPU-accelerated FFmpeg (dynamic, CUDA 12.0)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 ── runtime: CUDA 12.1-devel – n8n + (NO local Chrome) + Torch/Whisper
###############################################################################
FROM nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive

# NOTE:
# - We rely on a Chrome *sidecar* container. We do not install Chrome here.
# - Prevent puppeteer from downloading Chromium in this image.
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    TZ=Australia/Brisbane \
    PIP_ROOT_USER_ACTION=ignore \
    PATH=/usr/local/bin:$PATH \
    NODE_PATH=/usr/local/lib/node_modules \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

# 1) Base OS libs (unchanged)
RUN set -eux; \
    sed -i 's|http://archive.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g' /etc/apt/sources.list; \
    apt-get update -o Acquire::Retries=5; \
    apt-get install -y --no-install-recommends \
      software-properties-common ca-certificates curl git wget gnupg tini \
      python3.10 python3.10-venv python3.10-dev python3-pip \
      libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 \
      libatk-bridge2.0-0 libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 \
      libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 libva2 \
      libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 libsndio7.0 \
      libsdl2-2.0-0 fonts-liberation lsb-release xdg-utils libfreetype6 \
      libatspi2.0-0 libgcc1 libstdc++6 \
      poppler-utils poppler-data \
      ghostscript \
      fontconfig fonts-dejavu-core \
    || (apt-get update -o Acquire::Retries=5 && apt-get install -y --no-install-recommends --fix-missing \
      software-properties-common ca-certificates curl git wget gnupg tini \
      python3.10 python3.10-venv python3.10-dev python3-pip \
      libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 \
      libatk-bridge2.0-0 libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 \
      libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 libva2 \
      libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 libsndio7.0 \
      libsdl2-2.0-0 fonts-liberation lsb-release xdg-utils libfreetype6 \
      libatspi2.0-0 libgcc1 libstdc++6 \
      poppler-utils poppler-data \
      ghostscript \
      fontconfig fonts-dejavu-core); \
    rm -rf /var/lib/apt/lists/*

# 2) Legacy NVENC soname symlinks (unchanged)
RUN ln -sf /usr/lib/x86_64-linux-gnu/libsndio.so.7.0 /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva.so.2             /usr/lib/x86_64-linux-gnu/libva.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-drm.so.2         /usr/lib/x86_64-linux-gnu/libva-drm.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-x11.so.2         /usr/lib/x86_64-linux-gnu/libva-x11.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-wayland.so.2     /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

# 3) Strip NVIDIA GBM stubs (unchanged)
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# 4) Create non-root “node” user (unchanged)
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$HOME"

# 4b) Ensure Puppeteer’s config dir is writable by node (unchanged)
RUN mkdir -p /home/node/.config/puppeteer && \
    chown -R node:node /home/node/.config

# 5) Copy FFmpeg from stage (unchanged) + refresh ld cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg /usr/local/lib/*.so.* /usr/local/lib/
RUN ldconfig

# 6) Install Node 20, n8n & Puppeteer globally (unchanged)
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; \
    apt-get update -o Acquire::Retries=5; \
    apt-get install -y --no-install-recommends nodejs \
    || (apt-get update -o Acquire::Retries=5 && apt-get install -y --no-install-recommends --fix-missing nodejs); \
    npm install -g --unsafe-perm \
      n8n@1.104.2 \
      puppeteer@24.15.0 \
      n8n-nodes-puppeteer@1.4.1; \
    npm cache clean --force; \
    mkdir -p /home/node/.npm && chown -R node:node /home/node/.npm; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# 7) Torch/CUDA wheels + Whisper + Pyannote (ONLY librosa pin changed)
USER root
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install --no-cache-dir "numpy<2" && \
    python3.10 -m pip install --no-cache-dir \
      torch==2.3.1+cu121 \
      torchvision==0.18.1+cu121 \
      torchaudio==2.3.1+cu121 \
      --index-url https://download.pytorch.org/whl/cu121 && \
    python3.10 -m pip install --no-cache-dir \
      numba==0.61.2 \
      tiktoken==0.9.0 \
      git+https://github.com/openai/whisper.git@v20250625 \
      pyannote.audio>=3.1,<3.2 \
      "soundfile>=0.10.2,<0.11" \
      transformers==4.41.2 \
      librosa==0.10.2.post1 \
      scikit-learn==1.4.2 \
      pandas==2.2.2 \
      noisereduce==3.0.3

# 8) Whisper patch (unchanged)
RUN sed -i 's/segment_duration = 30\.0/segment_duration = 180.0/' \
    /usr/local/lib/python3.10/dist-packages/whisper/transcribe.py

# 9) Pre-download Whisper model (unchanged)
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    python3.10 -c "import whisper, os; whisper._download(whisper._MODELS['medium.en'], os.environ['WHISPER_MODEL_PATH'], in_memory=False)"

# 10) Symlink Whisper cache for node user (unchanged)
RUN mkdir -p /home/node/.cache && \
    ln -s "$WHISPER_MODEL_PATH" /home/node/.cache/whisper && \
    chown -h node:node /home/node/.cache/whisper

# 11) CUDA hwaccels check (unchanged)
RUN ffmpeg -hide_banner -hwaccels | grep -q cuda

# 12) Tiny PATH shim (unchanged)
RUN printf '%s\n' \
      '#!/bin/sh' \
      'export PATH=/usr/local/bin:$PATH' \
      'exec "$@"' \
    > /usr/local/bin/n8n-wrapper && chmod +x /usr/local/bin/n8n-wrapper

# 13) Health-check & entrypoint (unchanged)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR "$HOME"
EXPOSE 5678
ENTRYPOINT ["tini","--","/usr/local/bin/n8n-wrapper","n8n"]
CMD ["start"]
