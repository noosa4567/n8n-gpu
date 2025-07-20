# -----------------------------------------------------------------------------
# 1) Base: CUDA 11.8 devel image on Ubuntu 22.04 (bundles all CUDA runtimes)
# -----------------------------------------------------------------------------
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04

USER root

# -----------------------------------------------------------------------------
# 2) Install build & runtime deps, including libsndio6 for FFmpeg
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git pkg-config yasm nasm autoconf automake libtool \
      libfreetype6-dev libass-dev libtheora-dev libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
      zlib1g-dev texinfo libx264-dev libx265-dev libnuma-dev libvpx-dev \
      libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      libasound2-dev libsndio-dev libsndio6 \
      python3 python3-pip python3-venv ca-certificates curl gnupg2 dirmngr \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 3) Install Node.js 20 via NodeSource
# -----------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 4) Build NVIDIA NVENC/NVDEC headers
# -----------------------------------------------------------------------------
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# -----------------------------------------------------------------------------
# 5) Clone, build & install FFmpeg with sndio + NVENC/NVDEC
# -----------------------------------------------------------------------------
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && ./configure --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-alsa --enable-sndio \
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && make -j"$(nproc)" V=1 \
 && make install V=1 \
 && cd .. && rm -rf ffmpeg \
 && ldconfig \
 && ffmpeg -version

# -----------------------------------------------------------------------------
# 6) Add loader paths for FFmpeg & CUDA libs at runtime
# -----------------------------------------------------------------------------
RUN echo "/usr/local/lib"        > /etc/ld.so.conf.d/ffmpeg.conf \
 && echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf \
 && ldconfig

ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64

# -----------------------------------------------------------------------------
# 7) Install PyTorch (cu118) & Whisper, pre-download model & fix perms
# -----------------------------------------------------------------------------
RUN python3 -m pip install --break-system-packages --no-cache-dir --upgrade pip \
 && python3 -m pip install --break-system-packages --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --break-system-packages --no-cache-dir openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "from whisper import _download,_MODELS; _download(_MODELS['base'], '/usr/local/lib/whisper_models', in_memory=False)" \
 && chown -R node:node /usr/local/lib/whisper_models

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# -----------------------------------------------------------------------------
# 8) Install n8n globally
# -----------------------------------------------------------------------------
RUN npm install -g n8n && npm cache clean --force

# -----------------------------------------------------------------------------
# 9) Prepare QNAP Container Station mounts & permissions
# -----------------------------------------------------------------------------
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data /usr/local/lib/whisper_models /home/node \
 && chmod -R 777 /data /usr/local/lib/whisper_models /home/node

# -----------------------------------------------------------------------------
# 10) Switch to non-root user & expose port
# -----------------------------------------------------------------------------
USER node
EXPOSE 5678

# -----------------------------------------------------------------------------
# 11) Start n8n (via CMD, allowing overrides)
# -----------------------------------------------------------------------------
CMD ["n8n", "start"]
