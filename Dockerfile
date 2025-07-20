FROM node:20-bookworm-slim

USER root

# 1) Set up Debian repos and install build & runtime deps (including libsndio6)
RUN echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list \
 && echo "deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list \
 && echo "deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      git pkg-config yasm nasm build-essential autoconf automake libtool libc6-dev \
      libass-dev libfreetype6-dev libsdl2-dev libtheora-dev libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev texinfo \
      zlib1g-dev libx264-dev libx265-dev libnuma-dev libvpx-dev libfdk-aac-dev \
      libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev libasound2-dev \
      libsndio6 \
      python3 python3-pip python3-venv ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# 2) NVIDIA codec headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# 3) Build and install FFmpeg (fail loudly on error!)
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && ./configure \
      --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-alsa --disable-sndio \
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && make -j"$(nproc)" \
 && make install \
 && cd .. && rm -rf ffmpeg

# 4) Refresh the shared library cache so /usr/local/lib is found
RUN ldconfig

# 5) Install Python ML libraries globally
RUN python3 -m pip install --no-cache-dir --upgrade pip \
 && python3 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --no-cache-dir openai-whisper

# 6) Pre-download Whisper model
RUN mkdir -p /usr/local/lib/whisper_models \
 && python3 - << 'EOF' \
import os; from whisper import _download, _MODELS; \
_download(_MODELS['base'], '/usr/local/lib/whisper_models', in_memory=False) \
EOF

# 7) Install n8n
RUN npm install -g n8n \
 && npm cache clean --force

# Drop back to non-root for security
USER node

EXPOSE 5678

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

CMD ["n8n", "start"]
