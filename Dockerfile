FROM node:20-bookworm-slim

# 1) Switch to root to install system dependencies
USER root

# 2) Enable Debian non-free repos and pull in build/runtime packages
RUN echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list \
 && echo "deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list \
 && echo "deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      # FFmpeg build deps
      git pkg-config yasm nasm build-essential autoconf automake libtool libc6-dev \
      libass-dev libfreetype6-dev libsdl2-dev libtheora-dev libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
      texinfo zlib1g-dev libx264-dev libx265-dev libnuma-dev libvpx-dev \
      libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      # audio output support
      libasound2-dev libsndio-dev \
      # NVIDIA user-space CUDA toolkit (for libnppig, libcudart, etc.)
      nvidia-cuda-toolkit \
      # Python + HTTPS support
      python3 python3-pip python3-venv ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# 3) Install NVIDIA codec headers so FFmpeg can compile NVENC/NVDEC
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# 4) Build & install FFmpeg (with sndio + NVENC/NVDEC)
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && ./configure --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-alsa --enable-sndio \        # now includes sndio support
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && make -j"$(nproc)" \
 && make install \
 && cd .. && rm -rf ffmpeg

# 5) Refresh linker cache so /usr/local/lib and CUDA libs are found
RUN ldconfig

# 6) Install PyTorch (cu118) and Whisper, then pre-download the "base" model
RUN python3 -m pip install --no-cache-dir --upgrade pip \
 && python3 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --no-cache-dir openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "from whisper import _download,_MODELS; \
       _download(_MODELS['base'], '/usr/local/lib/whisper_models', in_memory=False)"

# 7) Install n8n globally
RUN npm install -g n8n \
 && npm cache clean --force

# 8) Prepare QNAP Container Station volumes & permissions
RUN mkdir -p /data/shared/videos /data/shared/audio /data/shared/transcripts /usr/local/lib/whisper_models \
 && chown -R node:node /data /usr/local/lib/whisper_models /home/node \
 && chmod -R 777  /data /usr/local/lib/whisper_models /home/node

# 9) Drop privileges back to the `node` user
USER node

# 10) Final runtime settings
EXPOSE 5678
ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models
ENTRYPOINT ["n8n", "start"]
