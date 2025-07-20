# -----------------------------------------------------------------------------
# Base image: CUDA 11.8 Devel on Ubuntu 22.04 (bundles CUDA runtimes & dev libs)
# -----------------------------------------------------------------------------
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04

USER root

# -----------------------------------------------------------------------------
# 1) Install build & runtime deps, including libsndio7.0 and full Python
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git pkg-config yasm nasm autoconf automake libtool \
      libfreetype6-dev libass-dev libtheora-dev libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
      zlib1g-dev texinfo libx264-dev libx265-dev libnuma-dev libvpx-dev \
      libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      libasound2-dev libsndio-dev libsndio7.0 \
      python3-full python3-dev python3-pip python3-venv \
      ca-certificates curl gnupg2 dirmngr \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2) Install Node.js 20 from NodeSource
# -----------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 3) Build NVIDIA NVENC/NVDEC headers
# -----------------------------------------------------------------------------
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# -----------------------------------------------------------------------------
# 4) Clone, build & install FFmpeg (sndio + NVENC/NVDEC), verbose & verify
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
# 5) Ensure loader sees /usr/local/lib & CUDA libs at runtime
# -----------------------------------------------------------------------------
RUN echo "/usr/local/lib"        > /etc/ld.so.conf.d/ffmpeg.conf \
 && echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf \
 && ldconfig

ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64

# -----------------------------------------------------------------------------
# 6) Install PyTorch (cu118) + Whisper, pre-download "base" model & fix perms
# -----------------------------------------------------------------------------
RUN python3 -m pip install --no-cache-dir --upgrade pip \
 && python3 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --no-cache-dir openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "from whisper import _download,_MODELS; _download(_MODELS['base'], '/usr/local/lib/whisper_models', in_memory=False)" \
 && chown -R node:node /usr/local/lib/whisper_models

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# -----------------------------------------------------------------------------
# 7) Install n8n globally
# -----------------------------------------------------------------------------
RUN npm install -g n8n && npm cache clean --force

# -----------------------------------------------------------------------------
# 8) Prepare QNAP Container Station mounts & permissions
# -----------------------------------------------------------------------------
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data /usr/local/lib/whisper_models /home/node \
 && chmod -R 777 /data /usr/local/lib/whisper_models /home/node

# -----------------------------------------------------------------------------
# 9) Drop to unprivileged node user and expose port
# -----------------------------------------------------------------------------
USER node
EXPOSE 5678

# -----------------------------------------------------------------------------
# 10) Start n8n (CMD for easy overrides)
# -----------------------------------------------------------------------------
CMD ["n8n", "start"]
