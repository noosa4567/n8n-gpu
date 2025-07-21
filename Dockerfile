# 1) Build FFmpeg with NVENC/NVDEC + all codecs we need
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       tzdata build-essential git pkg-config yasm nasm autoconf automake libtool \
       libfreetype6-dev libass-dev libtheora-dev libva-dev libva2 libvdpau-dev libvdpau1 \
       libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev zlib1g-dev texinfo \
       libx264-dev libx265-dev libvpx-dev libfdk-aac-dev libmp3lame-dev libopus-dev \
       libdav1d-dev libunistring-dev libasound2-dev libsndio-dev libsndio7.0 \
       nvidia-cuda-toolkit \
  && rm -rf /var/lib/apt/lists/*

# Install NVIDIA codec headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
  && cd nv-codec-headers && make install \
  && cd .. && rm -rf nv-codec-headers

# Clone & build FFmpeg
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
  && echo "🔍 Verifying FFmpeg libs…" \
  && LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 ldd /usr/local/bin/ffmpeg | grep -q "not found" \
       && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) || echo "✅ FFmpeg OK" \
  && cd .. \
  && rm -rf ffmpeg

# 2) Runtime: PyTorch GPU image + n8n + Whisper
FROM pytorch/pytorch:2.1.2-cuda11.8-cudnn8-runtime
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib

# Install tini, GPU runtimes, Node.js, n8n
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       tini \
       libsndio7.0 libasound2 \
       libva2 libva-x11-2 libva-drm2 libva-wayland2 \
       libvdpau1 \
       curl gnupg2 dirmngr ca-certificates \
  && ln -fs /usr/share/zoneinfo/Australia/Brisbane /etc/localtime \
  && dpkg-reconfigure --frontend noninteractive tzdata \
  # Node.js 20
  && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && npm install -g n8n \
  && rm -rf /var/lib/apt/lists/*

# Create the 'node' user (UID 1000) so USER node works
RUN groupadd -g 1000 node \
  && useradd --no-log-init -u 1000 -g node -m -d /home/node node

# Install Whisper (no deps) and pre-download base model
RUN pip3 install --no-cache-dir --no-deps openai-whisper \
  && mkdir -p /usr/local/lib/whisper_models \
  && echo "📥 Pre-downloading Whisper base model…" \
  && python3 - << 'PYTHON'
import whisper
whisper.load_model("base", download_root="/usr/local/lib/whisper_models")
PYTHON
  && ls -l /usr/local/lib/whisper_models/base.pt \
     || (echo "⚠️ Whisper model missing!" >&2 && exit 1)

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# Copy in our FFmpeg bits from the builder stage
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/        /usr/local/lib/

# Prepare data directories
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
  && chmod -R 777 /data/shared

# Switch to node user and run n8n
USER node
EXPOSE 5678
ENTRYPOINT ["tini","--","n8n"]
CMD ["start"]
