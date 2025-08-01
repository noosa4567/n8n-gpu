syntax=docker/dockerfile:1
###############################################################################
Stage 1 ─ build a static, CUDA/NVENC-enabled FFmpeg (no runtime .so libs)
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder
Make apt noninteractive, set install prefix and build directory, ensure CUDA in PATH
ENV DEBIAN_FRONTEND=noninteractive 

PREFIX=/usr/local 

BUILD_DIR=/tmp/ffmpeg_sources 

PATH=/usr/local/cuda/bin:$PATH
1) Install only build-time headers/tools to compile dependencies statically
- Avoid pulling in .so files that could pollute our static build
RUN apt-get update && 

apt-get install -y --no-install-recommends 

build-essential git pkg-config yasm cmake libtool nasm curl unzip 

autoconf automake libnuma-dev zlib1g-dev libfreetype6-dev 

libfontconfig-dev libharfbuzz-dev libogg-dev && 

rm -rf /var/lib/apt/lists/* && 

mkdir -p "$BUILD_DIR"
WORKDIR "$BUILD_DIR"
2) NVIDIA NVENC headers (required for --enable-nvenc)
RUN git clone --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git && 

make -C nv-codec-headers -j"$(nproc)" install && 

rm -rf nv-codec-headers
3) Build external codecs as static archives:
- x264, fdk-aac, lame, opus, vorbis, vpx
ensures ffmpeg links only to .a, no .so at runtime
RUN git clone https://code.videolan.org/videolan/x264.git && 

cd x264 && 

./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-opencl && 

make -j"$(nproc)" && make install && 

cd .. && rm -rf x264
RUN git clone https://github.com/mstorsjo/fdk-aac.git && 

cd fdk-aac && autoreconf -fiv && 

./configure --prefix="$PREFIX" --enable-static --disable-shared && 

make -j"$(nproc)" && make install && 

cd .. && rm -rf fdk-aac
RUN curl -fsSL https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz -o lame.tar.gz && 

tar xzf lame.tar.gz && cd lame-3.100 && 

./configure --prefix="$PREFIX" --enable-static --disable-shared --enable-nasm && 

make -j"$(nproc)" && make install && 

cd .. && rm -rf lame-3.100 lame.tar.gz
RUN curl -fsSL https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz -o opus.tar.gz && 

tar xzf opus.tar.gz && cd opus-1.5.2 && 

./configure --prefix="$PREFIX" --enable-static --disable-shared && 

make -j"$(nproc)" && make install && 

cd .. && rm -rf opus-1.5.2 opus.tar.gz
RUN curl -fsSL https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz -o vorbis.tar.gz && 

tar xzf vorbis.tar.gz && cd libvorbis-1.3.7 && 

./configure --prefix="$PREFIX" --enable-static --disable-shared && 

make -j"$(nproc)" && make install && 

cd .. && rm -rf libvorbis-1.3.7 vorbis.tar.gz
RUN git clone https://chromium.googlesource.com/webm/libvpx.git && 

cd libvpx && 

./configure --prefix="$PREFIX" 

--enable-static --disable-shared 

--disable-examples --disable-unit-tests 

--enable-vp9-highbitdepth && 

make -j"$(nproc)" && make install && 

cd .. && rm -rf libvpx
4) Configure & build FFmpeg itself, fully static + CUDA/NVENC
- disable sdl2, sndio, X11 grab, Xv, OpenGL to avoid pulling host .so
RUN git clone --depth 1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git && 

cd FFmpeg && 

PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure 

--prefix="$PREFIX" 

--pkg-config-flags="--static" 

--extra-cflags="-I/usr/local/cuda/include -I$PREFIX/include" 

--extra-ldflags="-L/usr/local/cuda/lib64 -L$PREFIX/lib -static -Bstatic" 

--extra-libs="-lpthread -lm -lz" 

--enable-cuda --enable-cuvid --enable-nvenc 

--enable-nonfree --enable-gpl --enable-postproc 

--enable-libx264 --enable-libfdk-aac 

--enable-libvpx --enable-libopus --enable-libmp3lame --enable-libvorbis 

--enable-static --disable-shared 

--disable-sdl2 --disable-sndio 

--disable-libxcb --disable-indev=x11grab --disable-outdev=xv 

--disable-opengl && 

make -j"$(nproc)" && make install && 

cd .. && rm -rf FFmpeg
5) Clean up build directory (slim down image)
RUN rm -rf "$BUILD_DIR"
###############################################################################
Stage 2 ─ runtime: CUDA 11.8 + n8n + Whisper + Puppeteer + Chrome
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04
ARG DEBIAN_FRONTEND=noninteractive
Ensure:
- our static /usr/local/bin ffmpeg still wins,
- and the host’s NVIDIA driver libs (in /usr/local/nvidia) remain on LD_LIBRARY_PATH
ENV HOME=/home/node 

WHISPER_MODEL_PATH=/usr/local/lib/whisper_models 

PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer 

PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable 

LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:/usr/local/nvidia/lib64:/usr/local/nvidia/lib:$LD_LIBRARY_PATH 

TZ=Australia/Brisbane 

PIP_ROOT_USER_ACTION=ignore 

PATH=/usr/local/bin:$PATH
1) Install base OS libs, Chrome deps (lsb-release & xdg-utils needed by Chrome)
RUN apt-get update && 

apt-get install -y --no-install-recommends 

software-properties-common ca-certificates curl git wget gnupg tini 

python3.10 python3.10-venv python3.10-dev python3-pip 

libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 

libatk-bridge2.0-0 libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 

libxcomposite1 libxrandr2 libxdamage1 libx11-xcb1 libva2 

libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 libxcb-shape0 

libxcb-shm0 libxcb-xfixes0 libxcb-render0 libxrender1 libxtst6 

libxi6 libxcursor1 libcairo2 libcups2 libdbus-1-3 libexpat1 

libfontconfig1 libegl1-mesa libgl1-mesa-dri libpangocairo-1.0-0 

libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 

fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 

libgcc1 libstdc++6 libnvidia-egl-gbm1 libSDL2-2.0-0 libsndio7.0 libxv1 && 

curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && 

echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" \

/etc/apt/sources.list.d/google-chrome.list && 

apt-get update && apt-get install -y --no-install-recommends google-chrome-stable && 

rm -rf /var/lib/apt/lists/*

2) Legacy soname symlinks for NVENC driver blobs (sndio & VA-API)
RUN ln -sf /usr/lib/x86_64-linux-gnu/libsndio.so.7.0   /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && 

ln -sf /usr/lib/x86_64-linux-gnu/libva.so.2        /usr/lib/x86_64-linux-gnu/libva.so.1 && 

ln -sf /usr/lib/x86_64-linux-gnu/libva-drm.so.2    /usr/lib/x86_64-linux-gnu/libva-drm.so.1 && 

ln -sf /usr/lib/x86_64-linux-gnu/libva-x11.so.2    /usr/lib/x86_64-linux-gnu/libva-x11.so.1 && 

ln -sf /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1
3) Remove NVIDIA GBM stubs that crash headless Chrome
RUN rm -rf /usr/share/egl/egl_external_platform.d/nvidia 

/usr/local/nvidia/lib*/gbm 

