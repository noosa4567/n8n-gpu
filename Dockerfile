FROM node:20-bookworm-slim

USER root

# 1) Enable Bookworm non-free repos & install build/runtime deps (incl. sndio runtime + CUDA toolkit)
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

# 2) NVIDIA codec headers for NVENC/NVDEC
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers \
 && make install \
 && cd .. \
 && rm -rf nv-codec-headers

# 3) Build & install FFmpeg (with sndio + NVIDIA acceleration)
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && ./configure --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-alsa --enable-sndio \
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && make -j"$(nproc)" \
 && make install \
 && cd .. \
 && rm -rf ffmpeg

# 4) Refresh shared library cache (so /usr/local/lib & CUDA libs are found)
RUN ldconfig

# 5) Install PyTorch (cu118) & Whisper, then pre-download the base model
RUN python3 -m pip install --no-cache-dir --upgrade pip \
 && python3 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --no-cache-dir openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "from whisper import _download,_MODELS; _download(_MODELS['base'], '/usr/local/lib/whisper_models', in_memory=False)"

# 6) Install n8n
RUN npm install -g n8n \
 && npm cache clean --force

# 7) Prepare QNAP Container Station volumes & permissions  
#    (Host-side mounts must also be chmod’d/chown’d appropriately if needed)
RUN mkdir -p /data/shared/videos /data/shared/audio /data/shared/transcripts /usr/local/lib/whisper_models \
 && chown -R node:node /data /usr/local/lib/whisper_models /home/node \
 && chmod -R 777 /data /usr/local/lib/whisper_models /home/node

# 8) Drop back to unprivileged `node` user
USER node

EXPOSE 5678
ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 9) Use CMD (per n8n recommendations) for easier overrides
CMD ["n8n", "start"]
