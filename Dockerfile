###############################################################################
# Stage 1 • pre-built GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 • runtime layer: CUDA 11.8 PyTorch 2.1, n8n, Whisper, FFmpeg
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG  DEBIAN_FRONTEND=noninteractive
ENV  TZ=Australia/Brisbane \
     LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
     WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 1) non-root user (mirrors official image)
RUN groupadd -r node \
 && useradd  -r -g node -m -d /home/node -s /bin/bash node \
 && mkdir -p /home/node/.n8n \
 && chown -R node:node /home/node/.n8n

# 2) tiny runtime deps + certs + curl
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip \
      libsndio7.0 libasound2 \
      libva2  libva-x11-2  libva-drm2  libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 3) FFmpeg (GPU-enabled) — binaries + libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/

# 4) Node.js 20  + n8n CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm  install -g n8n \
 && npm  cache clean --force \
 && rm   -rf /var/lib/apt/lists/*

# 5) copy n8n’s official entrypoint (keeps init logic intact)
COPY --from=n8nio/n8n:latest /docker-entrypoint.sh /docker-entrypoint.sh
RUN  chmod +x /docker-entrypoint.sh

# 6) Whisper + base model  — **fixed heredoc terminator**
RUN pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 - << 'PY' \
import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH']) \
PY \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

# 7) shared volumes
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data/shared

# 8) verify FFmpeg linkage (fails build if missing libs)
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️  unresolved FFmpeg libs" >&2 && exit 1) || echo "✅ FFmpeg libs OK"

USER node
EXPOSE 5678

# Health-check (optional but recommended)
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD curl -f http://localhost:5678/healthz || exit 1

ENTRYPOINT ["tini","--","n8n"]
CMD []                       # default server mode
