# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 – build a static, CUDA-enabled FFmpeg
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/cuda/bin:$PATH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential git pkg-config yasm cmake libtool nasm curl \
      libnuma-dev libx264-dev libfdk-aac-dev libmp3lame-dev \
      libopus-dev libvorbis-dev libvpx-dev libpostproc-dev && \
    rm -rf /var/lib/apt/lists/*

# nv-codec headers
RUN git clone --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git && \
    make -C nv-codec-headers -j"$(nproc)" install && \
    rm -rf nv-codec-headers

# static FFmpeg + CUDA/NVENC (disable shared and all unneeded device libraries)
RUN git clone --depth 1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git ffmpeg && \
    cd ffmpeg && \
    . /configure \
      --prefix=/usr/local \
      --pkg-config-flags="--static" \
      --extra-cflags="-I/usr/local/cuda/include" \
      --extra-ldflags="-L/usr/local/cuda/lib64 -static" \
      --extra-libs="-lpthread -lm" \
      --enable-cuda --enable-cuvid --enable-nvenc \
      --enable-nonfree --enable-gpl --enable-postproc \
      --enable-libx264 --enable-libfdk-aac \
      --enable-libvpx --enable-libopus --enable-libmp3lame --enable-libvorbis \
      --enable-static --disable-shared \
      --disable-devices \
      --disable-opengl && \\
    make -j"$(nproc)" && \
    make install && \
    cd .. && rm -rf ffmpeg

###############################################################################
# Stage 2 – runtime: CUDA 11.8 + n8n + Whisper + Puppeteer
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu \
    TZ=Australia/Brisbane \
    PIP_ROOT_USER_ACTION=ignore

# 1. Base OS & libraries + SDL2 runtime + Chrome Stable
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
      libgcc1 libstdc++6 libnvidia-egl-gbm1 libSDL2-2.0-0 && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# Remove NVIDIA GBM stubs that crash Chrome
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# 2. Create non-root user
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$HOME"

# 3. Copy static FFmpeg
COPY --from=ffmpeg-builder /usr/local /usr/local

# 4. Node.js & n8n + Puppeteer (root), fix npm cache
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    HOME=/root npm install -g --unsafe-perm \
      n8n@1.104.1 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 && \
    npm cache clean --force && \
    chown -R node:node /home/node/.npm || true && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 5. Whisper + Torch (GPU)
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 && \
    python3.10 -m pip install --no-cache-dir git+https://github.com/openai/whisper.git

# 6. Pre-download Whisper model (no heredoc)
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    python3.10 -c "import whisper, os; whisper.load_model('tiny', download_root=os.environ['WHISPER_MODEL_PATH'])"

# 7. FFmpeg sanity check
RUN ffmpeg -version && \
    ffmpeg -hide_banner -hwaccels | grep -q "cuda" && \
    echo "✅  static FFmpeg with CUDA acceleration ready"

# 8. Healthcheck & launch
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR $HOME
EXPOSE 5678
ENTRYPOINT ["tini", "--", "n8n"]
CMD []
