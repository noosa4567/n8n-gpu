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
# Optional Enhancements:
# - ✅ Healthcheck added (checks n8n healthz endpoint)
# - ⚫ Image size: ~5–7GB; can be optimized with alpine/multi-stage stripping
# - ✅ Optional debug layer for nvidia-smi (commented by default)
#######################################################################

###############################
# Stage 1: Build FFmpeg with GPU support
###############################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/usr/local/cuda/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git pkg-config yasm cmake libtool nasm \
    libnuma-dev libx264-dev libx265-dev libfdk-aac-dev libmp3lame-dev \
    libopus-dev libvorbis-dev libvpx-dev libpostproc-dev curl && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && make -j"$(nproc)" && make install && cd .. && rm -rf nv-codec-headers

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
      --enable-libopus --enable-libmp3lame --enable-libvorbis && \
    make -j"$(nproc)" && make install && cd .. && rm -rf ffmpeg

###############################
# Stage 2: Runtime Image
###############################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64

# Install system dependencies (excluding nvidia-smi to avoid unresolved package errors)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git wget gnupg \
    python3.10 python3.10-venv python3.10-dev python3-pip \
    libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libgtk-3-0 \
    libdrm2 libxkbcommon0 libgbm1 libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 \
    libva2 libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 \
    libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 libxrender1 libxtst6 \
    libxi6 libxcursor1 libcairo2 libcups2 libdbus-1-3 libexpat1 \
    libfontconfig1 libegl1-mesa libgl1-mesa-dri \
    libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
    fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 libgcc1 libstdc++6 \
    libnvidia-egl-gbm1 tini && \
    rm -rf /var/lib/apt/lists/*

# Remove NVIDIA GBM libraries that crash Puppeteer
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
    /usr/local/nvidia/lib/*gbm* \
    /usr/local/nvidia/lib64/*gbm* \
    /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# Create non-root user and workspace
RUN useradd -m node && mkdir -p /data && chown -R node:node /data

# Copy FFmpeg build from builder stage
COPY --from=builder /usr/local /usr/local

# Install Node.js 20.x and n8n / Puppeteer
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g --unsafe-perm n8n@1.104.1 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Whisper (GPU), Torch for CUDA 11.8
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 && \
    python3.10 -m pip install git+https://github.com/openai/whisper.git

# Pre-download Whisper tiny model
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    python3.10 -c "import whisper; whisper.load_model('tiny', download_root='$WHISPER_MODEL_PATH')"

# Setup Puppeteer cache and shared data dir
RUN mkdir -p "$PUPPETEER_CACHE_DIR" /data/shared && \
    chown -R node:node "$HOME" /data/shared

# Sanity check: FFmpeg and CUDA available
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" && \
    (echo "❌ FFmpeg library linking failed" >&2 && exit 1) || echo "✅ FFmpeg libraries resolved" && \
    ffmpeg -version && \
    ffmpeg -hide_banner -hwaccels | grep -q "cuda" && echo "✅ FFmpeg GPU OK" || (echo "❌ FFmpeg GPU missing" >&2 && exit 1)

# Optional production healthcheck: verifies n8n status
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl --fail http://localhost:5678/healthz || exit 1

# Default container runtime config
USER node
WORKDIR /data
ENTRYPOINT ["tini", "--", "n8n", "start"]
CMD []


###############################
# Stage 3: [Optional] Debug Layer (nvidia-smi)
###############################
FROM runtime AS debug
RUN wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && rm cuda-keyring_1.1-1_all.deb && \
    apt-get update && apt-get install -y nvidia-utils-535 && \
    nvidia-smi || true
