###############################################################################
# Stage 1: prebuilt GPU-accelerated FFmpeg
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2: runtime with CUDA 11.8 PyTorch, n8n, Whisper & FFmpeg
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 1) Create a non-root "node" user
RUN groupadd -r node \
 && useradd -r -g node -m -d /home/node -s /bin/bash node

# 2) Install minimal runtime deps + tini
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
       tini \
       python3-pip \
       libsndio7.0 libasound2 \
       libva2 libva-x11-2 libva-drm2 libva-wayland2 \
       libvdpau1 \
       curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 3) Bring in FFmpeg binaries & libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/

# 4) Install Node.js 20 and n8n
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && rm -rf /var/lib/apt/lists/*

# 5) Install Whisper + tiktoken
RUN pip3 install --no-cache-dir tiktoken openai-whisper

# 6) Pre-download the Whisper "base" model
RUN mkdir -p $WHISPER_MODEL_PATH
RUN python3 << 'PYCODE'
import whisper
whisper.load_model('base', download_root='/usr/local/lib/whisper_models')
PYCODE

# 7) Verify model and fix ownership
RUN ls -l $WHISPER_MODEL_PATH/base.pt \
    || (echo "⚠️ Whisper model missing!" >&2 && exit 1) \
 && chown -R node:node $WHISPER_MODEL_PATH

# 8) Prepare shared data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data/shared

# 9) Switch to non-root
USER node

ENTRYPOINT ["tini","--"]
CMD ["n8n","start"]
