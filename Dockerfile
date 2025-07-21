# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ 1) Build FFmpeg with NVIDIA GPU support                                    │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential git pkg-config yasm nasm autoconf automake libtool \
      libfreetype6-dev libass-dev libtheora-dev libva-dev libva2 \
      libvdpau-dev libvdpau1 libvorbis-dev libxcb1-dev libxcb-shm0-dev \
      libxcb-xfixes0-dev zlib1g-dev texinfo libx264-dev libx265-dev \
      libvpx-dev libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev \
      libunistring-dev libasound2-dev libsndio-dev libsndio7.0 \
      nvidia-cuda-toolkit \
 && rm -rf /var/lib/apt/lists/*

RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && echo "🔧 Configuring FFmpeg…" \
 && ./configure --help \
 && ./configure --prefix=/usr/local \
       --enable-gpl --enable-nonfree \
       --enable-libass --enable-libfdk-aac --enable-libfreetype \
       --enable-libmp3lame --enable-libopus --enable-libvorbis \
       --enable-libvpx --enable-libx264 --enable-libx265 \
       --enable-libtheora --enable-vaapi --enable-alsa --enable-sndio \
       --enable-nvenc --enable-nvdec --enable-cuvid \
 && echo "🛠 Building FFmpeg…" \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig \
 && echo "🔍 Verifying FFmpeg libraries…" \
 && LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
    ldd /usr/local/bin/ffmpeg | grep -q "not found" \
    && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
    || echo "✅ FFmpeg OK" \
 && cd .. && rm -rf ffmpeg

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ 2) Runtime: PyTorch CUDA runtime + n8n + Whisper + GPU support              │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM pytorch/pytorch:2.1.2-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib

# 2a) Ensure the node user exists for n8n
RUN groupadd -r node && useradd -r -g node node

# 2b) Minimal runtime deps + GPU codec runtimes + n8n
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl gnupg2 dirmngr ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Copy FFmpeg from builder
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/        /usr/local/lib/

# Node.js 20 + n8n
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && rm -rf /var/lib/apt/lists/*

# Whisper + tiktoken + pre-download model
RUN pip3 install --no-cache-dir --no-deps tiktoken openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models \
 && echo "📥 Pre-downloading Whisper base model…" \
 && python3 - << 'PYTHON'
import whisper
whisper.load_model('base', download_root='/usr/local/lib/whisper_models')
PYTHON \
 && ls -l /usr/local/lib/whisper_models/base.pt || (echo "⚠️ Whisper model missing!" >&2 && exit 1) \
 && chown -R node:node /usr/local/lib/whisper_models

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# Data volumes
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data

USER node
ENTRYPOINT ["tini","--"]
CMD ["n8n","start"]
