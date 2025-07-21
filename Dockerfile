```dockerfile
# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ 1) Build FFmpeg with NVIDIA GPU support                                    │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
      tzdata build-essential git pkg-config yasm nasm autoconf automake libtool \
      libfreetype6-dev libass-dev libtheora-dev libva-dev libvdpau-dev zlib1g-dev \
      texinfo libx264-dev libx265-dev libvpx-dev libfdk-aac-dev \
      libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      libasound2-dev libsndio-dev libsndio7.0 nvidia-cuda-toolkit \
 && rm -rf /var/lib/apt/lists/*

# NVENC/NVDEC headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# Configure, build & install
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && echo "🔧 Configuring FFmpeg…" \
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
 && echo "🔍 Verifying FFmpeg linkage…" \
 && LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 ldd /usr/local/bin/ffmpeg | grep -q "not found" \
      && (echo "⚠️ Unresolved libraries" >&2 && exit 1) \
      || echo "✅ FFmpeg OK" \
 && cd .. && rm -rf ffmpeg


# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ 2) Runtime: n8n + Whisper + FFmpeg                                          │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM pytorch/pytorch:2.7.1-cuda11.8-cudnn8-runtime
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib

# Basic runtimes, timezone, Node.js & cleans
RUN apt-get update && apt-get install -y --no-install-recommends \
      tzdata curl gnupg2 dirmngr ca-certificates \
      libsndio7.0 libasound2 libva2 libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 \
      tini \
 && ln -fs /usr/share/zoneinfo/Australia/Brisbane /etc/localtime \
 && dpkg-reconfigure --frontend noninteractive tzdata \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# n8n
RUN npm install -g n8n && npm cache clean --force

# Whisper (skip torch dep install)
RUN pip3 install --no-cache-dir --no-deps openai-whisper

# Pre-download Whisper model
RUN mkdir -p /usr/local/lib/whisper_models \
 && python3 - <<PYTHON
import whisper
whisper.load_model('base', download_root='/usr/local/lib/whisper_models')
PYTHON
 && ls -l /usr/local/lib/whisper_models/base.pt \
 && chown -R 1000:1000 /usr/local/lib/whisper_models

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# Copy FFmpeg from builder
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/      /usr/local/lib/

# Prepare data dirs
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chown -R 1000:1000 /data \
 && chmod -R 777 /data

# Unprivileged run
USER node

EXPOSE 5678
ENTRYPOINT ["tini","--","/docker-entrypoint.sh"]
CMD ["n8n","start"]
```
