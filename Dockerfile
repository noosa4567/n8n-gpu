# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 — pull a proven, GPU-accelerated FFmpeg (dynamic, CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 — runtime: CUDA 12.1-devel → n8n + Chrome + Puppeteer + Torch/Whisper
###############################################################################
FROM nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    PATH=/usr/local/bin:/usr/local/sbin:$PATH \
    NODE_PATH=/usr/local/lib/node_modules \
    TZ=Australia/Brisbane \
    PIP_ROOT_USER_ACTION=ignore \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

###############################################################################
# 1) Base OS libs + Google Chrome
###############################################################################
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git wget gnupg software-properties-common tini \
      python3.10 python3.10-venv python3.10-dev python3-pip \
      libglib2.0-0 libnss3 libx11-xcb1 libxss1 libasound2 \
      libatk1.0-0 libatk-bridge2.0-0 libcairo2 libcups2 libdbus-1-3 \
      libdrm2 libexpat1 libfontconfig1 libfreetype6 libgbm1 libgcc1 \
      libgtk-3-0 libharfbuzz0b libpango-1.0-0 libthai0 \
      libxi6 libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 \
      libxkbcommon0 libxrandr2 libxrender1 libxshmfence1 libxtst6 \
      libxv1 libsndio7.0 libvdpau1 libva2 libva-drm2 libva-x11-2 libva-wayland2 \
      libxcb1 libxcb-render0 libxcb-shm0 libxcb-shape0 libxcb-xfixes0 \
      libsdl2-2.0-0 fonts-liberation lsb-release xdg-utils && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

###############################################################################
# 2) Legacy NVENC soname symlinks
###############################################################################
RUN ln -sf /usr/lib/x86_64-linux-gnu/libsndio.so.7.0   /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva.so.2        /usr/lib/x86_64-linux-gnu/libva.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-drm.so.2    /usr/lib/x86_64-linux-gnu/libva-drm.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-x11.so.2    /usr/lib/x86_64-linux-gnu/libva-x11.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

###############################################################################
# 3) Strip NVIDIA GBM stubs (fix headless Chrome <115)
###############################################################################
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

###############################################################################
# 4) Create non-root “node” user
###############################################################################
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$PUPPETEER_CACHE_DIR" /usr/local/lib/whisper_models && \
    chown -R node:node "$HOME" "$PUPPETEER_CACHE_DIR" /usr/local/lib/whisper_models

###############################################################################
# 5) Copy FFmpeg + its shared libs, then ldconfig
###############################################################################
COPY --from=ffmpeg /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg /usr/local/lib/*.so.*    /usr/local/lib/
RUN ldconfig

###############################################################################
# 6) Install Node 20, n8n & Puppeteer globally
###############################################################################
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g --unsafe-perm \
      n8n@1.104.2 \
      puppeteer@24.15.0 \
      n8n-nodes-puppeteer@1.4.1 && \
    npm cache clean --force && \
    chown -R node:node /home/node/.npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

###############################################################################
# 7) Puppeteer’s Chromium + restore sandbox
###############################################################################
USER node
RUN npx puppeteer@24.15.0 browsers install chrome
USER root
RUN cp "$PUPPETEER_CACHE_DIR"/chrome/linux-*/chrome-linux*/chrome_sandbox \
        /usr/local/sbin/chrome-devel-sandbox && \
    chown root:root /usr/local/sbin/chrome-devel-sandbox && \
    chmod 4755 /usr/local/sbin/chrome-devel-sandbox
ENV CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox

###############################################################################
# 8) Chrome warm-up as root (NODE_PATH in effect)
###############################################################################
RUN node -e 'const p=require("/usr/local/lib/node_modules/puppeteer");(async()=>{\
const b=await p.launch({headless:true,args:["--no-sandbox","--disable-setuid-sandbox"]});\
const pg=await b.newPage();await pg.goto("about:blank",{timeout:60000});\
await b.close();})()'

###############################################################################
# 9) Install Torch/CUDA wheels + Whisper
###############################################################################
USER root
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install --no-cache-dir \
      torch==2.3.1+cu121 torchvision==0.18.1+cu121 torchaudio==2.3.1+cu121 \
      --index-url https://download.pytorch.org/whl/cu121 && \
    python3.10 -m pip install --no-cache-dir \
      numba==0.61.2 tiktoken==0.9.0 \
      git+https://github.com/openai/whisper.git@v20250625

###############################################################################
# 10) Pre-download Whisper medium (FP16, CPU-mode)
###############################################################################
RUN python3.10 -c 'import os, torch, hashlib, json, whisper; \
m=whisper.load_model("medium",device="cpu").half(); \
out=os.environ["WHISPER_MODEL_PATH"]; \
pt=os.path.join(out,"medium.pt"); \
torch.save(m.state_dict(),pt); \
json.dump({"sha256":hashlib.sha256(open(pt,"rb").read()).hexdigest()[:20]},\
open(pt+".json","w"))'

###############################################################################
# 11) Whisper cache symlink for node
###############################################################################
RUN mkdir -p "$HOME/.cache" && \
    ln -sf /usr/local/lib/whisper_models "$HOME/.cache/whisper" && \
    chown -h node:node "$HOME/.cache/whisper"

###############################################################################
# 12) Sanity-check: CUDA hwaccels visible to FFmpeg
###############################################################################
RUN ffmpeg -hide_banner -hwaccels | grep -q cuda

###############################################################################
# 13) Tiny PATH-shim so /usr/local/bin comes first
###############################################################################
RUN printf '%s\n' '#!/bin/sh' 'export PATH=/usr/local/bin:$PATH' 'exec "$@"' \
  > /usr/local/bin/n8n-wrapper && chmod +x /usr/local/bin/n8n-wrapper

###############################################################################
# 14) Health-check & final ENTRYPOINT
###############################################################################
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR "$HOME"
EXPOSE 5678
ENTRYPOINT ["tini","--","/usr/local/bin/n8n-wrapper","n8n"]
CMD ["start"]