/usr/lib/x86_64-linux-gnu/nvidiagbm*
4) Create non-root 'node' user and prepare cache dirs for n8n & Puppeteer
RUN groupadd -r node && 

useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node && 

mkdir -p "$HOME/.n8n" "$PUPPETEER_CACHE_DIR" && 

chown -R node:node "$HOME"
5) Copy static FFmpeg & FFprobe, then symlink into /usr/local/nvidia/bin
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe
RUN mkdir -p /usr/local/nvidia/bin && 

ln -sf /usr/local/bin/ffmpeg  /usr/local/nvidia/bin/ffmpeg && 

ln -sf /usr/local/bin/ffprobe /usr/local/nvidia/bin/ffprobe
6) Install Node.js 20, n8n & Puppeteer globally, fix npm cache perms
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && 

apt-get update && apt-get install -y --no-install-recommends nodejs && 

npm install -g --unsafe-perm n8n@1.104.1 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 && 

npm cache clean --force && chown -R node:node /home/node/.npm && 

apt-get clean && rm -rf /var/lib/apt/lists/*
7) As node, install Puppeteer’s managed Chrome
USER node
RUN npx puppeteer@24.15.0 browsers install chrome
USER root
8) Install Whisper + Torch (CUDA wheels) & satisfy new whisper deps
RUN python3.10 -m pip install --upgrade pip && 

python3.10 -m pip install --no-cache-dir 

torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 && 

python3.10 -m pip install --no-cache-dir numba tiktoken && 

python3.10 -m pip install --no-cache-dir git+https://github.com/openai/whisper.git
9) Pre-download Whisper “tiny” model via a temp script (no heredoc!)
RUN mkdir -p "$WHISPER_MODEL_PATH" && 

echo "import whisper, os; whisper.load_model('tiny', download_root=os.environ['WHISPER_MODEL_PATH'])" \

/tmp/preload_whisper.py && 

python3.10 /tmp/preload_whisper.py && 

rm /tmp/preload_whisper.py

10) Sanity-check FFmpeg: must be static and list CUDA hwaccels
RUN which -a ffmpeg && 

ldd /usr/local/bin/ffmpeg | grep -E 'not a dynamic executable|sndio|libva' || true && 

ffmpeg -hide_banner -hwaccels | grep cuda
11) Tiny shim wrapper to re re-order PATH after NVIDIA hook, re-prepending /usr/local/bin
RUN printf '%s\n' 

'#!/bin/sh' 

'export PATH=/usr/local/bin:$PATH' 

'exec "$@"' \

/usr/local/bin/n8n-wrapper && 

chmod +x /usr/local/bin/n8n-wrapper

12) Healthcheck & final entrypoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 

CMD curl --fail http://localhost:5678/healthz || exit 1
USER node
WORKDIR $HOME
EXPOSE 5678
ENTRYPOINT ["tini","--","/usr/local/bin/n8n-wrapper","n8n"]
CMD []
