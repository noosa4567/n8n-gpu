# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 ─── proven GPU-accelerated FFmpeg (dynamic, CUDA 12.0)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 ─── runtime: CUDA 12.1-devel – n8n + Torch/Whisper (+ puppeteer-core)
###############################################################################
FROM nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive

# --- Environment --------------------------------------------------------------
ENV HOME=/home/node \
    TZ=Australia/Brisbane \
    PATH=/usr/local/bin:$PATH \
    NODE_PATH=/usr/local/lib/node_modules \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PIP_ROOT_USER_ACTION=ignore \
    # IMPORTANT: do NOT download Chromium; we use Chrome sidecar via wsEndpoint
    PUPPETEER_SKIP_DOWNLOAD=true

# --- Make apt more resilient (mirror list + retries) --------------------------
# This does NOT change packages or versions; it only improves mirror reliability
RUN set -eux; \
    sed -i 's|http://archive.ubuntu.com/ubuntu|mirror://mirrors.ubuntu.com/mirrors.txt|g' /etc/apt/sources.list; \
    echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries

# --- Base OS libs (unchanged functional set from v1008) -----------------------
RUN set -eux; \
    apt-get update -o Acquire::Retries=5; \
    apt-get install -y --no-install-recommends \
      software-properties-common ca-certificates curl git wget gnupg tini && \
    add-apt-repository -y universe; \
    apt-get update -o Acquire::Retries=5; \
    apt-get install -y --no-install-recommends \
      python3.10 python3.10-venv python3.10-dev python3-pip \
      libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 \
      libatk-bridge2.0-0 libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 \
      libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 libva2 \
      libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 libsndio7.0 \
      libsdl2-2.0-0 fonts-liberation lsb-release xdg-utils libfreetype6 \
      libatspi2.0-0 libgcc-s1 libstdc++6 \
      poppler-utils poppler-data \
      ghostscript \
      fontconfig fonts-dejavu-core \
      || (apt-get update -o Acquire::Retries=5 && \
          apt-get install -y --no-install-recommends --fix-missing \
            python3.10 python3.10-venv python3.10-dev python3-pip \
            libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 \
            libatk-bridge2.0-0 libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 \
            libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 libva2 \
            libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 libsndio7.0 \
            libsdl2-2.0-0 fonts-liberation lsb-release xdg-utils libfreetype6 \
            libatspi2.0-0 libgcc-s1 libstdc++6 \
            poppler-utils poppler-data \
            ghostscript \
            fontconfig fonts-dejavu-core); \
    rm -rf /var/lib/apt/lists/*

# --- Legacy NVENC soname shims (as in v1008) ----------------------------------
RUN set -eux; \
    ln -sf /usr/lib/x86_64-linux-gnu/libsndio.so.7.0 /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 || true; \
    ln -sf /usr/lib/x86_64-linux-gnu/libva.so.2        /usr/lib/x86_64-linux-gnu/libva.so.1        || true; \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-drm.so.2    /usr/lib/x86_64-linux-gnu/libva-drm.so.1    || true; \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-x11.so.2    /usr/lib/x86_64-linux-gnu/libva-x11.so.1    || true; \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1 || true

# --- Strip NVIDIA GBM stubs (kept from v1008 to keep headless stable) ---------
RUN set -eux; \
    rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm* || true

# --- Create runtime user matching the UID/GID you run with (999:999) ----------
RUN set -eux; \
    groupadd -g 999 node; \
    useradd  -r -g 999 -G video -u 999 -m -d "$HOME" -s /bin/bash node; \
    mkdir -p "$HOME/.n8n" "$HOME/.cache" "$HOME/.config" && chown -R 999:999 "$HOME"

# --- Bring FFmpeg binaries/libs from stage 1 -----------------------------------
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg /usr/local/lib/*.so.*  /usr/local/lib/
RUN ldconfig

# --- Node 20 + global JS deps (versions unchanged where relevant) -------------
# IMPORTANT: use puppeteer-core (+ stealth) because executable is the sidecar
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; \
    apt-get update -o Acquire::Retries=5; \
    apt-get install -y --no-install-recommends nodejs || \
      (apt-get update -o Acquire::Retries=5 && apt-get install -y --no-install-recommends --fix-missing nodejs); \
    npm install -g --unsafe-perm \
      n8n@1.104.2 \
      puppeteer-core@24.15.0 \
      puppeteer-extra@3.3.6 \
      puppeteer-extra-plugin-stealth@2.11.2 \
      n8n-nodes-puppeteer@1.4.1; \
    npm cache clean --force; \
    mkdir -p /home/node/.npm && chown -R 999:999 /home/node/.npm; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# --- Python ML stack (Torch CUDA 12.1 wheels + Whisper + pyannote) ------------
RUN set -eux; \
    python3.10 -m pip install --upgrade pip; \
    python3.10 -m pip install --no-cache-dir "numpy<2"; \
    python3.10 -m pip install --no-cache-dir \
      torch==2.3.1+cu121 \
      torchvision==0.18.1+cu121 \
      torchaudio==2.3.1+cu121 \
      --index-url https://download.pytorch.org/whl/cu121; \
    python3.10 -m pip install --no-cache-dir \
      numba==0.61.2 \
      tiktoken==0.9.0 \
      git+https://github.com/openai/whisper.git@v20250625 \
      pyannote.audio==2.1.1 \
      "soundfile>=0.10.2,<0.11" \
      transformers==4.41.2 \
      librosa==0.9.2 \
      scikit-learn==1.4.2 \
      pandas==2.2.2 \
      noisereduce==3.0.3

# --- Whisper patch (kept): larger segment duration to reduce churn ------------
RUN set -eux; \
    sed -i 's/segment_duration = 30\.0/segment_duration = 180.0/' \
      /usr/local/lib/python3.10/dist-packages/whisper/transcribe.py || true

# --- Pre-download Whisper medium.en to your model cache (unchanged behavior) --
RUN set -eux; \
    mkdir -p "$WHISPER_MODEL_PATH"; \
    python3.10 - <<'PY'
import os, whisper
whisper._download(whisper._MODELS['medium.en'], os.environ['WHISPER_MODEL_PATH'], in_memory=False)
PY
RUN ln -s "$WHISPER_MODEL_PATH" /home/node/.cache/whisper && chown -h 999:999 /home/node/.cache/whisper

# --- Sanity: ensure CUDA hwaccels visible to FFmpeg (unchanged) ---------------
RUN set -eux; ffmpeg -hide_banner -hwaccels | grep -q cuda

# --- Optional tiny wrapper (kept simple; PATH already set) --------------------
RUN printf '%s\n' '#!/bin/sh' 'exec "$@"' > /usr/local/bin/n8n-wrapper && chmod +x /usr/local/bin/n8n-wrapper

# --- Health & entrypoint (unchanged behavior) ---------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl --fail http://localhost:5678/healthz || exit 1

USER 999:999
WORKDIR /home/node
EXPOSE 5678
ENTRYPOINT ["tini","--","/usr/local/bin/n8n-wrapper","n8n"]
CMD ["start"]
