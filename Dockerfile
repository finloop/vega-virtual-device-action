# Thin wrapper on top of vega-virtual-device-host-base (which contains apt deps,
# Node, platform-tools, and the Vega SDK + VVD). The heavy "base" is built and
# pushed by .github/workflows/docker-base-publish.yml on .sdk-version bumps;
# this wrapper just layers in /scripts/ so PR builds never re-run get_vvm.sh.
#
# Run with:  --privileged --device /dev/kvm --init  (see Dockerfile.host-base).
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

ENTRYPOINT ["/bin/bash", "-c"]
