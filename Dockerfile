# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 ─ build a *fully-static* FFmpeg with CUDA/NVENC support
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ENV DEBIAN_FRONTEND=noninteractive \
    PREFIX=/usr/local \
    BUILD_DIR=/tmp/ffmpeg_sources \
    PATH=/usr/local/cuda/bin:$PATH

# ── 1) tool-chain only — runtime stage stays clean ───────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential git pkg-config yasm cmake libtool nasm curl unzip \
        autoconf automake libnuma-dev zlib1g-dev libfreetype6-dev \
        libfontconfig-dev libharfbuzz-dev libogg-dev && \
    rm -rf /var/lib/apt/lists/* && mkdir -p "$BUILD_DIR"

WORKDIR "$BUILD_DIR"

# ── 2) NVENC headers ─────────────────────────────────────────────────────────
RUN git clone --branch n13.0.19.0 https://github.com/FFmpeg/nv-codec-headers.git && \
    make -C nv-codec-headers -j"$(nproc)" install && rm -rf nv-codec-headers

# ── 3) external codec libraries – built *static* (.a) ────────────────────────
RUN git clone --branch stable https://code.videolan.org/videolan/x264.git && \
    cd x264 && ./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-opencl && \
    make -j"$(nproc)" && make install && cd .. && rm -rf x264

RUN git clone --depth 1 --branch v2.0.3 https://github.com/mstorsjo/fdk-aac.git && \
    cd fdk-aac && autoreconf -fiv && \
    ./configure --prefix="$PREFIX" --enable-static --disable-shared && \
    make -j"$(nproc)" && make install && cd .. && rm -rf fdk-aac

RUN curl -fsSL https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz -o lame.tar.gz && \
    tar -xzf lame.tar.gz && cd lame-3.100 && \
    ./configure --prefix="$PREFIX" --enable-static --disable-shared --enable-nasm && \
    make -j"$(nproc)" && make install && cd .. && rm -rf lame-3.100 lame.tar.gz

RUN curl -fsSL https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz -o opus.tar.gz && \
    tar -xzf opus.tar.gz && cd opus-1.5.2 && \
    ./configure --prefix="$PREFIX" --enable-static --disable-shared && \
    make -j"$(nproc)" && make install && cd .. && rm -rf opus-1.5.2 opus.tar.gz

RUN curl -fsSL https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz -o vorbis.tar.gz && \
    tar -xzf vorbis.tar.gz && cd libvorbis-1.3.7 && \
    ./configure --prefix="$PREFIX" --enable-static --disable-shared && \
    make -j"$(nproc)" && make install && cd .. && rm -rf libvorbis-1.3.7 vorbis.tar.gz

RUN git clone https://chromium.googlesource.com/webm/libvpx.git && \
    cd libvpx && \
    ./configure --prefix="$PREFIX" --enable-static --disable-shared \
        --disable-examples --disable-unit-tests --enable-vp9-highbitdepth && \
    make -j"$(nproc)" && make install && cd .. && rm -rf libvpx

# ── 4) FFmpeg (static + NVENC) ───────────────────────────────────────────────
RUN git clone --depth 1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git && \
    cd FFmpeg && \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure \
        --prefix="$PREFIX" --pkg-config-flags="--static" \
        --extra-cflags="-I/usr/local/cuda/include -I$PREFIX/include" \
        --extra-ldflags="-L/usr/local/cuda/lib64 -L$PREFIX/lib -static -Bstatic" \
        --extra-libs="-lpthread -lm -lz" \
        --enable-cuda --enable-cuvid --enable-nvenc \
        --enable-nonfree --enable-gpl --enable-postproc \
        --enable-libx264 --enable-libfdk-aac \
        --enable-libvpx --enable-libopus --enable-libmp3lame --enable-libvorbis \
        --enable-static --disable-shared \
        --disable-sdl2 --disable-sndio \
        --disable-libxcb --disable-indev=x11grab --disable-outdev=xv \
        --disable-opengl && \
    make -j"$(nproc)" && make install && cd .. && rm -rf FFmpeg

RUN rm -rf "$BUILD_DIR"

###############################################################################
# Stage 2 – runtime: CUDA 11.8, n8n, Chrome, Torch, Whisper (medium-int8)
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    TZ=Australia/Brisbane \
    PIP_ROOT_USER_ACTION=ignore \
    PATH=/usr/local/bin:$PATH \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

# ── 1) base libs + Chrome ────────────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        software-properties-common ca-certificates curl git wget gnupg tini \
        python3.10 python3.10-venv python3.10-dev python3-pip \
        libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 \
        libatk-bridge2.0-0 libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 \
        libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 libva2 \
        libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 libxcb-shape0 \
        libxcb-shm0 libxcb-xfixes0 libxcb-render0 libxrender1 libxtst6 \
        libxi6 libxcursor1 libcairo2 libcups2 libdbus-1-3 libexpat1 \
        libfontconfig1 libegl1-mesa libgl1-mesa-dri libpangocairo-1.0-0 \
        libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
        fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 \
        libgcc1 libstdc++6 libnvidia-egl-gbm1 libsndio7.0 libxv1 libsdl2-2.0-0 && \
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# ── 2) soname symlinks expected by NVENC ─────────────────────────────────────
RUN ln -sf /usr/lib/x86_64-linux-gnu/libsndio.so.7.0   /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva.so.2        /usr/lib/x86_64-linux-gnu/libva.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-drm.so.2    /usr/lib/x86_64-linux-gnu/libva-drm.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-x11.so.2    /usr/lib/x86_64-linux-gnu/libva-x11.so.1 && \
    ln -sf /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

# ── 3) remove NVIDIA GBM stubs that crash headless Chrome ────────────────────
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# ── 4) non-root user + cache dirs ────────────────────────────────────────────
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" && chown -R node:node "$HOME"

# ── 5) static FFmpeg from Stage 1 ────────────────────────────────────────────
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe
RUN mkdir -p /usr/local/nvidia/bin && \
    ln -sf /usr/local/bin/ffmpeg  /usr/local/nvidia/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/local/nvidia/bin/ffprobe

# ── 6) Node 20 + n8n + Puppeteer ─────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    npm install -g --unsafe-perm n8n@1.104.2 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 && \
    npm cache clean --force && chown -R node:node /home/node/.npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ── 7) Puppeteer’s managed Chromium ──────────────────────────────────────────
USER node
RUN npx puppeteer@24.15.0 browsers install chrome
USER root

# ── 8) Torch/cu118 + Whisper ────────────────────────────────────────────────
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install --no-cache-dir \
        torch==2.3.1+cu118 torchvision==0.18.1+cu118 torchaudio==2.3.1+cu118 \
        --index-url https://download.pytorch.org/whl/cu118 && \
    python3.10 -m pip install --no-cache-dir \
        numba==0.61.2 tiktoken==0.9.0 \
        git+https://github.com/openai/whisper.git@v20250625

# ── 9) download + dynamic-INT8 quantise Whisper *medium* (CPU) ───────────────
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    printf '%s\n' \
      "import os, torch, whisper, torch.nn as nn" \
      "root = os.environ['WHISPER_MODEL_PATH']" \
      "model = whisper.load_model('medium', device='cpu')" \
      "model_q = torch.quantization.quantize_dynamic(model, {nn.Linear, nn.LSTM}, dtype=torch.qint8)" \
      "torch.save(model_q.state_dict(), os.path.join(root, 'medium.pt'))" \
    > /tmp/quantise.py && python3.10 /tmp/quantise.py && rm /tmp/quantise.py

# ── 9b) symlink so  load_model('medium')  works out-of-the-box ───────────────
RUN mkdir -p /home/node/.cache && \
    ln -s /usr/local/lib/whisper_models /home/node/.cache/whisper && \
    chown -h node:node /home/node/.cache/whisper

# ── 10) quick sanity-check FFmpeg sees CUDA ──────────────────────────────────
RUN ffmpeg -hide_banner -hwaccels | grep -q cuda

# ── 11) PATH shim (static /usr/local/bin first after NVIDIA hook) ────────────
RUN printf '%s\n' '#!/bin/sh' 'export PATH=/usr/local/bin:$PATH' 'exec "$@"' \
    > /usr/local/bin/n8n-wrapper && chmod +x /usr/local/bin/n8n-wrapper

# ── 12) health-check + entrypoint ────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR "$HOME"
EXPOSE 5678
ENTRYPOINT ["tini","--","/usr/local/bin/n8n-wrapper","n8n"]
CMD ["start"]
