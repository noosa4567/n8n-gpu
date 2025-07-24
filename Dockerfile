###############################################################################
# 1) Grab NVIDIA-accelerated FFmpeg build (with NVENC) 
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# 2) Runtime: Ubuntu 22.04 + CUDA 11.8/cuDNN8
###############################################################################
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/node \
    TZ=Australia/Brisbane

# 3) System dependencies: tini, git, xz-utils, python3-pip, Puppeteer libs
RUN apt-get update && apt-get install -y --no-install-recommends \
      tini \
      git \
      xz-utils \
      curl \
      ca-certificates \
      python3 \
      python3-pip \
      libnss3 \
      libxss1 \
      libasound2 \
      libcups2 \
      libatk-bridge2.0-0 \
      libgtk-3-0 \
      libxcomposite1 \
      libxdamage1 \
      libgbm1 \
      libpangocairo-1.0-0 \
      libpango-1.0-0 \
      libxrandr2 \
      libxrender1 \
      libxi6 \
      libxtst6 \
      libxcursor1 \
      fonts-liberation \
      libfribidi0 \
      libharfbuzz0b \
      libthai0 \
      libdatrie1 \
 && rm -rf /var/lib/apt/lists/*

# 4) Copy GPU-enabled ffmpeg + libs from the build stage
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 5) Node.js 20 + npm (NodeSource), leave git present
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# 6) Globally install n8n, Puppeteer (bundled Chrome), community node
RUN npm install -g n8n@latest \
                  puppeteer@23.11.1 \
                  n8n-nodes-puppeteer \
        --legacy-peer-deps \
 && npm cache clean --force

# 7) Whisper + PyTorch (GPU) + tiktoken + pre-download “base” model
RUN pip3 install --no-cache-dir \
      torch==2.1.0+cu118 \
      --index-url https://download.pytorch.org/whl/cu118 \
    && pip3 install --no-cache-dir \
      openai-whisper \
      tiktoken \
    && python3 -c "import whisper; whisper.load_model('base')" \
    && rm -rf /root/.cache

# 8) Create non-root user + soak up all runtime dirs
RUN useradd -m -u 1000 -s /bin/bash node \
 && mkdir -p \
      $HOME/.n8n \
      $HOME/.cache/n8n/public \
      /data/shared/videos \
      /data/shared/audio \
      /data/shared/transcripts \
 && chown -R node:node \
      $HOME \
      /data/shared

# 9) Healthcheck on n8n
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 10) Drop to non-root, expose port, launch under tini
USER node
WORKDIR /home/node
EXPOSE 5678
ENTRYPOINT ["tini","--","n8n"]
CMD []
