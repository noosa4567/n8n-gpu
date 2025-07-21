###############################################################################
# Stage 1 – build FFmpeg with VAAPI, NVENC/NVDEC, sndio, etc.
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ARG  DEBIAN_FRONTEND=noninteractive
ENV  TZ=Etc/UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
      tzdata build-essential git pkg-config yasm nasm autoconf automake libtool \
      libfreetype6-dev libass-dev libtheora-dev \
      libva-dev libvdpau-dev \
      libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev \
      zlib1g-dev texinfo libx264-dev libx265-dev libnuma-dev libvpx-dev \
      libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      libasound2-dev libsndio-dev libsndio7.0 \
      nvidia-cuda-toolkit && \
    rm -rf /var/lib/apt/lists/*

# NVENC/NVDEC headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git && \
    cd nv-codec-headers && make install && cd .. && rm -rf nv-codec-headers

# Clone, configure, build and install FFmpeg
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg && \
    cd ffmpeg && \
    ./configure --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-libtheora --enable-vaapi --enable-libnuma \
      --enable-libdav1d \
      --enable-alsa --enable-sndio \
      --enable-nvenc --enable-nvdec --enable-cuvid && \
    make -j"$(nproc)" V=1 && make install V=1 && ldconfig && \
    cd .. && rm -rf ffmpeg && \
    # verify no missing shared libs
    ldd /usr/local/bin/ffmpeg | grep -q "not found" && \
      (echo "⚠️ Unresolved FFmpeg libraries" >&2 && exit 1) || echo "✅ FFmpeg libs OK"

###############################################################################
# Stage 2 – runtime (based on official n8n image)
###############################################################################
FROM n8nio/n8n:latest

USER root

# Copy FFmpeg + ffprobe + libs
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/        /usr/local/lib/

# Make sure these are found at runtime
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib

# Runtime deps (audio, VAAPI, Python)
RUN apt-get update && apt-get install -y --no-install-recommends \
      tzdata libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 \
      python3-minimal python3-pip \
      ca-certificates curl gnupg2 dirmngr && \
    rm -rf /var/lib/apt/lists/*

# Python + Whisper
RUN python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel && \
    python3 -m pip install --no-cache-dir \
      torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 && \
    python3 -m pip install --no-cache-dir openai-whisper

# Pre-download and verify the Whisper “base” model
RUN mkdir -p /usr/local/lib/whisper_models && \
    python3 -c "import whisper; whisper.load_model('base', download_root='/usr/local/lib/whisper_models')" && \
    ls -l /usr/local/lib/whisper_models/base.pt || echo "⚠️ Whisper model missing" && \
    chown -R node:node /usr/local/lib/whisper_models

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# Make /data writable for QNAP Container Station volumes
RUN mkdir -p /data/shared/{videos,audio,transcripts} && \
    chown -R node:node /data /usr/local/lib/whisper_models /home/node && \
    chmod -R 777       /data /usr/local/lib/whisper_models /home/node

# Switch back to unprivileged user
USER node

EXPOSE 5678

# Use tini + official n8n entrypoint, with CMD for “start”
ENTRYPOINT ["tini","--","/docker-entrypoint.sh"]
CMD        ["n8n","start"]
