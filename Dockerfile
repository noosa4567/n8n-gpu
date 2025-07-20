# --------------------------------------------------------------------------------
#  Base image: CUDA 11.8 with cuDNN8 development libs on Ubuntu 22.04
#  (bundles all user-space CUDA libs; matches P2200 driver on host)
# --------------------------------------------------------------------------------
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04

USER root

# --------------------------------------------------------------------------------
#  1) System deps: build tools, FFmpeg libs (incl. libsndio6), Python, Node.js 20
# --------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      # Core build tools
      build-essential git pkg-config yasm nasm autoconf automake libtool \
      # FFmpeg audio/video libs
      libfreetype6-dev libass-dev libtheora-dev libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
      zlib1g-dev texinfo libx264-dev libx265-dev libnuma-dev libvpx-dev \
      libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      # Audio output & sndio
      libasound2-dev libsndio6 libsndio-dev \
      # Python 3 + pip
      python3 python3-pip python3-venv ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 from NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------------------------------------
#  2) NVIDIA NVENC/NVDEC headers for FFmpeg
# --------------------------------------------------------------------------------
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# --------------------------------------------------------------------------------
#  3) Build & install FFmpeg with sndio + GPU accel (verbose & verify)
# --------------------------------------------------------------------------------
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
 && ffmpeg -version

# --------------------------------------------------------------------------------
#  4) Refresh dynamic loader cache & set LD paths
# --------------------------------------------------------------------------------
RUN echo "/usr/local/lib"        > /etc/ld.so.conf.d/ffmpeg.conf \
 && echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf \
 && echo "/usr/local/nvidia/lib" > /etc/ld.so.conf.d/nvidia.conf \
 && ldconfig

ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib

# --------------------------------------------------------------------------------
#  5) Python ML & Whisper: install, pre-download model, fix perms
# --------------------------------------------------------------------------------
RUN python3 -m pip install --break-system-packages --no-cache-dir --upgrade pip \
 && python3 -m pip install --break-system-packages --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --break-system-packages --no-cache-dir openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "from whisper import _download,_MODELS; _download(_MODELS['base'], '/usr/local/lib/whisper_models', in_memory=False)" \
 && chown -R node:node /usr/local/lib/whisper_models

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# --------------------------------------------------------------------------------
#  6) Install n8n globally
# --------------------------------------------------------------------------------
RUN npm install -g n8n && npm cache clean --force

# --------------------------------------------------------------------------------
#  7) Prepare QNAP volumes & permissions
#    (host-mounted /data/... may still need host-side chmod/chown to UID 1000)
# --------------------------------------------------------------------------------
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data /usr/local/lib/whisper_models /home/node \
 && chmod -R 777 /data /usr/local/lib/whisper_models /home/node

# --------------------------------------------------------------------------------
#  8) Switch to unprivileged user & expose port
# --------------------------------------------------------------------------------
USER node
EXPOSE 5678

# --------------------------------------------------------------------------------
#  9) Default command (easy override)
# --------------------------------------------------------------------------------
CMD ["n8n", "start"]
