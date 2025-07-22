###############################################################################
# Stage 1 • Pre-built, GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • Runtime: CUDA 11.8 PyTorch 2.1, n8n, Puppeteer, Whisper & FFmpeg
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive

ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    NODE_PATH=/usr/lib/node_modules

# 1) non-root 'node' user & n8n config dir
RUN groupadd -r node \
 && useradd -r -g node -m -d /home/node -s /bin/bash node \
 && mkdir -p /home/node/.n8n \
 && chown -R node:node /home/node/.n8n

# 2) tini, pip & minimal libs (plus Puppeteer deps)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      fonts-liberation libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 \
      libcups2 libdbus-1-3 libdrm2 libgbm1 libexpat1 libfontconfig1 \
      libgtk-3-0 libpango-1.0-0 libpangocairo-1.0-0 libxcomposite1 \
      libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 \
      libxrender1 libxtst6 lsb-release wget xdg-utils git \
      libxss1 libgconf-2-4 \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy FFmpeg from stage 1 & update linker cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node.js 20 + n8n (isolated)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n@1.104.0 \
 && rm -rf /var/lib/apt/lists/*

# 5) Inside n8n’s own folder, add Puppeteer + community node
RUN cd /usr/lib/node_modules/n8n \
 && npm install puppeteer n8n-nodes-puppeteer --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node /usr/lib/node_modules/n8n

# 6) Whisper + tokenizer & model download
RUN pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 7) Data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# 8) FFmpeg linkage check
RUN ldd /usr/local/bin/ffmpeg \
    | grep -q "not found" \
      && (echo "⚠️  unresolved FFmpeg libs" >&2 && exit 1) \
      || echo "✅ FFmpeg libs OK"

# 9) Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 10) non-root n8n launch
USER node
EXPOSE 5678
ENTRYPOINT ["tini","--","n8n"]
CMD []
