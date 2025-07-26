# ULTIMATE Dockerfile: n8n + Whisper + Puppeteer + GPU + FFmpeg built from source (CUDA 11.8 + Ubuntu 22.04)
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64

# 1) Create non-root 'node' user (UID 999) in 'video' group
RUN groupadd -r node \
 && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

# 2) Remove NVIDIA/CUDA APT lists
RUN rm -f /etc/apt/sources.list.d/cuda* /etc/apt/sources.list.d/nvidia*

# 3) Add modern Mesa PPA for GBM symbol support
RUN apt-get update \
 && apt-get install -y --no-install-recommends software-properties-common \
 && add-apt-repository ppa:oibaf/graphics-drivers -y \
 && apt-get update

# 4) Install dependencies for runtime + Puppeteer + Whisper
RUN apt-get install -y --no-install-recommends \
      tini git curl ca-certificates gnupg wget xz-utils \
      python3 python3-pip binutils \
      libsndio7.0 libasound2 libsdl2-2.0-0 libxv1 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      libx11-6 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 \
      libxrender1 libxss1 libxtst6 libxi6 libxcursor1 \
      libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdbus-1-3 libexpat1 \
      libfontconfig1 libgbm1 libegl1-mesa libgl1-mesa-dri libdrm2 \
      libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
      libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
      fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 libgcc1 libstdc++6 \
      libnvidia-egl-gbm1 \
 && rm -rf /var/lib/apt/lists/*

# 5) Remove NVIDIA’s outdated libgbm that breaks Puppeteer
RUN rm -f /usr/local/nvidia/lib/libgbm.so.1 /usr/local/nvidia/lib64/libgbm.so.1

# 6) (Optional legacy) Pull in Bionic's libsndio6.1
RUN wget -qO /tmp/libsndio6.1.deb \
      http://security.ubuntu.com/ubuntu/pool/universe/s/sndio/libsndio6.1_1.1.0-3_amd64.deb \
 && dpkg -i /tmp/libsndio6.1.deb \
 && rm /tmp/libsndio6.1.deb

# 7) Install FFmpeg build dependencies (CUDA 11.8 + NVENC support)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential yasm cmake libtool libc6-dev libnuma-dev pkg-config \
      git wget curl ca-certificates \
      libass-dev libfreetype6-dev libfontconfig-dev libxml2-dev \
      libvorbis-dev libopus-dev libx264-dev libx265-dev libmp3lame-dev \
 && rm -rf /var/lib/apt/lists/*

# 7.5) Install NVIDIA Video Codec SDK headers for ffnvcodec (fixes cuvid/ffnvcodec dependency)
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers \
 && git checkout n11.1.5.3 \
 && make \
 && make install \
 && cd .. \
 && rm -rf nv-codec-headers

# 8) Build and install FFmpeg 5.1.4 with CUDA/NVENC
RUN git clone https://git.ffmpeg.org/ffmpeg.git -b n5.1.4 \
 && cd ffmpeg \
 && ./configure \
      --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-cuda-nvcc --enable-ffnvcodec --enable-libnpp --enable-cuvid --enable-nvdec --enable-nvenc \
      --enable-libass --enable-libfreetype --enable-libfontconfig \
      --enable-libxml2 --enable-libvorbis --enable-libopus --enable-libx264 --enable-libx265 --enable-libmp3lame \
      --extra-cflags=-I/usr/local/cuda/include \
      --extra-ldflags=-L/usr/local/cuda/lib64 \
 && make -j$(nproc) \
 && make install \
 && cd .. \
 && rm -rf ffmpeg \
 && ldconfig

# 9) Install Node.js 20.x (needs curl and ca-certificates)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x -o nodesource_setup.sh \
 && bash nodesource_setup.sh \
 && apt-get install -y --no-install-recommends nodejs \
 && rm nodesource_setup.sh \
 && rm -rf /var/lib/apt/lists/*

# 10) Globally install n8n + Puppeteer (needs git for n8n-nodes-puppeteer)
RUN npm install -g --unsafe-perm \
      n8n@1.104.1 \
      puppeteer@24.14.0 \
      n8n-nodes-puppeteer@1.4.1 \
      ajv@8.17.1 \
      --legacy-peer-deps \
 && npm cache clean --force \
 && mkdir -p "$PUPPETEER_CACHE_DIR" \
 && chown -R node:node "$PUPPETEER_CACHE_DIR" "$(npm root -g)"

# 11) Now cleanup build dependencies
RUN apt-get purge -y \
      build-essential yasm cmake libtool libnuma-dev pkg-config git wget \
      libass-dev libfreetype6-dev libfontconfig-dev libxml2-dev \
      libvorbis-dev libopus-dev libx264-dev libx265-dev libmp3lame-dev \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# 12) Install Whisper + CUDA
RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "$WHISPER_MODEL_PATH" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "$WHISPER_MODEL_PATH"

# 13) Prepare shared media + n8n runtime dirs
RUN mkdir -p \
      "$HOME/.cache/n8n/public" \
      /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared \
 && chmod -R 770 /data/shared "$HOME/.cache"

# 14) FFmpeg sanity check
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "❌ unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 15) Run n8n as non-root
USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini", "--", "n8n", "start"]
CMD []
