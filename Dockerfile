###############################################################################
# Stage 1: Pull a tiny, GPU-accelerated FFmpeg image
###############################################################################
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

###############################################################################
# Stage 2: Runtime with CUDA 11.8 PyTorch, n8n, Whisper & our FFmpeg binaries
###############################################################################
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib

# 1) Minimal runtime deps + timezone + tini + codec runtimes
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata \
      tini \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl gnupg dirmngr ca-certificates \
 && ln -fs /usr/share/zoneinfo/Australia/Brisbane /etc/localtime \
 && dpkg-reconfigure --frontend noninteractive tzdata \
 && rm -rf /var/lib/apt/lists/*

# 2) Copy our GPU-enabled FFmpeg + ffprobe
COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/

# 3) Install Node.js 20 & n8n CLI
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && rm -rf /var/lib/apt/lists/*

# 4) Install Whisper (no PyTorch wheels needed) and pre-download model
RUN pip3 install --no-cache-dir --no-deps openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models \
 && echo "📥 Pre-downloading Whisper base model…" \
 && python3 - << 'PYTHON'
import whisper
whisper.load_model("base", download_root="/usr/local/lib/whisper_models")
PYTHON

# 5) Verification
RUN ls -l /usr/local/lib/whisper_models/base.pt \
    || (echo "⚠️ Whisper model missing!" >&2 && exit 1)

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 6) Prepare data volume & permissions
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data/shared

USER node

ENTRYPOINT ["tini","--"]
CMD ["n8n","start"]
