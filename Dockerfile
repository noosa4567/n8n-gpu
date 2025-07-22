###############################################################################
# Stage 1  •  prebuilt GPU-accelerated FFmpeg (CUDA 11.8)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2  •  Runtime: CUDA 11.8 PyTorch, n8n, Whisper & FFmpeg
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG  DEBIAN_FRONTEND=noninteractive
ENV  TZ=Australia/Brisbane \
     LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 \
     WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 1) Create non-root "node" user (mirrors official n8n image)
RUN groupadd -r node \
 && useradd -r -g node -m -d /home/node -s /bin/bash node \
 && mkdir -p /home/node/.n8n \
 && chown -R node:node /home/node/.n8n

# 2) Minimal runtime deps + tini
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini python3-pip \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy GPU-enabled FFmpeg
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/

# 4) Install Node.js 20 & n8n CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

# 5) Preserve official n8n entrypoint logic for keygen etc.
COPY --from=n8nio/n8n:latest /docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# 6) Install Whisper + tokenizer
RUN pip3 install --no-cache-dir tiktoken openai-whisper

# 7) Pre-download Whisper "base" model
RUN mkdir -p "${WHISPER_MODEL_PATH}"
RUN python3 << 'PY'
import os, whisper
whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])
PY
RUN chown -R node:node "${WHISPER_MODEL_PATH}"

# 8) Prepare shared data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data/shared

# 9) Verify FFmpeg linkage early
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "⚠️  unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

# 10) Switch to non-root
USER node

EXPOSE 5678

# 11) Start n8n exactly as upstream does but via tini
ENTRYPOINT ["tini","--","n8n"]
CMD []
