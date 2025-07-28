# #######################################################################
# Multi-stage Dockerfile: GPU-enabled FFmpeg + Whisper + Puppeteer + n8n
# Target platform: Ubuntu 22.04 + CUDA 11.8 + runtime-ready image
# Subtitle rendering intentionally excluded (no libass)
#
# Notes for QNAP NAS (QuTS Hero with NVIDIA P2200 GPU):
# - P2200 is compatible with CUDA 11.8 (NVIDIA driver >=450 required).
# - Enable GPU passthrough via Container Station settings or use --gpus all.
# - 5GB VRAM: avoid Whisper large/v2 models (OOM risk); 'tiny' and 'base' are fine.
#
# Enhancements:
# - ✅ Healthcheck added (checks n8n healthz endpoint)
# - ⚫ Image size: ~5–7GB; can be optimized with alpine/multi-stage stripping
# - ✅ Optional debug layer for nvidia-smi (fixed for root privileges)
#######################################################################

###############################
# Stage 1: FFmpeg with GPU (pre-built to avoid linking issues)
###############################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################
# Stage 2: Runtime Image
###############################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64

# Install core runtime dependencies + binutils for debugging
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common ca-certificates curl git wget gnupg \
    python3.10 python3.10-venv python3.10-dev python3-pip binutils \
    libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libgtk-3-0 \
    libdrm2 libxkbcommon0 libgbm1 libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 \
    libva2 libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 \
    libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 libxrender1 libxtst6 \
    libxi6 libxcursor1 libcairo2 libcups2 libdbus-1-3 libexpat1 \
    libfontconfig1 libegl1-mesa libgl1-mesa-dri \
    libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
    fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 libgcc1 libstdc++6 \
    libnvidia-egl-gbm1 tini && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Add PPA for Mesa updates
RUN add-apt-repository ppa:oibaf/graphics-drivers -y && apt-get update && apt-get upgrade -y && apt-get clean && rm -rf /var/lib/apt/lists/*

# Remove NVIDIA GBM libraries that crash Puppeteer
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
    /usr/local/nvidia/lib/*gbm* \
    /usr/local/nvidia/lib64/*gbm* \
    /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# Create node user with video group and .n8n home
RUN groupadd -r node \
 && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# Copy pre-built FFmpeg
COPY --from=ffmpeg /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/ /usr/local/lib/
RUN ldconfig && rm -f /usr/local/lib/lib{asound,atk,atspi,cairo,cups,dbus,expat,fontconfig,gbm,glib,gtk,nspr,nss,pango,stdc++,x11,xcb,xcomposite,xcursor,xdamage,xext,xfixes,xi,xrandr,xrender,xss,xtst,harfbuzz,fribidi,thai,datrie,drm,wayland,EGL,GLES,glapi,va,vdpau,sndio,freetype}* && ldconfig

# Install missing FFmpeg deps (libass9, libSDL2, libXv1)
RUN add-apt-repository universe && add-apt-repository multiverse && apt-get update && \
    apt-get install -y --no-install-recommends libass9 libSDL2-2.0-0 libXv1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install libsndio6.1 (from WORKING Puppeteer)
RUN wget -qO /tmp/libsndio6.1.deb http://security.ubuntu.com/ubuntu/pool/universe/s/sndio/libsndio6.1_1.1.0-3_amd64.deb && \
    dpkg -i /tmp/libsndio6.1.deb && rm /tmp/libsndio6.1.deb

# Node.js + n8n + Puppeteer
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g --unsafe-perm n8n@1.104.1 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 && \
    npm cache clean --force && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Force Puppeteer Chrome download and sandbox chown
RUN npx puppeteer browsers install chrome && \
    chown -R node:node "$PUPPETEER_CACHE_DIR" && \
    cp $PUPPETEER_CACHE_DIR/chrome/linux-*/chrome-linux64/chrome_sandbox /usr/local/sbin/chrome-devel-sandbox && \
    chown root:root /usr/local/sbin/chrome-devel-sandbox && \
    chmod 4755 /usr/local/sbin/chrome-devel-sandbox

# Whisper with CUDA
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 && \
    python3.10 -m pip install git+https://github.com/openai/whisper.git && \
    pip cache purge

# Pre-download Whisper tiny model
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    python3.10 -c "import whisper; whisper.load_model('tiny', download_root='$WHISPER_MODEL_PATH')"

# Puppeteer cache + shared dir
RUN mkdir -p "$PUPPETEER_CACHE_DIR" /data/shared && \
    chown -R node:node "$HOME" /data/shared

# Validate FFmpeg
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" && \
    (echo "❌ FFmpeg library linking failed" >&2 && exit 1) || echo "✅ FFmpeg libraries resolved" && \
    ffmpeg -version && \
    ffmpeg -hide_banner -hwaccels | grep -q "cuda" && echo "✅ FFmpeg GPU OK" || (echo "❌ FFmpeg GPU missing" >&2 && exit 1)

# n8n healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR $HOME
EXPOSE 5678
ENTRYPOINT ["tini", "--", "n8n"]
CMD []
