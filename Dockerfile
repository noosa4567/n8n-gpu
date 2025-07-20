# 1) Base on CUDA 11.8 runtime + cuDNN 8 so we have libcudart, libnvrtc, etc.
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

USER root

# 2) Install Node.js 20, build tools, FFmpeg deps, Python, runtime libs (incl. libsndio6)
RUN apt-get update && apt-get install -y --no-install-recommends \
    # basics
    curl ca-certificates gnupg lsb-release \
    # Node.js 20
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    # FFmpeg build & runtime deps
    git pkg-config yasm nasm build-essential autoconf automake libtool \
    libass-dev libfreetype6-dev libsdl2-dev libtheora-dev libva-dev \
    libvdpau-dev libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
    texinfo zlib1g-dev libx264-dev libx265-dev libnuma-dev libvpx-dev \
    libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
    libasound2-dev libsndio6 \
    # Python
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# 3) Make sure the CUDA libs are on the loader path
RUN echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf && ldconfig

# 4) Build & install NVIDIA codec headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# 5) Build & install FFmpeg (NVENC/NVDEC + all your libs)
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && ./configure --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-alsa --disable-sndio \
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && make -j"$(nproc)" \
 && make install \
 && cd .. && rm -rf ffmpeg \
 && ldconfig

# 6) Install Python ML libs & Whisper
RUN python3 -m pip install --no-cache-dir --upgrade pip \
 && python3 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --no-cache-dir openai-whisper

# 7) Pre-download the Whisper base model
RUN mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "from whisper import _download,_MODELS; _download(_MODELS['base'], '/usr/local/lib/whisper_models', in_memory=False)"

# 8) Install n8n globally
RUN npm install -g n8n && npm cache clean --force

# 9) Create an unprivileged user, fix permissions
RUN useradd --create-home --shell /bin/bash n8n \
 && chown -R n8n:n8n /usr/local/lib/whisper_models

USER n8n

EXPOSE 5678
ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

ENTRYPOINT ["n8n","start"]
