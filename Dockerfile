###############################################################################
# Stage 1: Build FFmpeg with NVENC/NVDEC/CUVID support
###############################################################################
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# 1) Install only the bare build tools + runtime headers needed for hardware codecs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git build-essential pkg-config yasm nasm \
      autoconf automake libtool \
      libva-dev libva2 libvdpau-dev libvdpau1 \
      libsndio-dev libsndio7.0 libasound2-dev \
      libfreetype6-dev libass-dev libtheora-dev libvorbis-dev zlib1g-dev texinfo \
      libx264-dev libx265-dev libvpx-dev libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev \
      nvidia-cuda-toolkit \
 && rm -rf /var/lib/apt/lists/*

# 2) Install NVIDIA codec headers for NVENC/NVDEC/CUVID
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# 3) Clone, configure, build, and install FFmpeg
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && echo "🔧 Configuring FFmpeg…" \
 && ./configure \
      --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-libass --enable-libfdk-aac --enable-libfreetype \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-libvpx --enable-libx264 --enable-libx265 \
      --enable-libtheora \
      --enable-vaapi --enable-vdpau \
      --enable-alsa --enable-sndio \
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && echo "🛠 Building FFmpeg…" \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig \
 && echo "🔍 Verifying FFmpeg libraries and codecs…" \
 && LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64 ldd /usr/local/bin/ffmpeg | grep -q "not found" \
      && (echo "⚠️ Unresolved FFmpeg libs" >&2 && exit 1) \
      || echo "✅ FFmpeg libs OK" \
 && ffmpeg -encoders | head -n 5 && ffmpeg -decoders | head -n 5 \
 && cd .. && rm -rf ffmpeg

###############################################################################
# Stage 2: Runtime with PyTorch CUDA 11.8, n8n, Whisper, and FFmpeg binaries
###############################################################################
FROM pytorch/pytorch:2.1.2-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib

# 4) Minimal runtime deps + tini + hardware codec runtimes
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini \
      libsndio7.0 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      curl gnupg2 dirmngr ca-certificates \
 && ln -fs /usr/share/zoneinfo/Australia/Brisbane /etc/localtime \
 && dpkg-reconfigure --frontend noninteractive tzdata \
 && rm -rf /var/lib/apt/lists/*

# 5) Copy FFmpeg from builder
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/       /usr/local/lib/

# 6) Install Node.js 20 & n8n
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && rm -rf /var/lib/apt/lists/*

# 7) Install Whisper without extra deps and pre-download model
RUN pip3 install --no-cache-dir --no-deps openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models

RUN echo "📥 Pre-downloading Whisper base model…" \
 && python3 - << 'PYTHON'
import whisper
whisper.load_model("base", download_root="/usr/local/lib/whisper_models")
PYTHON

# 8) Verify Whisper model
RUN ls -l /usr/local/lib/whisper_models/base.pt \
    || (echo "⚠️ Whisper model missing!" >&2 && exit 1)

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 9) Prepare shared data mount
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data

USER node

ENTRYPOINT ["tini","--"]
CMD ["n8n","start"]
