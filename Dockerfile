# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 ─ build a *static* FFmpeg (NVENC enabled, no host libs required)
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ENV  DEBIAN_FRONTEND=noninteractive \
     PREFIX=/usr/local \
     BUILD_DIR=/tmp/ffmpeg_sources \
     PATH=/usr/local/cuda/bin:$PATH

# ─────────────────────────────────────────────────────────────────────────────
# 1)  Build-time tools + ONLY the headers we need
# ─────────────────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git pkg-config yasm cmake libtool nasm curl unzip \
      autoconf automake libnuma-dev zlib1g-dev \
      libfreetype6-dev libfontconfig-dev libharfbuzz-dev libogg-dev \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p "$BUILD_DIR"

WORKDIR "$BUILD_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# 2)  NVENC headers
# ─────────────────────────────────────────────────────────────────────────────
RUN git clone --branch n11.1.5.3 https://github.com/FFmpeg/nv-codec-headers.git  \
 && make -C nv-codec-headers -j"$(nproc)" install \
 && rm -rf nv-codec-headers

# ─────────────────────────────────────────────────────────────────────────────
# 3)  Build every external codec statically
# ─────────────────────────────────────────────────────────────────────────────
# x264
RUN git clone https://code.videolan.org/videolan/x264.git    \
 && cd x264                                                  \
 && ./configure --prefix=$PREFIX --enable-static --disable-shared --disable-opencl \
 && make -j"$(nproc)" && make install                       \
 && cd .. && rm -rf x264

# fdk-aac
RUN git clone https://github.com/mstorsjo/fdk-aac.git        \
 && cd fdk-aac && autoreconf -fiv                            \
 && ./configure --prefix=$PREFIX --enable-static --disable-shared \
 && make -j"$(nproc)" && make install                       \
 && cd .. && rm -rf fdk-aac

# lame
RUN curl -L -o lame.tar.gz https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz \
 && tar xzf lame.tar.gz && cd lame-3.100                      \
 && ./configure --prefix=$PREFIX --enable-static --disable-shared --enable-nasm \
 && make -j"$(nproc)" && make install                         \
 && cd .. && rm -rf lame-3.100 lame.tar.gz

# opus
RUN curl -L -o opus.tar.gz https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz \
 && tar xzf opus.tar.gz && cd opus-1.5.2                      \
 && ./configure --prefix=$PREFIX --enable-static --disable-shared \
 && make -j"$(nproc)" && make install                         \
 && cd .. && rm -rf opus-1.5.2 opus.tar.gz

# vorbis
RUN curl -L -o vorbis.tar.gz https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz \
 && tar xzf vorbis.tar.gz && cd libvorbis-1.3.7              \
 && ./configure --prefix=$PREFIX --enable-static --disable-shared \
 && make -j"$(nproc)" && make install                         \
 && cd .. && rm -rf libvorbis-1.3.7 vorbis.tar.gz

# libvpx
RUN git clone https://chromium.googlesource.com/webm/libvpx.git \
 && cd libvpx                                                   \
 && ./configure --prefix=$PREFIX --enable-static --disable-shared \
                --disable-examples --disable-unit-tests --enable-vp9-highbitdepth \
 && make -j"$(nproc)" && make install                         \
 && cd .. && rm -rf libvpx

# ─────────────────────────────────────────────────────────────────────────────
# 4)  Build FFmpeg itself  (fully static, NVENC enabled, no X11 / Sndio)
# ─────────────────────────────────────────────────────────────────────────────
RUN git clone --depth 1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git \
 && cd FFmpeg                                                              \
 && PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure                    \
      --prefix="$PREFIX"                                                   \
      --pkg-config-flags="--static"                                        \
      --extra-cflags="-I/usr/local/cuda/include -I$PREFIX/include"         \
      --extra-ldflags="-L/usr/local/cuda/lib64 -L$PREFIX/lib -static -Bstatic" \
      --extra-libs="-lpthread -lm -lz"                                     \
      --enable-cuda --enable-cuvid --enable-nvenc                          \
      --enable-nonfree --enable-gpl --enable-postproc                      \
      --enable-libx264 --enable-libfdk-aac                                 \
      --enable-libvpx --enable-libopus --enable-libmp3lame --enable-libvorbis \
      --enable-static --disable-shared                                     \
      --disable-sdl2 --disable-sndio                                       \
      --disable-libxcb --disable-indev=x11grab --disable-outdev=xv         \
      --disable-devices --disable-opengl                                   \
 && make -j"$(nproc)" && make install                                      \
 && cd .. && rm -rf FFmpeg

# ─────────────────────────────────────────────────────────────────────────────
# 5)  Clean build dirs
# ─────────────────────────────────────────────────────────────────────────────
RUN rm -rf "$BUILD_DIR"

###############################################################################
# Stage 2 ─ runtime: CUDA 11.8 + n8n + Whisper + Puppeteer + Chrome
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG  DEBIAN_FRONTEND=noninteractive
ENV  HOME=/home/node \
     WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
     PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
     PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable \
     LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu \
     TZ=Australia/Brisbane \
     PIP_ROOT_USER_ACTION=ignore

