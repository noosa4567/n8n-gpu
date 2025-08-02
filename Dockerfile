# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 ─ pull a proven, GPU-accelerated FFmpeg (dynamic, CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 ─ runtime: CUDA 11.8 – n8n + Chrome + Torch/Whisper (small)
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG  DEBIAN_FRONTEND=noninteractive
ENV  HOME=/home/node \
     WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
     PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
     PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
     LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
     TZ=Australia/Brisbane \
     PIP_ROOT_USER_ACTION=ignore \
     PATH=/usr/local/bin:$PATH \
     NVIDIA_VISIBLE_DEVICES=all \
     NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

# ── 1) base libs + Chrome
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      software-properties-common ca-certificates curl git wget gnupg tini \
      python3.10 python3.10-venv python3.10-dev python3-pip \
      libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 \
      libatk-bridge2.0-0 libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 \
      libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 libva2 \
      libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 libxcb-shape0 \
      libxcb-shm0 libxcb-xfixes0 libxcb-render0 libxrender1 libxtst6 \
      libxi6 libxcursor1 libcairo2 libcups2 libdbus-1-3 libexpat1 \
      libfontconfig1 libegl1-mesa libgl1-mesa-dri libpangocairo-1.0-0 \
      libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
      fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 \
      libgcc1 libstdc++6 libnvidia-egl-gbm1 libsndio7.0 libxv1 libsdl2-2.0-0 && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# ── 2) legacy NVENC sonames
RUN ln -sf /usr/lib/x86_64-linux-gnu/libsndio.so.7.0   /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva.so.2        /usr/lib/x86_64-linux-gnu/libva.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-drm.so.2    /usr/lib/x86_64-linux-gnu/libva-drm.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-x11.so.2    /usr/lib/x86_64-linux-gnu/libva-x11.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

# ── 3) strip NVIDIA GBM stubs
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# ── 4) non-root user
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$HOME"

# ── 5) dynamic FFmpeg from Stage 1
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffprobe

# ── 6) Node 20 + n8n + Puppeteer
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g --unsafe-perm \
      n8n@1.104.2 \
      puppeteer@24.15.0 \
      n8n-nodes-puppeteer@1.4.1 && \
    npm cache clean --force && \
    chown -R node:node /home/node/.npm && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ── 7) Puppeteer + sandbox
USER node
RUN npx puppeteer@24.15.0 browsers install chrome
USER root
RUN cp "$PUPPETEER_CACHE_DIR"/chrome/linux-*/chrome-linux*/chrome_sandbox /usr/local/sbin/chrome-devel-sandbox && \
    chown root:root /usr/local/sbin/chrome-devel-sandbox && \
    chmod 4755      /usr/local/sbin/chrome-devel-sandbox
ENV CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox

# ── 8) Torch/cu118 + Whisper
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install --no-cache-dir \
      torch==2.3.1+cu118 \
      torchvision==0.18.1+cu118 \
      torchaudio==2.3.1+cu118 \
      --index-url https://download.pytorch.org/whl/cu118 && \
    python3.10 -m pip install --no-cache-dir \
      numba==0.61.2 \
      tiktoken==0.9.0 \
      git+https://github.com/openai/whisper.git@v20250625

# ── 9) pre-download Whisper small (no heredoc)
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    python3.10 -c "import os, whisper, torch, shutil; \
root=os.environ['WHISPER_MODEL_PATH']; \
model=whisper.load_model('small', device='cpu'); \
torch.save(model.state_dict(), os.path.join(root,'small.pt')); \
shutil.copy(os.path.join(root,'small.pt'), os.path.join(root,'small.pt.bak'))"

# ── 9b) default cache symlink
RUN mkdir -p /home/node/.cache && \
    ln -s /usr/local/lib/whisper_models /home/node/.cache/whisper && \
    chown -h node:node /home/node/.cache/whisper

# ── 10) FFmpeg CUDA sanity check
RUN ffmpeg -hide_banner -hwaccels | grep -q cuda

# ── 11) PATH shim
RUN printf '%s\n' '#!/bin/sh' 'export PATH=/usr/local/bin:$PATH' 'exec "$@"' \
    > /usr/local/bin/n8n-wrapper && chmod +x /usr/local/bin/n8n-wrapper

# ── 12) health-check & entrypoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR "$HOME"
EXPOSE 5678
ENTRYPOINT ["tini","--","/usr/local/bin/n8n-wrapper","n8n"]
CMD ["start"]
