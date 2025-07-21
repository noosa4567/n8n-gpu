###############################################################################
# Stage 1: prebuilt GPU-accelerated FFmpeg
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2: runtime with CUDA 11.8, PyTorch, n8n, Whisper & FFmpeg
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 1) Create non-root "node" user and n8n config dir
RUN groupadd -r node \
 && useradd -r -g node -m -d /home/node -s /bin/bash node \
 && mkdir -p /home/node/.n8n \
 && chown -R node:node /home/node/.n8n

# 2) Install tini & minimal runtime libs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini \
      python3-pip \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy FFmpeg & ffprobe from the builder
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/

# 4) Install Node.js 20 & n8n
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && rm -rf /var/lib/apt/lists/*

# 5) Pull in official n8n entrypoint (so keygen etc. works)
COPY --from=n8nio/n8n:latest /docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# 6) Install Whisper + tokenizer
RUN pip3 install --no-cache-dir tiktoken openai-whisper

# 7) Pre-download Whisper base model
RUN mkdir -p $WHISPER_MODEL_PATH
RUN python3 << 'PYCODE'
import whisper
whisper.load_model('base', download_root='$WHISPER_MODEL_PATH')
PYCODE
RUN chown -R node:node $WHISPER_MODEL_PATH

# 8) Verify FFmpeg linkage
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
  && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
  || echo "✅ FFmpeg OK"

# 9) Prepare shared data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data/shared

# 10) Switch to non-root & expose/start
USER node
EXPOSE 5678
ENTRYPOINT ["tini","--","/docker-entrypoint.sh"]
CMD ["start"]
