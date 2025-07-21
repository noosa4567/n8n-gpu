FROM jrottenberg/ffmpeg:5.1-nvidia AS ffmpeg
FROM pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/usr/local/nvidia/lib WHISPER_MODEL_PATH=/usr/local/lib/whisper_models
RUN groupadd -r node && useradd -r -g node -m -d /home/node -s /bin/bash node && mkdir -p /home/node/.n8n && chown -R node:node /home/node/.n8n
RUN apt-get update && apt-get install -y --no-install-recommends tini python3-pip libsndio7.0 libasound2 libva2 libva-x11-2 libva-drm2 libva-wayland2 libvdpau1 curl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=ffmpeg /usr/local/bin/ffmpeg /usr/local/bin/
COPY --from=ffmpeg /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=ffmpeg /usr/local/lib/ /usr/local/lib/
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get update && apt-get install -y --no-install-recommends nodejs && npm install -g n8n && rm -rf /var/lib/apt/lists/*
COPY --from=n8nio/n8n:latest /docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
RUN pip3 install --no-cache-dir tiktoken openai-whisper
RUN mkdir -p $WHISPER_MODEL_PATH && python3 - << 'PYCODE' && chown -R node:node $WHISPER_MODEL_PATH
import whisper
whisper.load_model('base', download_root='$WHISPER_MODEL_PATH')
PYCODE
RUN ldd /usr/local/bin/ffmpeg | grep -q "not found" && (echo "⚠️ Unresolved FFmpeg libraries" >&2 && exit 1) || echo "✅ FFmpeg libs OK"
RUN mkdir -p /data/shared/{videos,audio,transcripts} && chmod -R 777 /data/shared
USER node
EXPOSE 5678
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["n8n","start"]
