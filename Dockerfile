# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ Stage 1: Build FFmpeg with sndio & NVENC/NVDEC                              │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# 1) Install build-time dependencies (including sndio7.0 & CUDA toolkit)
RUN echo "📦 Installing build dependencies…" \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata \
      build-essential git pkg-config yasm nasm autoconf automake libtool \
      libfreetype6-dev libass-dev libtheora-dev \
      libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
      zlib1g-dev texinfo libx264-dev libx265-dev libvpx-dev \
      libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      libasound2-dev libsndio-dev libsndio7.0 \
      nvidia-cuda-toolkit \
 && rm -rf /var/lib/apt/lists/*

# 2) NVIDIA codec headers for NVENC/NVDEC
RUN echo "🔧 Installing NVIDIA codec headers…" \
 && git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# 3) Clone, configure, build & install FFmpeg
RUN echo "🔍 Cloning FFmpeg source…" \
 && git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && echo "⚙️  Configuring FFmpeg…" \
 && ./configure --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-libtheora --enable-vaapi \
      --enable-alsa --enable-sndio \
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && echo "🛠  Building FFmpeg…" \
 && make -j"$(nproc)" V=1 \
 && make install V=1 \
 && ldconfig \
 && echo "✅ FFmpeg built; verifying…" \
 && ffmpeg -version \
 && LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
    ldd /usr/local/bin/ffmpeg | grep -q "not found" \
      && (echo "❌ Missing FFmpeg libs!" >&2; exit 1) \
      || echo "✅ FFmpeg libs OK" \
 && cd .. && rm -rf ffmpeg

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ Stage 2: Runtime (extends official n8n image)                              │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM n8nio/n8n:latest

USER root

# 4) Copy FFmpeg artifacts
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/      /usr/local/lib/

# 5) Runtime library lookup & timezone
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib \
    TZ=Etc/UTC

# 6) Install minimal runtime deps
RUN echo "📦 Installing runtime dependencies…" \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      python3-minimal python3-pip \
      ca-certificates curl gnupg2 dirmngr \
 && rm -rf /var/lib/apt/lists/*

# 7) Python tooling & Whisper
RUN echo "🐍 Installing Python packages…" \
 && python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel \
 && python3 -m pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 \
 && python3 -m pip install --no-cache-dir openai-whisper

# 8) Pre-download Whisper "base" model with strict check
RUN echo "⬇️  Pre-downloading Whisper model…" \
 && mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "import whisper; whisper.load_model('base', download_root='/usr/local/lib/whisper_models')" \
 && ls -l /usr/local/lib/whisper_models/base.pt \
      || (echo "❌ Whisper model missing!" >&2; exit 1) \
 && chown -R node:node /usr/local/lib/whisper_models

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 9) Prepare QNAP-friendly mounts & permissions
RUN echo "🔐 Setting up data directories…" \
 && mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data /usr/local/lib/whisper_models /home/node \
 && chmod -R 777 /data /usr/local/lib/whisper_models /home/node

# 10) Switch to unprivileged user & expose port
USER node
EXPOSE 5678

ENTRYPOINT ["tini","--","/docker-entrypoint.sh"]
CMD        ["n8n","start"]
