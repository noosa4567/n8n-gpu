###############################################################################
# Stage 1 – GPU-enabled FFmpeg (tiny)
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2 – Runtime with CUDA 11.8, PyTorch, n8n, Whisper & FFmpeg
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG  DEBIAN_FRONTEND=noninteractive
ENV  TZ=Australia/Brisbane \
     LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
     WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 1 ) non-root “node” user
RUN groupadd -r node \
 && useradd  -r -g node -m -d /home/node -s /bin/sh node \
 && mkdir -p /home/node/.n8n \
 && chown  -R node:node /home/node/.n8n

# 2 ) tini + minimal libs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        tini python3-pip \
        libsndio7.0 libasound2 \
        libva2 libva-{x11-2,drm2,wayland2} \
        libvdpau1 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 3 ) GPU-enabled FFmpeg
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/

# 4 ) quick sanity check
RUN LD_LIBRARY_PATH=$LD_LIBRARY_PATH ldd /usr/local/bin/ffmpeg | grep -q "not found" \
      && (echo "⚠️ missing libs" >&2 && exit 1) || echo "✅ FFmpeg OK"

# 5 ) Node.js 20 + n8n
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && rm -rf /var/lib/apt/lists/*

# 6 ) Whisper + model
RUN pip3 install --no-cache-dir tiktoken openai-whisper \
 && mkdir -p $WHISPER_MODEL_PATH \
 && python3 - << 'PY' \
import whisper, os; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH']); \
PY \
 && chown -R node:node $WHISPER_MODEL_PATH

# 7 ) Shared data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data/shared

USER node
EXPOSE 5678

# Health-check (optional but recommended)
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD curl -f http://localhost:5678/healthz || exit 1

ENTRYPOINT ["tini","--","n8n"]
CMD []                       # default server mode
