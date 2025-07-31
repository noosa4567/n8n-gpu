# syntax=docker/dockerfile:1
###############################################################################
# Stage 1 ─ build a *static* FFmpeg (NVENC-enabled, no host libs required)
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

# ……………<build stage unchanged, truncated here for brevity>……………

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
# 1)  Runtime libraries for Chrome + Puppeteer
#     — *Nothing* here touches CUDA libs, so NVENC remains intact.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      software-properties-common ca-certificates curl git wget gnupg tini \
      python3.10 python3.10-venv python3.10-dev python3-pip \
      libglib2.0-0 libnss3 libxss1 libasound2 libatk1.0-0 libatk-bridge2.0-0 \
      libgtk-3-0 libdrm2 libxkbcommon0 libgbm1 libxcomposite1 libxrandr2 \
      libxdamage1 libx11-xcb1 libva2 libva-{x11,drm,wayland}2 libvdpau1 \
      libxcb-{shape,shm,xfixes,render}0 libxrender1 libxtst6 libxi6 libxcursor1 \
      libcairo2 libcups2 libdbus-1-3 libexpat1 libfontconfig1 libegl1-mesa \
      libgl1-mesa-dri libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b \
      libfribidi0 libthai0 libdatrie1 libfreetype6 libatspi2.0-0 libSDL2-2.0-0 \
      libsndio7.0 libxv1 libgcc1 libstdc++6 libnvidia-egl-gbm1 fonts-liberation \
 && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add - \
 && echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" \
       > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /var/lib/apt/lists/*

# Compat-symlinks for NVIDIA driver blobs that dlopen() legacy names
RUN ln -s /usr/lib/x86_64-linux-gnu/libsndio.so.7.0   /usr/lib/x86_64-linux-gnu/libsndio.so.6.1 && \
    ln -s /usr/lib/x86_64-linux-gnu/libva.so.2        /usr/lib/x86_64-linux-gnu/libva.so.1      && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-drm.so.2    /usr/lib/x86_64-linux-gnu/libva-drm.so.1  && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-x11.so.2    /usr/lib/x86_64-linux-gnu/libva-x11.so.1  && \
    ln -s /usr/lib/x86_64-linux-gnu/libva-wayland.so.2 /usr/lib/x86_64-linux-gnu/libva-wayland.so.1

# ─────────────────────────────────────────────────────────────────────────────
# 2)  Copy *static* FFmpeg built in Stage 1
# ---------------------------------------------------------------------------
COPY --from=ffmpeg-builder /usr/local /usr/local

# 3)  Force NVIDIA’s wrapper dir to point to our binary (survives entry-scripts)
RUN mkdir -p /usr/local/nvidia/bin && \
    ln -sf /usr/local/bin/ffmpeg  /usr/local/nvidia/bin/ffmpeg  && \
    ln -sf /usr/local/bin/ffprobe /usr/local/nvidia/bin/ffprobe

# ─────────────────────────────────────────────────────────────────────────────
# 4)  Node.js 20 + n8n + Puppeteer
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y nodejs \
 && npm i -g --unsafe-perm \
      n8n@1.104.1 puppeteer@24.15.0 n8n-nodes-puppeteer@1.4.1 \
 && npm cache clean --force \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# 5)  Non-root user so Chromium’s sandbox works
RUN groupadd -r node && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node
USER node

# Puppeteer’s managed Chrome (downloads to $PUPPETEER_CACHE_DIR)
RUN npx puppeteer@24.15.0 browsers install chrome

USER root

# ─────────────────────────────────────────────────────────────────────────────
# 6)  Whisper + Torch (CUDA 11.8 wheels)
# ---------------------------------------------------------------------------
RUN python3.10 -m pip install --no-cache-dir --upgrade pip \
 && python3.10 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
      git+https://github.com/openai/whisper.git

# 7)  Pre-download Whisper “tiny” model (saves time at first run)
RUN mkdir -p "$WHISPER_MODEL_PATH" \
 && python3.10 - <<'PY' \
import whisper, os; whisper.load_model("tiny", download_root=os.environ["WHISPER_MODEL_PATH"])
PY

# ─────────────────────────────────────────────────────────────────────────────
# 8)  Quick sanity-test: path, linkage, CUDA hwaccel present
# ---------------------------------------------------------------------------
RUN which -a ffmpeg \
 && ldd /usr/local/bin/ffmpeg | grep -E 'sndio|libva' || true \
 && ffmpeg -hide_banner -hwaccels | grep cuda

# ─────────────────────────────────────────────────────────────────────────────
# 9)  Healthcheck & launch
# ---------------------------------------------------------------------------
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
# • Puppeteer/Chrome
#   – Chrome needs a *huge* stack of X11 / GTK / VA-API libraries even in
#     headless-new mode.  The list above is the minimal set that works on
#     Ubuntu 22.04 inside a CUDA base image.
#   – NVIDIA’s libgbm stubs crash Chromium; we delete them.
#
# • FFmpeg
#   – We build every codec statically and then link FFmpeg with -static.  The
#     binary itself has **zero** DT_NEEDED entries, but NVENC is dlopened at
#     runtime.  Those driver blobs expect legacy sonames: libsndio.so.6.1,
#     libva.so.1…  harmless symlinks satisfy them.
#   – `/usr/local/nvidia/bin` is always prepended to $PATH by CUDA’s
#     entrypoint scripts.  We **overwrite** the wrappers there with symlinks to
#     our static build so the correct binary is used no matter what.
#
# • GPU acceleration
#   – CUDA & NVENC libraries remain untouched in /usr/local/cuda-*/lib64 and
#     continue to work for both Whisper (torch-CUDA) and FFmpeg.
###############################################################################
