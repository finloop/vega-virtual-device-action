FROM --platform=linux/amd64 ubuntu:22.04

SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# Install curl and utilities needed by the SDK installer.
# Graphics stack for non-black screen capture WITHOUT a GPU (see
# docs/vvd-docker-screenshot-fix.md):
#   - libgl1-mesa-dri provides swrast_dri.so = the llvmpipe software GL renderer
#     that backs the emulator's `-gpu host` path. THIS is what makes capture work.
#   - xvfb + x11-utils give -gpu host a virtual display + xdpyinfo.
#   - libgl1/libegl1 + x11/xcb libs are the GL/X loaders.
#   - python3 drives the emulator-console screenshot (scripts/vvd-screenshot.sh)
#     and unpacks the platform-tools zip below.
# Node.js is NOT installed from apt (Ubuntu 22.04 ships Node 12, too old for the
# Vega CLI tooling and for Argent which needs Node 18+); Node 20 is installed below.
RUN apt-get update && \
    apt-get install -y \
      curl \
      tar \
      jq \
      ca-certificates \
      python3 \
      libx11-6 \
      libxext6 \
      libxcb1 \
      libx11-xcb1 \
      libgl1 \
      libegl1 \
      libgl1-mesa-dri \
      libglx-mesa0 \
      mesa-utils \
      xvfb \
      x11-utils \
      iproute2 \
      --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Node.js 20 (LTS) — the Vega CLI runs fine under it and Argent (run against the
# VVD in CI) needs Node 18+. Installed to /opt/node and put first on PATH so the
# SDK install + verify steps below use it.
ARG NODE_VERSION=v20.18.1
RUN curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.gz" \
      -o /tmp/node.tar.gz && \
    mkdir -p /opt/node && \
    tar -xzf /tmp/node.tar.gz -C /opt/node --strip-components=1 && \
    rm /tmp/node.tar.gz
ENV PATH="/opt/node/bin:${PATH}"

# Android platform-tools (adb). Argent's Vega screenshot resolves a real `adb`
# from $ANDROID_HOME/platform-tools and captures via `adb emu screenrecord`;
# real adb auto-detects the VVD on tcp:5555 as emulator-5554.
ENV ANDROID_HOME=/opt/android
ENV ANDROID_SDK_ROOT=/opt/android
RUN curl -fsSL https://dl.google.com/android/repository/platform-tools-latest-linux.zip \
      -o /tmp/platform-tools.zip && \
    mkdir -p "${ANDROID_HOME}" && \
    python3 -c "import zipfile; zipfile.ZipFile('/tmp/platform-tools.zip').extractall('${ANDROID_HOME}')" && \
    chmod +x "${ANDROID_HOME}/platform-tools/adb" && \
    rm /tmp/platform-tools.zip
ENV PATH="${ANDROID_HOME}/platform-tools:${PATH}"

# Install Vega SDK including VVD (Vega Virtual Device / emulator)
# NOTE: Run this image with:  --privileged --device /dev/kvm --init
#   --privileged + --device /dev/kvm : kernel-level virtualisation for QEMU.
#   --init : PID 1 must reap zombies, else the SDK's "already running" check
#            keys on a defunct emulator and blocks relaunch.
# --network=host is NOT required: start-vvd.sh re-enables IPv6 on loopback so
# QEMU's ::1 GNSS chardev binds without sharing the host network namespace.
ENV NONINTERACTIVE=true

ARG VEGA_SDK_VERSION=0.22.5600
ENV VEGA_SDK_VERSION=${VEGA_SDK_VERSION}

# SKIP_VVD_INSTALL=false means the VVD emulator IS installed in this image.
# Set to true at build time to produce a smaller build-only image.
ARG SKIP_VVD_INSTALL=false
ENV SKIP_VVD_INSTALL=${SKIP_VVD_INSTALL}

RUN curl -fsSL https://sdk-installer.vega.labcollab.net/get_vvm.sh | bash

ENV PATH="/root/vega/bin:${PATH}"

# Verify toolchain
RUN vega -v && node -v && npm -v && adb version

# Private npm registry config is mounted at runtime via NPM_CONFIG_GLOBALCONFIG.
# All @amazon-devices/ packages are currently public so this is a no-op by default.
ENV NPM_CONFIG_GLOBALCONFIG="/etc/npmrc"

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

ENTRYPOINT ["/bin/bash", "-c"]
