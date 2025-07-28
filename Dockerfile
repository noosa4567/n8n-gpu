# syntax=docker/dockerfile:1

###############################################################################
# Stage 1: Build FFmpeg with CUDA/NVENC (No libass)
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Install build dependencies for FFmpeg (excluding libass)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential yasm cmake libtool libc6-dev pkg-config git wget curl \
    libvorbis-dev libopus-dev libmp3lame-dev libx264-dev libx265-dev \
    libvpx-dev libfdk-aac-dev && \
    rm -rf /var/lib/apt/lists/*

# Install NVIDIA codec headers for NVENC/NVDEC support
RUN git clone --depth 1 --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && make && make install && cd .. && rm -rf nv-codec-headers

# Build FFmpeg (excluding subtitle rendering)
RUN git clone --depth 1 --branch n7.1 https://git.ffmpeg.org/ffmpeg.git && \
    cd ffmpeg && \
    ./configure \
      --prefix=/usr/local \
      --pkg-config-flags="--static" \
      --extra-cflags="-I/usr/local/cuda/include" \
      --extra-ldflags="-L/usr/local/cuda/lib64" \
      --extra-libs="-lpthread -lm" \
      --enable-cuda --enable-cuvid --enable-nvenc \
      --enable-nonfree --enable-gpl --enable-shared --enable-postproc \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libx264 --enable-libx265 --enable-libfdk-aac --enable-libvpx && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf ffmpeg

# Collect shared libs for runtime
RUN mkdir -p /ffmpeg-libs && \
    ldd /usr/local/bin/ffmpeg | awk '{print $3}' | grep -E '^/lib|^/usr/lib' | xargs -I{} cp --parents {} /ffmpeg-libs || true

###############################################################################
# Stage 2: Runtime Image with FFmpeg, Puppeteer, Whisper, n8n
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    TORCH_HOME=/opt/torch_cache \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/lib/x86_64-linux-gnu \
    NODE_PATH=/usr/local/lib/node_modules \
    CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox

# Create non-root node user and working directory
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" && chown -R node:node "$HOME"

# Copy FFmpeg binaries and required shared libs
COPY --from=builder /usr/local /usr/local
COPY --from=builder /ffmpeg-libs/lib /lib
COPY --from=builder /ffmpeg-libs/usr/lib /usr/lib
RUN ldconfig

# Install Puppeteer and GUI/Chromium dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini git curl ca-certificates gnupg wget xz-utils python3 python3-pip binutils \
    libglib2.0-0 libnss3 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 \
    libxss1 libxtst6 libgtk-3-0 libatk-bridge2.0-0 libatk1.0-0 libcups2 \
    libdrm2 libgbm1 libasound2 libxshmfence1 libx11-6 libxext6 \
    libxfixes3 libxrender1 libxcb1 libxcursor1 libxinerama1 libxv1 \
    libfreetype6 libfontconfig1 libdbus-1-3 libexpat1 libharfbuzz0b \
    libpango-1.0-0 libpangocairo-1.0-0 libthai0 libdatrie1 libsndio6.1 \
    fonts-liberation xdg-utils libnvidia-egl-gbm1 && \
    rm -rf /var/lib/apt/lists/*

# Remove NVIDIA's conflicting GBM libraries
RUN rm -f /usr/local/nvidia/lib*/*gbm* /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Whisper with GPU support
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.7.1+cu118 numpy==1.26.3 && \
    pip3 install --no-cache-dir tiktoken openai-whisper==20250625 && \
    mkdir -p "$WHISPER_MODEL_PATH" && \
    chown -R node:node "$WHISPER_MODEL_PATH" && \
    python3 -c "import whisper; whisper.load_model('base', download_root='$WHISPER_MODEL_PATH')"

# Install Puppeteer and n8n
RUN npm install -g --unsafe-perm \
    puppeteer@24.15.0 \
    n8n@1.103.2 \
    n8n-nodes-puppeteer@1.4.1 \
    ajv@8.17.1 --legacy-peer-deps && \
    npm cache clean --force && \
    mkdir -p "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$PUPPETEER_CACHE_DIR" "$(npm root -g)" && \
    cp "$PUPPETEER_CACHE_DIR"/chrome/linux-*/chrome-linux64/chrome_sandbox "$CHROME_DEVEL_SANDBOX" && \
    chown root:root "$CHROME_DEVEL_SANDBOX" && chmod 4755 "$CHROME_DEVEL_SANDBOX"

# Setup directories and permissions
RUN mkdir -p "$HOME/.cache/n8n/public" /data/shared/{videos,audio,transcripts} && \
    chown -R node:node "$HOME" /data/shared && chmod -R 770 /data/shared "$HOME/.cache"

# Validate FFmpeg and GPU
RUN ldd /usr/local/bin/ffmpeg && \
    ffmpeg -hide_banner -hwaccels | grep -q cuda && echo "✅ FFmpeg GPU OK" || (echo "❌ GPU not detected" && exit 1)

# Set execution context
USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini", "--", "n8n", "start"]
CMD []
