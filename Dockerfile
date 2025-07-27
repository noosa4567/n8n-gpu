# ----------------------------
# Stage 1 – Minimized FFmpeg for Whisper
# ----------------------------
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential yasm cmake libtool libc6-dev libnuma-dev pkg-config git wget \
      libass-dev libvorbis-dev libopus-dev libmp3lame-dev libpostproc-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* && \
    git clone --depth 1 --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git nv-codec-headers && \
    cd nv-codec-headers && make && make install && cd .. && rm -rf nv-codec-headers && \
    git clone --depth 1 --branch n5.1.4 https://git.ffmpeg.org/ffmpeg.git ffmpeg && \
    cd ffmpeg && \
    ./configure \
      --prefix=/usr/local \
      --disable-everything \
      --enable-shared \
      --disable-static \
      --enable-ffmpeg \
      --enable-postproc \
      --enable-protocol=file \
      --enable-demuxer=wav,mp3,flac,aac,ogg,opus,mov,matroska \
      --enable-decoder=pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,flac,mp3,aac,opus,vorbis \
      --enable-libass --enable-libvorbis --enable-libopus --enable-libmp3lame \
      --enable-gpl --enable-nonfree && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf ffmpeg /tmp/*

# ----------------------------
# Stage 2 – Runtime Image
# ----------------------------
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    TORCH_HOME=/opt/torch_cache \
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    NODE_PATH=/usr/local/lib/node_modules \
    CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox

# Copy compiled FFmpeg
COPY --from=builder /usr/local/bin/ff* /usr/local/bin/
COPY --from=builder /usr/local/lib/libav* /usr/local/lib/
COPY --from=builder /usr/local/lib/libsw* /usr/local/lib/
COPY --from=builder /usr/local/lib/libpostproc* /usr/local/lib/
COPY --from=builder /usr/local/include/libav* /usr/local/include/
COPY --from=builder /usr/local/include/libsw* /usr/local/include/
RUN ldconfig

# Create non-root user
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" && chown -R node:node "$HOME"

# Mesa + Puppeteer dependencies (added FFmpeg external runtime libs)
RUN apt-get update && apt-get install -y --no-install-recommends \
      software-properties-common && \
    add-apt-repository ppa:oibaf/graphics-drivers -y && \
    apt-get update && apt-get install -y --no-install-recommends \
      tini git curl ca-certificates gnupg wget xz-utils \
      python3 python3-pip binutils libglib2.0-bin \
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
      libnvidia-egl-gbm1 libass9 libmp3lame0 libopus0 libvorbis0a libvorbisenc2 && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /usr/share/man/* /usr/share/doc/* /var/log/* /var/tmp/*

# Remove NVIDIA’s conflicting libgbm
RUN rm -f /usr/local/nvidia/lib/libgbm.so.1 /usr/local/nvidia/lib64/libgbm.so.1 && rm -rf /tmp/*

# Legacy libsndio
RUN wget -qO /tmp/libsndio6.1.deb http://security.ubuntu.com/ubuntu/pool/universe/s/sndio/libsndio6.1_1.1.0-3_amd64.deb && \
    dpkg -i /tmp/libsndio6.1.deb && rm /tmp/libsndio6.1.deb && rm -rf /tmp/*

# Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_20.x -o nodesource_setup.sh && \
    bash nodesource_setup.sh && \
    apt-get install -y --no-install-recommends nodejs && \
    rm nodesource_setup.sh && apt-get clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/*

# Pip + Torch
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && rm -rf /root/.cache/pip/* /tmp/*
RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 && \
    rm -rf /root/.cache/pip/* /tmp/*

# Whisper with model preload
RUN pip3 install --no-cache-dir tiktoken openai-whisper && \
    mkdir -p "$WHISPER_MODEL_PATH" && \
    chown -R node:node "$WHISPER_MODEL_PATH" && \
    python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" && \
    rm -rf /root/.cache/pip/* /tmp/*

# Puppeteer + n8n (with SUID sandbox setup for fallback)
RUN npm install -g --unsafe-perm \
      n8n@1.104.1 \
      puppeteer@24.14.0 \
      n8n-nodes-puppeteer@1.4.1 \
      ajv@8.17.1 \
      --legacy-peer-deps && \
    npm cache clean --force && \
    mkdir -p "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$PUPPETEER_CACHE_DIR" "$(npm root -g)" && rm -rf /tmp/* && \
    # Set up SUID sandbox
    chrome_path=$(node -e "console.log(require('puppeteer').executablePath())") && \
    sandbox_dir=$(dirname "$chrome_path") && \
    cp "$sandbox_dir/chrome_sandbox" /usr/local/sbin/chrome-devel-sandbox && \
    chown root:root /usr/local/sbin/chrome-devel-sandbox && \
    chmod 4755 /usr/local/sbin/chrome-devel-sandbox

# Runtime dirs
RUN mkdir -p "$HOME/.cache/n8n/public" /data/shared/{videos,audio,transcripts} && \
    chown -R node:node "$HOME" /data/shared && chmod -R 770 /data/shared "$HOME/.cache"

# FFmpeg link check
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" && \
    (echo "❌ unresolved FFmpeg libs" >&2 && exit 1) || echo "✅ FFmpeg libs OK"

USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini", "--", "n8n", "start"]
CMD []
