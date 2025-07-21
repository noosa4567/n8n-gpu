# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ Stage 1: Build a minimal FFmpeg with NVIDIA NVENC/NVDEC support            │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS ffmpeg-builder

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# 1) Minimal build tools + CUDA toolkit
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata build-essential git pkg-config yasm nasm autoconf automake libtool \
      zlib1g-dev texinfo nvidia-cuda-toolkit \
 && rm -rf /var/lib/apt/lists/*

# 2) NVIDIA NVENC headers
RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
 && cd nv-codec-headers && make install \
 && cd .. && rm -rf nv-codec-headers

# 3) Clone, configure & build FFmpeg with only NVENC/NVDEC
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg \
 && cd ffmpeg \
 && echo "🔧 Configuring FFmpeg…" \
 && ./configure \
      --prefix=/usr/local \
      --enable-gpl --enable-nonfree \
      --enable-nvenc --enable-nvdec --enable-cuvid \
 && echo "🛠 Building FFmpeg…" \
 && make -j"$(nproc)" \
 && make install \
 && ldconfig \
 && echo "✅ FFmpeg built" \
 && cd .. && rm -rf ffmpeg

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ Stage 2: Runtime – PyTorch (CUDA 11.8), n8n, Whisper, FFmpeg binaries        │
# └─────────────────────────────────────────────────────────────────────────────┘
FROM pytorch/pytorch:2.1.2-cuda11.8-cudnn8-runtime

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib

# 1) Minimal runtime deps + timezone + tini
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tzdata curl gnupg2 dirmngr ca-certificates tini \
      libsndio7.0 libasound2 \
 && ln -fs /usr/share/zoneinfo/Australia/Brisbane /etc/localtime \
 && dpkg-reconfigure --frontend noninteractive tzdata \
 && rm -rf /var/lib/apt/lists/*

# 2) Copy FFmpeg binaries & libs
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg-builder /usr/local/lib/       /usr/local/lib/

# 3) Install Node.js & n8n
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g n8n \
 && rm -rf /var/lib/apt/lists/*

# 4) Install Whisper and prepare model dir
RUN pip3 install --no-cache-dir --no-deps openai-whisper \
 && mkdir -p /usr/local/lib/whisper_models

# 4a) Pre-download Whisper base model (fixed heredoc)
RUN echo "📥 Pre-downloading Whisper model…" \
 && python3 - <<'PYTHON'
import whisper
whisper.load_model("base", download_root="/usr/local/lib/whisper_models")
PYTHON

# 4b) Validate model download
RUN ls -l /usr/local/lib/whisper_models/base.pt \
 || (echo "⚠️ Whisper model missing!" >&2 && exit 1)

ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models

# 5) Prepare data mount
RUN mkdir -p /data/shared/{videos,audio,transcripts} \
 && chmod -R 777 /data

USER node

EXPOSE 5678
ENTRYPOINT ["tini","--"]
CMD ["n8n","start"]
