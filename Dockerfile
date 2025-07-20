# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ Stage 1: Build FFmpeg with sndio & NVENC/NVDEC                              │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Build deps + sndio runtime headers
RUN apt-get update && apt-get install -y --no-install-recommends \
      tzdata build-essential git pkg-config yasm nasm autoconf automake libtool \
      libsndio-dev libsndio7.0 libasound2-dev \
      libfreetype6-dev libass-dev libtheora-dev libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
      zlib1g-dev texinfo libx264-dev libx265-dev libnuma-dev libvpx-dev \
      libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
 && rm -rf /var/lib/apt/lists/*

# NVENC/NVDEC headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# Build FFmpeg
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && ./configure --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-alsa --enable-sndio \
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && make -j"$(nproc)" V=1 \
 && make install V=1 \
 && cd .. && rm -rf ffmpeg \
 && ldconfig

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ Stage 2: Runtime image                                                      │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM nvidia/cuda:11.8.0-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64

USER root

# ── Copy only FFmpeg binaries & libs ─────────────────────────────────────────
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg-builder /usr/local/lib/ /usr/local/lib/

# ── Register loader paths ────────────────────────────────────────────────────
RUN echo "/usr/local/lib"        > /etc/ld.so.conf.d/ffmpeg.conf \
 && echo "/usr/local/cuda/lib64" > /etc/ld.so.conf.d/cuda.conf \
 && ldconfig

# ── Install minimal runtime deps + tzdata ────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      tzdata libsndio7.0 libasound2 \
      python3-full python3-pip python3-venv ca-certificates curl gnupg2 dirmngr \
 && rm -rf /var/lib/apt/lists/*

# ── Install Node.js 20 ───────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# ── Create unprivileged 'node' user ──────────────────────────────────────────
RUN groupadd -r node \
 && useradd  -r -g node -d /home/node -s /bin/bash -c "n8n user" node \
 && mkdir -p /home/node \
 && chown -R node:node /home/node

# ── Python & Whisper setup ───────────────────────────────────────────────────
RUN python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel
RUN python3 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
RUN python3 -m pip install --no-cache-dir openai-whisper

# Pre-download Whisper "base" model
RUN mkdir -p /usr/local/lib/whisper_models \
 && python3 -c "import whisper; whisper.load_model('base', download_root='/usr/local/lib/whisper_models')" \
 && chown -R node:node /usr/local/lib/whisper_models

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# ── Install n8n globally ─────────────────────────────────────────────────────
RUN npm install -g n8n \
 && npm cache clean --force

# ── Prepare /data mounts & permissions ───────────────────────────────────────
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R node:node /data /usr/local/lib/whisper_models /home/node \
 && chmod -R 777 /data /usr/local/lib/whisper_models /home/node

# ── Switch to 'node' & expose port ──────────────────────────────────────────
USER node
EXPOSE 5678

# ── Ensure n8n is run directly, bypassing NVIDIA entrypoint ─────────────────
ENTRYPOINT ["n8n"]
CMD        ["start"]
