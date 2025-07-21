# Stage 1: grab prebuilt FFmpeg with NVENC/NVDEC
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

# Stage 2: runtime with Node.js (n8n), Whisper, and GPU-accelerated FFmpeg
FROM node:20-slim
ARG DEBIAN_FRONTEND=noninteractive

# Timezone and library path
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# Create non-root user
RUN groupadd -r node && useradd -r -g node node

# Install minimal runtime deps + tini
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       tini \
       python3 python3-pip \
       libsndio7.0 libasound2 \
       libva2 libva-x11-2 libva-drm2 libva-wayland2 \
       libvdpau1 \
       curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Copy FFmpeg binaries & libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/

# Install Whisper and its tokenizer
RUN pip3 install --no-cache-dir tiktoken openai-whisper

# Pre-download the Whisper “base” model
RUN mkdir -p $WHISPER_MODEL_PATH
RUN python3 << 'PYTHON'
import whisper
whisper.load_model('base', download_root='/usr/local/lib/whisper_models')
PYTHON

# Verify and fix ownership
RUN ls -l $WHISPER_MODEL_PATH/base.pt \
  || (echo "⚠️ Whisper model missing!" >&2 && exit 1)
RUN chown -R node:node $WHISPER_MODEL_PATH

# Install n8n
RUN npm install -g n8n

# Prepare shared data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
  && chmod -R 777 /data/shared

# Drop to non-root
USER node

ENTRYPOINT ["tini","--"]
CMD ["n8n","start"]
