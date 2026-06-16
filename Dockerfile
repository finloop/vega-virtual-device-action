FROM --platform=linux/amd64 ubuntu:22.04

SHELL ["/bin/bash", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

# Install curl and utilities needed by the SDK installer, plus Node.js.
# Graphics stack for non-black screen capture WITHOUT a GPU (see
# docs/vvd-docker-screenshot-fix.md):
#   - libgl1-mesa-dri provides swrast_dri.so = the llvmpipe software GL renderer
#     that backs the emulator's `-gpu host` path. THIS is what makes capture work.
#   - xvfb + x11-utils give -gpu host a virtual display + xdpyinfo.
#   - libgl1/libegl1 + x11/xcb libs are the GL/X loaders.
#   - python3 drives the emulator-console screenshot (scripts/vvd-screenshot.sh).
RUN apt-get update && \
    apt-get install -y \
      curl \
      tar \
      jq \
      ca-certificates \
      nodejs \
      npm \
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
RUN vega -v && node -v && npm -v

# Private npm registry config is mounted at runtime via NPM_CONFIG_GLOBALCONFIG.
# All @amazon-devices/ packages are currently public so this is a no-op by default.
ENV NPM_CONFIG_GLOBALCONFIG="/etc/npmrc"

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

ENTRYPOINT ["/bin/bash", "-c"]
