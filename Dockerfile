FROM node:20-bookworm-slim

USER root

# 1) Enable Bookworm non-free repos & install build/runtime deps
RUN echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list \
 && echo "deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list \
 && echo "deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      git pkg-config yasm nasm build-essential autoconf automake libtool libc6-dev \
      libass-dev libfreetype6-dev libsdl2-dev libtheora-dev libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
      texinfo zlib1g-dev libx264-dev libx265-dev libnuma-dev libvpx-dev \
      libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      libasound2-dev libsndio-dev libsndio7.0 \
      nvidia-cuda-toolkit \
      python3 python3-pip python3-venv ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# 2) NVIDIA NVENC/NVDEC headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# 3) Build & install FFmpeg (sndio + GPU accel), verbose & verify
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

# 4) Refresh loader cache for FFmpeg & CUDA libs
RUN echo "/usr/local/lib"        > /etc/ld.so.conf.d/ffmpeg.conf \
 && echo "/usr/local/nvidia/lib" > /etc/ld.so.conf.d/nvidia.conf \
 && ldconfig

# 5) Install PyTorch (cu118) & Whisper (with PEP668 override), pre-download model, fix perms
RUN python3 -m pip install --break-system-packages --no-cache-dir --upgrade pip \
 && python3 -m pip install --break-system-packages --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --break-system-packages --no-cache-dir openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "from whisper import _download,_MODELS; _download(_MODELS['base'],'/usr/local/lib/whisper_models',in_memory=False)" \
 && chown -R node:node /usr/local/lib/whisper_models

# 6) Install n8n globally
RUN npm install -g n8n \
 && npm cache clean --force

# 7) Prepare QNAP mount points & permissions
RUN mkdir -p /data/shared/videos /data/shared/audio /data/shared/transcripts \
 && chown -R node:node /data /usr/local/lib/whisper_models /home/node \
 && chmod -R 777 /data /usr/local/lib/whisper_models /home/node

# 8) Drop back to unprivileged user
USER node

# 9) Runtime env & port
ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/nvidia/lib
EXPOSE 5678

# 10) Use CMD for n8n entry (easy override)
CMD ["n8n", "start"]
