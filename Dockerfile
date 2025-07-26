# syntax=docker/dockerfile:1
FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg

FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane \
    HOME=/home/node \
    LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/nvidia/nvidia:/usr/local/nvidia/nvidia.u18.04 \
    WHISPER_MODEL_PATH=/usr/local/lib/whisper_models \
    PUPPETEER_CACHE_DIR=/home/node/.cache/puppeteer \
    PATH="/opt/conda/bin:${PATH}"

RUN groupadd -r node \
 && useradd -r -g node -G video -u 999 -m -d "$HOME" -s /bin/bash node \
 && mkdir -p "$HOME/.n8n" \
 && chown -R node:node "$HOME"

RUN rm -f /etc/apt/sources.list.d/cuda* /etc/apt/sources.list.d/nvidia* \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      tini git curl ca-certificates gnupg wget \
      python3 python3-pip xz-utils \
      libsndio7.0 libsndio6.1 libasound2 \
      libva2 libva-x11-2 libva-drm2 libva-wayland2 \
      libvdpau1 \
      libxcb1 libxcb-shape0 libxcb-shm0 libxcb-xfixes0 libxcb-render0 \
      libx11-6 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2 \
      libxrender1 libxss1 libxtst6 libxi6 libxcursor1 \
      libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdbus-1-3 libexpat1 \
      libfontconfig1 libgbm1 libegl1-mesa libgl1-mesa-dri libdrm2 \
      libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
      libpangocairo-1.0-0 libpango-1.0-0 libharfbuzz0b libfribidi0 libthai0 libdatrie1 \
      libsdl2-2.0-0 fonts-liberation lsb-release xdg-utils libfreetype6 libatspi2.0-0 libgcc1 libstdc++6 \
      libnvidia-egl-gbm1 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ffmpeg /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/        /usr/local/lib/
RUN rm -f /usr/local/lib/lib{fribidi,harfbuzz,pango}* \
 && ldconfig

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/node/.cache/puppeteer \
 && chown node:node /home/node/.cache/puppeteer

USER root
RUN npm install -g --unsafe-perm \
      n8n@1.104.1 \
      puppeteer@24.14.0 \
      n8n-nodes-puppeteer@1.4.1 \
      ajv@8.17.1 \
      --legacy-peer-deps \
 && npm cache clean --force \
 && chown -R node:node /home/node/.cache/puppeteer "$(npm root -g)"

RUN pip3 install --no-cache-dir \
      --index-url https://download.pytorch.org/whl/cu118 \
      torch==2.1.0+cu118 numpy==1.26.3 \
 && pip3 install --no-cache-dir tiktoken openai-whisper==20240930 \
 && mkdir -p "${WHISPER_MODEL_PATH}" \
 && python3 -c "import os, whisper; whisper.load_model('base', download_root=os.environ['WHISPER_MODEL_PATH'])" \
 && chown -R node:node "${WHISPER_MODEL_PATH}"

RUN mkdir -p "$HOME/.cache/n8n/public" /data/shared/{videos,audio,transcripts} \
 && chown -R node:node "$HOME" /data/shared \
 && chmod -R 770 /data/shared "$HOME/.cache"

RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" \
     && (echo "❌ unresolved FFmpeg libs" >&2 && exit 1) \
     || echo "✅ FFmpeg libs OK"

USER node
WORKDIR $HOME
EXPOSE 5678

ENTRYPOINT ["tini","--","n8n","start"]
CMD []