# ─────────────────────────────────────────────────────────────────────────────
# 1)  Runtime libs for Chrome & Puppeteer
# ─────────────────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      software-properties-common ca-certificates curl git wget gnupg tini \
      python3.10 python3.10-venv python3.10-dev python3-pip \
      libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 libatk-bridge2.0-0 \
      libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 libxcomposite1 libxrandr2 \
      libxdamage1 libx11-xcb1 libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      libxrender1 libxtst6 libxi6 libxcursor1 libcairo2 libcups2 libdbus-1-3 \
      libexpat1 libfontconfig1 libegl1-mesa libgl1-mesa-dri libpangocairo-1.0-0 \
      libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 libfreetype6 \
      libatspi2.0-0 libSDL2-2.0-0 libsndio7.0 libxv1 libgcc1 libstdc++6 \
      libnvidia-egl-gbm1 fonts-liberation \
 && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - \
 && echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" \
       > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

# — Legacy-soname symlinks needed by NVENC driver blobs —
RUN ln -s /usr/lib/x86_64-linux-gnu/libsndio.so.7.0    /usr/lib/x86_64-linux-gnu/libsndio.so.6.1  && \
    ln -s /usr/lib/x86_64-linux-gnu/libva.so.2         /usr/lib/x86_64-linux-gnu/libva.so.1       && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-drm.so.2     /usr/lib/x86_64-linux-gnu/libva-drm.so.1   && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-x11.so.2     /usr/lib/x86_64-linux-gnu/libva-x11.so.1   && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

# Delete NVIDIA GBM stubs that crash Chromium
RUN rm -rf /usr/share/egl/egl_external_platform.d/*nvidia* \
           /usr/local/nvidia/lib*/*gbm* \
           /usr/lib/x86_64-linux-gnu/*nvidia*gbm*

# ─────────────────────────────────────────────────────────────────────────────
# 2)  Copy the *static* FFmpeg we built
# ─────────────────────────────────────────────────────────────────────────────
COPY --from=ffmpeg-builder /usr/local /usr/local

# Overwrite NVIDIA wrappers with symlinks to our static build
RUN mkdir -p /usr/local/nvidia/bin \
 && ln -sf /usr/local/bin/ffmpeg  /usr/local/nvidia/bin/ffmpeg \
 && ln -sf /usr/local/bin/ffprobe /usr/local/nvidia/bin/ffprobe

# ─────────────────────────────────────────────────────────────────────────────
# 3)  Node.js 20 + n8n + Puppeteer
# ─────────────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y nodejs \
 && npm i -g --unsafe-perm \
      n8n@1.104.1 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 \
 && npm cache clean --force \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# 4)  Create non-root user (Chromium sandbox requires it)
# ─────────────────────────────────────────────────────────────────────────────
RUN groupadd -r node && useradd -r -g node -G video -u 999 \
            -m -d "$HOME" -s /bin/bash node
USER node

# Download Puppeteer’s managed Chrome into $PUPPETEER_CACHE_DIR
RUN npx puppeteer@24.15.0 browsers install chrome
USER root

# ─────────────────────────────────────────────────────────────────────────────
# 5)  Whisper + Torch (CUDA 11.8 wheels)
# ─────────────────────────────────────────────────────────────────────────────
RUN python3.10 -m pip install --no-cache-dir --upgrade pip \
 && python3.10 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
      git+https://github.com/openai/whisper.git

# Pre-download Whisper “tiny” model
RUN mkdir -p "$WHISPER_MODEL_PATH" \
 && python3.10 - <<'PY' \
import whisper, os; whisper.load_model("tiny", download_root=os.environ["WHISPER_MODEL_PATH"])
PY

# ─────────────────────────────────────────────────────────────────────────────
# 6)  Quick sanity test
# ─────────────────────────────────────────────────────────────────────────────
RUN which -a ffmpeg \
 && ldd /usr/local/bin/ffmpeg | grep -E 'sndio|libva' || true \
 && ffmpeg -hide_banner -hwaccels | grep cuda

# ─────────────────────────────────────────────────────────────────────────────
# 7)  Healthcheck & launch
# ─────────────────────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
  CMD curl -fs http://localhost:5678/healthz || exit 1

USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini","--","n8n"]
CMD []

###############################################################################
# Notes for future maintainers
#
# • **Puppeteer / Chrome**
#   – Chrome needs a long list of X11 / GTK / VA-API libs even in headless
#     mode.  The list above is the minimal set that works inside the CUDA image.
#   – NVIDIA’s GBM stubs crash Chromium; we simply delete them.
#
# • **FFmpeg**
#   – Every external codec is compiled static, FFmpeg is linked -static.
#   – The binary itself has **no** DT_NEEDED entries, but NVENC is dl-opened
#     at runtime and expects legacy sonames (libsndio.so.6.1, libva.so.1, …);
#     harmless symlinks satisfy those.
#   – `/usr/local/nvidia/bin` is always prepended to `$PATH` by CUDA’s shell
#     scripts. We overwrite the wrappers there with symlinks to our static
#     build so the correct binary wins in *every* context.
#
# • **GPU acceleration**
#   – CUDA & NVENC shared libraries live in `/usr/local/cuda/lib64` and are
#     untouched, so both Whisper (torch-CUDA) *and* FFmpeg retain hardware
#     acceleration.
###############################################################################
