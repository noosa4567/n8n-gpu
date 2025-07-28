# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 • Build FFmpeg from source with CUDA/NVENC, no subtitle libs
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/usr/local/cuda/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git pkg-config yasm cmake libtool nasm \
    libnuma-dev libx264-dev libx265-dev libfdk-aac-dev libmp3lame-dev \
    libopus-dev libvorbis-dev libvpx-dev libpostproc-dev curl && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && make -j"$(nproc)" && make install

RUN git clone --depth 1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git ffmpeg && \
    cd ffmpeg && ./configure \
      --prefix=/usr/local \
      --pkg-config-flags="--static" \
      --extra-cflags="-I/usr/local/cuda/include" \
      --extra-ldflags="-L/usr/local/cuda/lib64" \
      --extra-libs="-lpthread -lm" \
      --enable-cuda --enable-cuvid --enable-nvenc \
      --enable-nonfree --enable-gpl --enable-shared --enable-postproc \
      --enable-libx264 --enable-libx265 --enable-libfdk-aac --enable-libvpx \
      --enable-libopus --enable-libmp3lame --enable-libvorbis && \
    make -j"$(nproc)" && make install


###############################################################################
# Stage 2 • Runtime: CUDA 11.8 + Whisper + Puppeteer + FFmpeg + n8n
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64

# Install OS and Puppeteer runtime deps (Chrome, no subtitle libs)
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common curl gnupg git wget tini python3.10 python3.10-venv python3.10-dev python3-pip \
    ca-certificates libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libgtk-3-0 \
    libdrm2 libxkbcommon0 libgbm1 libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 \
    libva2 libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 \
    libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 libxrender1 libxtst6 \
    libxi6 libxcursor1 libcairo2 libcups2 libdbus-1-3 libexpat1 \
    libfontconfig1 libegl1-mesa libgl1-mesa-dri libatspi2.0-0 libfreetype6 \
    fonts-liberation lsb-release xdg-utils libstdc++6 libgcc1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Remove NVIDIA GBM extensions (conflict with Puppeteer)
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib/*gbm* \
           /usr/local/nvidia/lib64/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# Create node user (UID 999), add to video group, setup home
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" /data/shared && \
    chown -R node:node "$HOME" /data/shared

# Install runtime FFmpeg dependencies only (no subtitle support)
RUN add-apt-repository universe && add-apt-repository multiverse && apt-get update && \
    apt-get install -y --no-install-recommends \
    libvpx7 libx264-163 libx265-199 libfdk-aac2 libmp3lame0 libopus0 libvorbis0a libvorbisenc2 libpostproc55 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy GPU-enabled FFmpeg
COPY --from=ffmpeg-builder /usr/local /usr/local

# Install Node.js, n8n, Puppeteer and Puppeteer Community Node
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g --unsafe-perm n8n@1.104.1 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 && \
    npm cache clean --force && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Whisper + Torch (CUDA)
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 && \
    python3.10 -m pip install git+https://github.com/openai/whisper.git && \
    pip cache purge

# Pre-load Whisper tiny model
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    python3.10 -c "import whisper; whisper.load_model('tiny', download_root='$WHISPER_MODEL_PATH')"

# Healthcheck and validation
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini", "--", "n8n"]
CMD []
