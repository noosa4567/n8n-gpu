# ---- Base OS with CUDA (for GPU support) ----
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Australia/Brisbane

# Create a non-root user 'node' and home directory
RUN groupadd -r node && useradd -r -g node -m -d /home/node -s /bin/bash node

# Pre-create n8n configuration directory and set ownership
RUN mkdir -p /home/node/.n8n && chown -R node:node /home/node

# Install tini (for signal handling), Python (for pip), Git, and Chrome dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \ 
    tini python3-pip git \ 
    # Puppeteer/Chromium dependencies:
    libnss3 libnspr4 libcups2 libatk1.0-0 libatk-bridge2.0-0 \ 
    libx11-xcb1 libxcomposite1 libxcursor1 libxdamage1 libxext6 \ 
    libxi6 libxtst6 libxrandr2 libxrender1 libxcb-shm0 libxcb-xfixes0 \ 
    libxcb1 libxcb-dri3-0 libxss1 libglib2.0-0 libgbm1 libpangocairo-1.0-0 \ 
    libpango-1.0-0 libcairo2 libharfbuzz0b libfribidi0 libasound2 libsndio7.0 \ 
    fonts-liberation libexpat1 lsb-release wget xdg-utils \ 
 && rm -rf /var/lib/apt/lists/*

# Copy GPU-enabled FFmpeg binaries (from a pre-built image) for video processing
COPY --from=jrottenberg/ffmpeg:5.1-nvidia /usr/local/bin/ffmpeg  /usr/local/bin/
COPY --from=jrottenberg/ffmpeg:5.1-nvidia /usr/local/bin/ffprobe /usr/local/bin/
COPY --from=jrottenberg/ffmpeg:5.1-nvidia /usr/local/lib/        /usr/local/lib/
RUN ldconfig  # refresh linker cache for FFmpeg libs

# Install Node.js 20 (LTS) from official tarball
RUN curl -fsSL https://nodejs.org/dist/v20.19.4/node-v20.19.4-linux-x64.tar.xz -o node.tar.xz \ 
 && tar -xJf node.tar.xz -C /usr/local --strip-components=1 \ 
 && rm node.tar.xz

# Install n8n (latest version) and Puppeteer (with its Chromium)
ENV NODE_PATH=/usr/lib/node_modules  # so global modules are in Node search path
RUN npm install -g puppeteer@23.11.1 n8n-nodes-puppeteer --legacy-peer-deps \ 
 && mkdir -p /app && cd /app \ 
 && npm install n8n@latest \ 
 && npm cache clean --force

# Install Python dependencies: PyTorch (CUDA 11.8 build), Whisper, and related
RUN pip3 install --no-cache-dir --upgrade pip \ 
 && pip3 install --no-cache-dir torch==2.1.0+cu118 torchvision==0.14.1+cu118 \ 
        -f https://download.pytorch.org/whl/torch_stable.html \ 
 && pip3 install --no-cache-dir numpy==1.26.3 openai-whisper tiktoken

# (Optional) Pre-download a Whisper model to /usr/local/lib/whisper_models for faster startup
ENV WHISPER_MODEL_PATH=/usr/local/lib/whisper_models
RUN mkdir -p $WHISPER_MODEL_PATH \ 
 && python3 -c "import whisper; whisper.load_model('base', download_root='$WHISPER_MODEL_PATH')" \ 
    || python3 -c "import whisper; whisper.load_model('base', download_root='$WHISPER_MODEL_PATH')"

# Fix ownership of all installed files to non-root user
RUN chown -R node:node /app /usr/local/lib/node_modules $WHISPER_MODEL_PATH

# Create cache directory for n8n to avoid permission issues on first run
RUN mkdir -p /home/node/.cache/n8n && chown -R node:node /home/node/.cache

# Expose n8n web interface port
EXPOSE 5678

# Healthcheck (optional) to verify n8n is running
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \ 
  CMD curl -f http://localhost:5678/healthz || exit 1

# Use Tini as the entrypoint for proper signal handling, run n8n as 'node' user
USER node
ENTRYPOINT ["tini", "--"]
CMD ["/app/node_modules/.bin/n8n"]
