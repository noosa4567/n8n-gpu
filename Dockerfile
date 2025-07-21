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

# 1) Create non-root "node" user
RUN groupadd -r node \
 && useradd -r -g node -m -d /home/node -s /bin/bash node

# 2) Install tini, gosu (to drop to node), Python, Whisper deps, codec runtimes
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini gosu \
      python3-pip \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 3) Copy FFmpeg + ffprobe + libs
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/

# 4) Install Node.js 20 and n8n CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && rm -rf /var/lib/apt/lists/*

# 5) Install Whisper + its tokenizer
RUN pip3 install --no-cache-dir tiktoken openai-whisper

# 6) Pre-download Whisper "base" model and fix ownership
RUN mkdir -p $WHISPER_MODEL_PATH \
 && python3 - <<'PYTHON'
import whisper
whisper.load_model('base', download_root='$WHISPER_MODEL_PATH')
PYTHON \
 && chown -R node:node $WHISPER_MODEL_PATH

# 7) Prepare shared data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data/shared

# 8) Install a tiny entrypoint script that:
#    • creates /home/node/.n8n on each start
#    • fixes its ownership
#    • execs      n8n start    as the node user
RUN tee /usr/local/bin/entrypoint.sh > /dev/null << 'EOS'
#!/bin/sh
set -e
mkdir -p /home/node/.n8n
chown -R node:node /home/node/.n8n
exec gosu node n8n start
EOS
RUN chmod +x /usr/local/bin/entrypoint.sh

# 9) Switch to tini + our entrypoint, with default CMD of nothing (we bake "start" into the script)
ENTRYPOINT ["tini","--","/usr/local/bin/entrypoint.sh"]
CMD []
