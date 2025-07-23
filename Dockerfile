###############################################################################
# Stage 1  •  pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2  •  Runtime: CUDA 11.8 PyTorch, n8n, Whisper & FFmpeg
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    NODE_PATH=/home/node/.n8n/node_modules

# 1) Create non-root "node" user and n8n config dir
RUN groupadd -r node \
 && useradd -r -g node -m -d /home/node -s /bin/bash node \
 && mkdir -p /home/node/.n8n \
 && chown -R node:node /home/node/.n8n

# 2) Install tini, pip, git & minimal runtime libs (plus XCB for FFmpeg)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip git \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy FFmpeg binaries & libs, then update linker cache
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN ldconfig

# 4) Install Node.js 20 & pinned n8n CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n@1.104.0 \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

# 5) Whisper + tokenizer + pre-download model (with retry)
RUN pip3 install --no-cache-dir tiktoken openai-whisper \
 && pip3 cache purge \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && (python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
     || (sleep 5 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])")) \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 6) Prepare shared data dirs (tight perms)
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data/shared \
 && chmod -R 770 /data/shared

# 7) Verify FFmpeg linkage at build time
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 8) Health-check
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:5678/healthz || exit 1

# 9) Switch to non-root for community-node install
USER node

# 10) Install Puppeteer & the Puppeteer community-node into ~/.n8n
RUN npm install --prefix /home/node/.n8n \
      puppeteer n8n-nodes-puppeteer --legacy-peer-deps

EXPOSE 5678

# 11) Launch n8n under tini
ENTRYPOINT ["tini","--","n8n"]
CMD []
