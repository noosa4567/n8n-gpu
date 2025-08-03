# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 ─ pull a proven, GPU-accelerated FFmpeg (dynamic, CUDA 12.0)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 ─ runtime: CUDA 12.1-devel – n8n + Chrome + Torch/Whisper (medium.en)
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
    NODE_PATH=/usr/local/lib/node_modules \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

#── 1) Base OS libs + Google Chrome
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      software-properties-common ca-certificates curl git wget gnupg tini \
      python3.10 python3.10-venv python3.10-dev python3-pip \
      libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 \
      libatk-bridge2.0-0 libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 \
      libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 libva2 \
      libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 libsndio7.0 \
      libsdl2-2.0-0 fonts-liberation lsb-release xdg-utils libfreetype6 \
      libatspi2.0-0 libgcc1 libstdc++6 && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

#── 2) Legacy NVENC soname symlinks
RUN ln -sf /usr/lib/x86_64-linux-gnu/libsndio.so.7.0   /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva.so.2       /usr/lib/x86_64-linux-gnu/libva.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-drm.so.2   /usr/lib/x86_64-linux-gnu/libva-drm.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-x11.so.2   /usr/lib/x86_64-linux-gnu/libva-x11.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

#── 3) Strip NVIDIA GBM stubs (fixes headless Chrome <115)
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

#── 4) Create non-root “node” user
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$HOME"

#── 4b) Ensure Puppeteer’s config dir is writable by node
RUN mkdir -p /home/node/.config/puppeteer && \
    chown -R node:node /home/node/.config

#── 5) Copy FFmpeg + its libs, then update linker cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg /usr/local/lib/*.so.*    /usr/local/lib/
RUN ldconfig

#── 6) Install Node 20, n8n & Puppeteer globally
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g --unsafe-perm \
      n8n@1.104.2 \
      puppeteer@24.15.0 \
      n8n-nodes-puppeteer@1.4.1 && \
    npm cache clean --force && \
    mkdir -p /home/node/.npm && chown -R node:node /home/node/.npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

#── 7) Puppeteer’s Chromium + restore sandbox
USER node
RUN npx puppeteer@24.15.0 browsers install chrome

USER root
RUN cp "$PUPPETEER_CACHE_DIR"/chrome/linux-*/chrome-linux*/chrome_sandbox \
        /usr/local/sbin/chrome-devel-sandbox && \
    chown root:root      /usr/local/sbin/chrome-devel-sandbox && \
    chmod 4755           /usr/local/sbin/chrome-devel-sandbox
ENV CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox

#── 8) Chrome “warm-up” using dynamic path lookup of Puppeteer global install
RUN node -e "const { execSync } = require('child_process'); \
const path = require('path'); \
const npmRoot = execSync('npm root -g').toString().trim(); \
const puppeteer = require(path.join(npmRoot, 'puppeteer')); \
(async () => { \
  const browser = await puppeteer.launch({ \
    headless: true, \
    args: ['--no-sandbox','--disable-setuid-sandbox'] \
  }); \
  const page = await browser.newPage(); \
  await page.goto('about:blank', { timeout: 60000 }); \
  await browser.close(); \
})();"

#── 9) Install Torch/CUDA wheels + Whisper (as root)
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

#── 10) Pre-download official Whisper medium.en model using Whisper's internal downloader
RUN python3.10 -c "\
import whisper, os; \
whisper._download(whisper._MODELS['medium.en'], os.path.expanduser('~/.cache/whisper'), in_memory=False)"

#── 11) Symlink the entire Whisper cache to the node user
RUN mkdir -p /home/node/.cache && \
    ln -s /root/.cache/whisper /home/node/.cache/whisper && \
    chown -h node:node /home/node/.cache/whisper

#── 12) Sanity-check: CUDA hwaccels visible
RUN ffmpeg -hide_banner -hwaccels | grep -q cuda

#── 13) Tiny PATH-shim so /usr/local/bin comes first
RUN printf '%s\n' \
      '#!/bin/sh' \
      'export PATH=/usr/local/bin:$PATH' \
      'exec "$@"' \
    > /usr/local/bin/n8n-wrapper && chmod +x /usr/local/bin/n8n-wrapper

#── 14) Health-check & final entrypoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:5678/healthz || exit 1

# Drop to node for runtime
USER node
WORKDIR "$HOME"
EXPOSE 5678
ENTRYPOINT ["tini","--","/usr/local/bin/n8n-wrapper","n8n"]
CMD ["start"]
