# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 ─ pull a proven, GPU-accelerated FFmpeg (dynamic, CUDA 12.0)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 ─ runtime: CUDA 12.1-devel – n8n + Chrome + Torch/Whisper (medium)
###############################################################################
FROM nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    TZ=Australia/Brisbane \
    PIP_ROOT_USER_ACTION=ignore \
    PATH=/usr/local/bin:$PATH \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

# ── 1) Base OS libs + Google Chrome
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
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" \
         > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# ── 2) Legacy NVENC soname symlinks
RUN ln -sf /usr/lib/x86_64-linux-gnu/libsndio.so.7.0   /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva.so.2        /usr/lib/x86_64-linux-gnu/libva.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-drm.so.2    /usr/lib/x86_64-linux-gnu/libva-drm.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-x11.so.2    /usr/lib/x86_64-linux-gnu/libva-x11.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

# ── 3) Strip NVIDIA GBM stubs (fixes headless Chrome <115)
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# ── 4) Create non-root “node” user
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$HOME"

# ── 5) Copy FFmpeg binary + shared libs, then ldconfig
COPY --from=ffmpeg /usr/local/bin/ffmpeg       /usr/local/bin/ffmpeg
COPY --from=ffmpeg /usr/local/bin/ffprobe      /usr/local/bin/ffprobe
COPY --from=ffmpeg /usr/local/lib/*.so.*       /usr/local/lib/
RUN ldconfig

# ── 6) Install Node 20, n8n & Puppeteer globally
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

# ── Make global modules available to `require()`
ENV NODE_PATH=/usr/local/lib/node_modules

# ── 7) Puppeteer’s Chromium + restore sandbox
USER node
RUN npx puppeteer@24.15.0 browsers install chrome
USER root
RUN cp "$PUPPETEER_CACHE_DIR"/chrome/linux-*/chrome-linux*/chrome_sandbox \
        /usr/local/sbin/chrome-devel-sandbox && \
    chown root:root /usr/local/sbin/chrome-devel-sandbox && \
    chmod 4755      /usr/local/sbin/chrome-devel-sandbox
ENV CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox

# ── 8) Chrome “warm-up” to prime the first-run profile
USER node
RUN node -e "const p=require('puppeteer');(async()=>{const b=await p.launch({headless:true});const pg=await b.newPage();await pg.goto('about:blank',{timeout:60000});await b.close();})();"

# ── 9) Install Torch/CUDA wheels + Whisper
USER root
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install --no-cache-dir \
      torch==2.3.1+cu121 \
      torchvision==0.18.1+cu121 \
      torchaudio==2.3.1+cu121 \
      --index-url https://download.pytorch.org/whl/cu121 && \
    python3.10 -m pip install --no-cache-dir \
      numba==0.61.2 \
      tiktoken==0.9.0 \
      git+https://github.com/openai/whisper.git@v20250625

# ── 10) Pre-download Whisper medium (FP16, GPU-optimized)
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    python3.10 -c "\
import os, torch, hashlib, json, whisper; \
out=os.environ['WHISPER_MODEL_PATH']; \
m=whisper.load_model('medium', device='cuda').half(); \
pt=os.path.join(out,'medium.pt'); \
torch.save(m.state_dict(),pt); \
h=hashlib.sha256(open(pt,'rb').read()).hexdigest()[:20]; \
json.dump({'sha256':h},open(pt+'.json','w'));"

# ── 11) Cache symlink for Whisper
RUN mkdir -p /home/node/.cache && \
    ln -s /usr/local/lib/whisper_models /home/node/.cache/whisper && \
    chown -h node:node /home/node/.cache/whisper

# ── 12) Sanity-check CUDA hwaccels
RUN ffmpeg -hide_banner -hwaccels | grep -q cuda

# ── 13) PATH-shim so /usr/local/bin comes first
RUN printf '%s\n' \
      '#!/bin/sh' \
      'export PATH=/usr/local/bin:$PATH' \
      'exec "$@"' \
    > /usr/local/bin/n8n-wrapper && chmod +x /usr/local/bin/n8n-wrapper

# ── 14) Health-check & final entrypoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR "$HOME"
EXPOSE 5678
ENTRYPOINT ["tini","--","/usr/local/bin/n8n-wrapper","n8n"]
CMD ["start"]
