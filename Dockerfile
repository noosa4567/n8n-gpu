# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 – build a fully static, CUDA/NVENC-enabled FFmpeg
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

# – ensure noninteractive apt + set PREFIX for installs + add CUDA to PATH
ENV DEBIAN_FRONTEND=noninteractive \
    PREFIX=/usr/local \
    BUILD_DIR=/tmp/ffmpeg_sources \
    PATH=/usr/local/cuda/bin:$PATH

# 1) Install only the build-time headers and tools we need (no shared libs for ffmpeg deps)
#    including libogg-dev so that libvorbis can compile statically.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential git pkg-config yasm cmake libtool nasm curl unzip \
      autoconf automake libnuma-dev zlib1g-dev libfreetype6-dev \
      libfontconfig-dev libharfbuzz-dev libogg-dev && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p $BUILD_DIR

WORKDIR $BUILD_DIR

# 2) NVIDIA headers for NVENC/CUVID
RUN git clone --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git && \
    make -C nv-codec-headers -j"$(nproc)" install && \
    rm -rf nv-codec-headers

# 3) Build all external dependencies as static-only: x264, fdk-aac, lame, opus, vorbis, vpx
#    This ensures FFmpeg links to .a files, not dynamic .so files.
RUN git clone https://code.videolan.org/videolan/x264.git && \
    cd x264 && \
    ./configure --prefix=$PREFIX --enable-static --disable-shared --disable-opencl && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf x264

RUN git clone https://github.com/mstorsjo/fdk-aac.git && \
    cd fdk-aac && autoreconf -fiv && \
    ./configure --prefix=$PREFIX --enable-static --disable-shared && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf fdk-aac

RUN curl -L -o lame.tar.gz "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz" && \
    tar xzf lame.tar.gz && cd lame-3.100 && \
    ./configure --prefix=$PREFIX --enable-static --disable-shared --enable-nasm && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf lame-3.100 lame.tar.gz

RUN curl -L -o opus.tar.gz "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz" && \
    tar xzf opus.tar.gz && cd opus-1.5.2 && \
    ./configure --prefix=$PREFIX --enable-static --disable-shared && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf opus-1.5.2 opus.tar.gz

RUN curl -L -o vorbis.tar.gz "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz" && \
    tar xzf vorbis.tar.gz && cd libvorbis-1.3.7 && \
    ./configure --prefix=$PREFIX --enable-static --disable-shared && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf libvorbis-1.3.7 vorbis.tar.gz

RUN git clone https://chromium.googlesource.com/webm/libvpx.git && \
    cd libvpx && \
    ./configure --prefix=$PREFIX --enable-static --disable-shared \
                --disable-examples --disable-unit-tests \
                --enable-vp9-highbitdepth && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf libvpx

# 4) Finally, compile FFmpeg itself with all the static flags + NVENC/CUDA enabled.
#    We disable every optional I/O device (SDL2, sndio, X11, Xv, etc.) so there are no
#    unexpected hooks into host libraries.
RUN git clone --depth 1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git && \
    cd FFmpeg && \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure \
      --prefix=$PREFIX \
      --pkg-config-flags="--static" \
      --extra-cflags="-I/usr/local/cuda/include -I$PREFIX/include" \
      --extra-ldflags="-L/usr/local/cuda/lib64 -L$PREFIX/lib -static -Bstatic" \
      --extra-libs="-lpthread -lm -lz" \
      --enable-cuda --enable-cuvid --enable-nvenc \
      --enable-nonfree --enable-gpl --enable-postproc \
      --enable-libx264 --enable-libfdk-aac \
      --enable-libvpx --enable-libopus --enable-libmp3lame --enable-libvorbis \
      --enable-static --disable-shared \
      --disable-sdl2 --disable-sndio \
      --disable-libxcb \
      --disable-indev=x11grab \
      --disable-outdev=xv \
      --disable-devices --disable-opengl && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf FFmpeg

# 5) Clean up all build sources to keep the image small
RUN rm -rf $BUILD_DIR


###############################################################################
# Stage 2 – runtime: CUDA 11.8 + n8n + Whisper + Puppeteer + Chrome
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive

# keep environment for Chrome, Puppeteer, Whisper, and CUDA
ENV HOME=/home/node \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu \
    TZ=Australia/Brisbane \
    PIP_ROOT_USER_ACTION=ignore

# 1) Yank NVIDIA’s ffmpeg/ffprobe so $PATH picks /usr/local/bin/ffmpeg
RUN rm -f /usr/local/nvidia/bin/ffmpeg /usr/local/nvidia/bin/ffprobe || true

# 2) Install Chrome-support libs *and* the compatibility libraries for sndio & libva
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
      libgcc1 libstdc++6 libnvidia-egl-gbm1 libSDL2-2.0-0 \
      libsndio7.0 libxv1 && \
    # add Google Chrome repo and install
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" \
         > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable && \
    rm -rf /var/lib/apt/lists/*

# 3) Symlink Ubuntu’s sndio7.0 → sndio6.1 & libva2 → libva1 etc so NVIDIA libs load cleanly
RUN ln -s /usr/lib/x86_64-linux-gnu/libsndio.so.7.0   /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && \
    ln -s /usr/lib/x86_64-linux-gnu/libva.so.2        /usr/lib/x86_64-linux-gnu/libva.so.1 && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-drm.so.2    /usr/lib/x86_64-linux-gnu/libva-drm.so.1 && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-x11.so.2    /usr/lib/x86_64-linux-gnu/libva-x11.so.1 && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-wayland.so.2/ \
           /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

# 4) Prevent NVIDIA GBM stubs from crashing Chromium
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# 5) Create non-root node user
RUN groupadd -r node && \
    useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && \
    mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" && \
    chown -R node:node "$HOME"

# 6) Copy in our static FFmpeg (all deps baked in)
COPY --from=ffmpeg-builder /usr/local /usr/local

# 7) Install Node.js, n8n & Puppeteer globally (fix caching perms for node user)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    HOME=/root npm install -g --unsafe-perm \
      n8n@1.104.1 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 && \
    npm cache clean --force && \
    chown -R node:node /home/node/.npm && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 8) Download Puppeteer’s bundled Chrome as node user
USER node
RUN npx puppeteer@24.15.0 browsers install chrome
USER root

# 9) Install Whisper + Torch (CUDA) wheels
RUN python3.10 -m pip install --upgrade pip && \
    python3.10 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 && \
    python3.10 -m pip install --no-cache-dir git+https://github.com/openai/whisper.git

# 10) Pre-download the tiny Whisper model
RUN mkdir -p "$WHISPER_MODEL_PATH" && \
    python3.10 -c "import whisper; whisper.load_model('tiny', download_root='$WHISPER_MODEL_PATH')"

# 11) FFmpeg sanity check: should show our /usr/local/bin/ffmpeg,
#     no “not found” for sndio/libva, and list “cuda” under hwaccels.
RUN which ffmpeg && \
    ldd /usr/local/bin/ffmpeg | grep -E 'sndio|libva' || true && \
    ffmpeg -hide_banner -hwaccels | grep cuda

# 12) Healthcheck & final entry
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail http://localhost:5678/healthz || exit 1

USER node
WORKDIR $HOME

EXPOSE 5678
ENTRYPOINT ["tini","--","n8n"]
CMD []
