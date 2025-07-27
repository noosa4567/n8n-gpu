# ----------------------------
# Stage 1 – Build FFmpeg with GPU Acceleration
# ----------------------------
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential yasm cmake libtool libc6-dev libnuma-dev pkg-config git wget \
    libass-dev libvorbis-dev libopus-dev libmp3lame-dev libx264-dev libx265-dev \
    libvpx-dev libfdk-aac-dev libxml2-dev libunistring-dev && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN git clone --depth 1 --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && make && make install && cd .. && rm -rf nv-codec-headers

RUN git clone --depth 1 --branch n5.1.4 https://git.ffmpeg.org/ffmpeg.git && \
    cd ffmpeg && \
    ./configure \
      --prefix=/usr/local \
      --pkg-config-flags="--static" \
      --extra-cflags="-I/usr/local/cuda/include" \
      --extra-ldflags="-L/usr/local/cuda/lib64" \
      --extra-libs="-lpthread -lm" \
      --enable-cuda --enable-cuvid --enable-nvenc \
      --enable-nonfree --enable-gpl --enable-postproc --enable-shared \
      --enable-libass --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libx264 --enable-libx265 --enable-libfdk-aac --enable-libvpx && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf ffmpeg

# ----------------------------
# Stage 2 – Runtime Container
# ----------------------------
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    TORCH_HOME=/opt/torch_cache \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/lib/x86_64-linux-gnu \
    NODE_PATH=/usr/local/lib/node_modules \
    CHROME_DEVEL_SANDBOX=/usr/local/sbin/chrome-devel-sandbox

# Copy FFmpeg and all its shared libraries from builder
COPY --from=builder /usr/local/bin/ff* /usr/local/bin/
COPY --from=builder /usr/local/lib/lib* /usr/local/lib/
COPY --from=builder /usr/lib/x86_64-linux-gnu/lib* /usr/lib/x86_64-linux-gnu/
RUN ldconfig

RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" && chown -R node:node "$HOME"

RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common && \
    add-apt-repository ppa:oibaf/graphics-drivers -y && \
    apt-get update && apt-get install -y --no-install-recommends \
    tini git curl ca-certificates gnupg wget xz-utils python3 python3-pip binutils \
    libglib2.0-bin libsndio7.0 libasound2 libsdl2-2.0-0 libxv1 \
    libva2 libva-x11-2 libva-drm2 libva-wayland2 \
    libvdpau1 libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
    libx11-6 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 \
    libxrender1 libxss1 libxtst6 libxi6 libxcursor1 \
    libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdbus-1-3 libexpat1 \
    libfontconfig1 libgbm1 libegl1-mesa libgl1-mesa-dri libdrm2 \
    libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
    libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
    fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 libgcc1 libstdc++6 \
    libnvidia-egl-gbm1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

RUN rm -f /usr/local/nvidia/lib/libgbm.so.1 /usr/local/nvidia/lib64/libgbm.so.1

RUN curl -fsSL https://deb.nodesource.com/setup_20.x -o nodesource_setup.sh && \
    bash nodesource_setup.sh && \
    apt-get install -y --no-install-recommends nodejs && \
    rm nodesource_setup.sh && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 && \
    pip3 install --no-cache-dir tiktoken openai-whisper && \
    mkdir -p "$WHISPER_MODEL_PATH" && \
    chown -R node:node "$WHISPER_MODEL_PATH" && \
    python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])"

RUN npm install -g --unsafe-perm \
    n8n@1.104.1 \
    puppeteer@24.14.0 \
    n8n-nodes-puppeteer@1.4.1 \
    ajv@8.17.1 --legacy-peer-deps && \
    npm cache clean --force && \
    mkdir -p "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$PUPPETEER_CACHE_DIR" "$(npm root -g)" && \
    cp $PUPPETEER_CACHE_DIR/chrome/linux-*/chrome-linux64/chrome_sandbox /usr/local/sbin/chrome-devel-sandbox && \
    chown root:root /usr/local/sbin/chrome-devel-sandbox && \
    chmod 4755 /usr/local/sbin/chrome-devel-sandbox

RUN mkdir -p "$HOME/.cache/n8n/public" /data/shared/{videos,audio,transcripts} && \
    chown -R node:node "$HOME" /data/shared && chmod -R 770 /data/shared "$HOME/.cache"

RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" && \
    (echo "❌ unresolved FFmpeg libs" >&2 && exit 1) || echo "✅ FFmpeg libs OK"

USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini", "--", "n8n", "start"]
CMD []
