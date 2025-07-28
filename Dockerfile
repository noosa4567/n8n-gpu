###############################################
# Stage 1: Build FFmpeg with GPU acceleration
###############################################
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Install required dependencies for building FFmpeg (exclude libass)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential yasm cmake libtool libc6-dev pkg-config git wget \
    libnuma-dev libvorbis-dev libopus-dev libmp3lame-dev \
    libx264-dev libx265-dev libvpx-dev libfdk-aac-dev \
    libva-dev libdrm-dev && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install NVIDIA codec headers
RUN git clone --depth 1 --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && make && make install && cd .. && rm -rf nv-codec-headers

# Build FFmpeg with GPU acceleration and required codecs
RUN git clone --depth 1 --branch n7.1 https://git.ffmpeg.org/ffmpeg.git && \
    cd ffmpeg && \
    ./configure \
      --prefix=/usr/local \
      --pkg-config-flags="--static" \
      --extra-cflags="-I/usr/local/cuda/include" \
      --extra-ldflags="-L/usr/local/cuda/lib64" \
      --enable-cuda --enable-cuvid --enable-nvenc \
      --enable-nonfree --enable-gpl --enable-shared \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libx264 --enable-libx265 --enable-libfdk-aac --enable-libvpx && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf ffmpeg

# Copy all runtime libraries FFmpeg depends on
RUN mkdir -p /ffmpeg-libs && \
    ldd /usr/local/bin/ffmpeg | awk '{print $3}' | grep -E '/usr/lib|/lib' | xargs -I{} cp -v --parents {} /ffmpeg-libs || true


###############################################
# Stage 2: Runtime with Whisper, Puppeteer, n8n
###############################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    TORCH_HOME=/opt/torch_cache \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    NODE_PATH=/usr/local/lib/node_modules \
    CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox

# Create node user
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node

# Copy FFmpeg binary and dependencies
COPY --from=builder /usr/local /usr/local
COPY --from=builder /ffmpeg-libs / 
RUN ldconfig

# Install Puppeteer and Mesa graphics dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini git curl ca-certificates gnupg wget xz-utils python3 python3-pip binutils \
    libglib2.0-0 libnss3 libatk-bridge2.0-0 libgtk-3-0 libx11-xcb1 libxcb1 libxcomposite1 \
    libxdamage1 libxrandr2 libgbm1 libasound2 libxshmfence1 libxext6 libxfixes3 libxrender1 \
    libxtst6 libegl1 libx11-6 libdrm2 libudev1 libfontconfig1 libharfbuzz0b \
    libfreetype6 libvpx-dev libfdk-aac-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

# Fix NVIDIA GBM conflict with Puppeteer
RUN rm -rf /usr/local/nvidia/lib*/*gbm* /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# Manual fix for libsndio
RUN wget -qO /tmp/libsndio6.1.deb http://security.ubuntu.com/ubuntu/pool/universe/s/sndio/libsndio6.1_1.1.0-3_amd64.deb && \
    dpkg -i /tmp/libsndio6.1.deb && rm /tmp/libsndio6.1.deb

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

# Install Whisper and Torch (CUDA 11.8)
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.7.1+cu118 numpy==1.26.3 && \
    pip3 install --no-cache-dir openai-whisper==20250625 tiktoken && \
    mkdir -p "$WHISPER_MODEL_PATH" && \
    chown -R node:node "$WHISPER_MODEL_PATH" && \
    python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" && \
    rm -rf /root/.cache/pip/* /tmp/*

# Install n8n and Puppeteer
RUN npm install -g --unsafe-perm \
    n8n@1.103.2 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 ajv@8.17.1 --legacy-peer-deps && \
    npm cache clean --force && \
    mkdir -p "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$PUPPETEER_CACHE_DIR" "$(npm root -g)" && \
    cp "$PUPPETEER_CACHE_DIR/chrome/linux-*/chrome-linux64/chrome_sandbox" "$CHROME_DEVEL_SANDBOX" && \
    chown root:root "$CHROME_DEVEL_SANDBOX" && chmod 4755 "$CHROME_DEVEL_SANDBOX"

# Setup shared working directories
RUN mkdir -p "$HOME/.cache/n8n/public" /data/shared/{videos,audio,transcripts} && \
    chown -R node:node "$HOME" /data/shared && chmod -R 770 /data/shared "$HOME/.cache"

# Final validation of FFmpeg GPU
RUN ffmpeg -hide_banner -hwaccels | grep -q "cuda" && echo "✅ FFmpeg GPU OK" || (echo "❌ FFmpeg GPU check failed" >&2 && exit 1)

USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini", "--", "n8n", "start"]
CMD []
