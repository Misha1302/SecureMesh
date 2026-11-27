FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3
RUN apt-get update && apt-get install -y --no-install-recommends clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good pulseaudio-utils git curl unzip xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace/apps/client_flutter
RUN apt-get update && apt-get install -y --no-install-recommends xvfb xdotool imagemagick libgl1-mesa-dri xauth && rm -rf /var/lib/apt/lists/*
