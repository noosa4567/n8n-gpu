FROM node:20-bookworm-slim

USER root

RUN echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list && 

echo "deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list && 

echo "deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list && 

apt-get update && apt-get install -y 

git pkg-config yasm nasm build-essential autoconf automake libtool libc6-dev 

libass-dev libfreetype6-dev libsdl2-dev libtheora-dev libva-dev libvdpau-dev libvorbis-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev texinfo zlib1g-dev libx264-dev libx265-dev libnuma-dev libvpx-dev libfdk-aac-dev libmp3lame-dev libopus-dev libdav1d-dev libunistring-dev 

libasound2-dev libsndio-dev libsndio6.1 

nvidia-cuda-toolkit 

python3 python3-pip python3-venv && 

rm -rf /var/lib/apt/lists/*

RUN git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git && 

cd nv-codec-headers && 

make install && 

cd .. && rm -rf nv-codec-headers

RUN git clone https://git.ffmpeg.org/ffmpeg.git && 

cd ffmpeg && 

./configure --enable-gpl --enable-libass --enable-libfdk-aac --enable-libfreetype --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx --enable-libx264 --enable-libx265 --enable-nonfree --enable-nvenc --enable-nvdec --enable-cuvid --enable-alsa && 

make -j$(nproc) && 

make install && 

cd .. && rm -rf ffmpeg || echo "FFmpeg build failed, check logs"

RUN python3 -m pip install --upgrade pip --break-system-packages && 

python3 -m pip install --no-cache-dir --break-system-packages --target=/usr/local/lib/python3.11/dist-packages torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118

RUN python3 -m pip install --no-cache-dir --break-system-packages --target=/usr/local/lib/python3.11/dist-packages openai-whisper

RUN mkdir -p /usr/local/lib/whisper_models && 

python3 -c "from whisper import _download, _MODELS; _download(_MODELS['base'], '/usr/local/lib/whisper_models', in_memory=False)" && 

ls -l /usr/local/lib/whisper_models/base.pt || echo "Whisper model download failed"

RUN npm install -g n8n
