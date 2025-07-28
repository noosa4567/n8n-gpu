# syntax=docker/dockerfile:1

###############################################################################
# Stage 1: Builder — Build FFmpeg with GPU support but no subtitle support
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS builder

# Install dependencies for compiling FFmpeg with required codecs
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git pkg-config cmake \
    yasm nasm libtool autoconf automake \
    libx264-dev libx265-dev libfdk-aac-dev libvpx-dev libopus-dev libmp3lame-dev \
    zlib1g-dev libnuma-dev && \
    rm -rf /var/lib/apt/lists/*

# Build FFmpeg with GPU support, no subtitle rendering (no libass)
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
      --enable-libx264 --enable-libx265 --enable-libfdk-aac --enable-libvpx \
      --enable-libopus --enable-libmp3lame && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf ffmpeg

# Collect only FFmpeg shared lib dependencies
RUN mkdir -p /ffmpeg-libs && \
    ldd /usr/local/bin/ffmpeg | awk '{print $3}' | grep -E '^/lib|^/usr/lib' | xargs -I{} cp -v --parents {} /ffmpeg-libs || true

###############################################################################
# Stage 2: Runtime — Minimal base image with GPU FFmpeg + Puppeteer + n8n + Whisper
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

# Set environment variables
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git wget jq unzip sudo \
    libxext6 libx11-xcb1 libxcb1 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libgbm1 libnss3 libasound2 libatk-bridge2.0-0 libcups2 \
    libdrm2 libgtk-3-0 libxss1 libxshmfence1 xdg-utils \
    nodejs npm python3-pip && \
    rm -rf /var/lib/apt/lists/*

# Add node user for n8n and Puppeteer
RUN useradd -m node && mkdir -p /data && chown -R node:node /data

# Install FFmpeg runtime files
COPY --from=builder /usr/local /usr/local
COPY --from=builder /ffmpeg-libs /

RUN ldconfig

# Optional sanity check — ensure FFmpeg is GPU-enabled and linked
RUN ldd /usr/local/bin/ffmpeg | grep "not found" && (echo "❌ FFmpeg libs missing" && exit 1) || \
    (ffmpeg -hide_banner -hwaccels | grep -q "cuda" && echo "✅ FFmpeg GPU OK") || \
    (echo "❌ FFmpeg GPU not detected" && exit 1)

# Install n8n
RUN npm install -g n8n

# Install Puppeteer in a way that avoids NVIDIA GBM
USER node
RUN mkdir -p "${PUPPETEER_CACHE_DIR}" && \
    npm install puppeteer && \
    node -e "console.log(require('puppeteer').executablePath())"

# Install Whisper with GPU
USER root
RUN pip3 install torch --index-url https://download.pytorch.org/whl/cu118 && \
    pip3 install git+https://github.com/openai/whisper.git

# Create data and cache directories
RUN mkdir -p "${HOME}/.cache/n8n/public" /data/shared/{videos,audio,transcripts} && \
    chown -R node:node "${HOME}" /data/shared && chmod -R 770 /data/shared "${HOME}/.cache"

USER node
WORKDIR /data

# ENTRYPOINT & CMD — Preserve original intent
ENTRYPOINT ["n8n"]
CMD ["start"]
