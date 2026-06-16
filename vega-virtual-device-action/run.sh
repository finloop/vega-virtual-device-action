#!/usr/bin/env bash
# Host side of vega-virtual-device-action (runs on the GitHub runner).
#
# Runs the vega-virtual-device-host image as a container with the flags the VVD
# requires (--privileged --device /dev/kvm --init), bind-mounts the checkout and
# the action directory, and hands off to entrypoint.sh inside the container,
# which boots the VVD, waits for readiness, runs the user script, and captures a
# screenshot.
#
# GitHub step outputs (screenshot, boot-status) are written by the container to a
# bridge file under the mounted workspace (the container cannot write the
# runner's real $GITHUB_OUTPUT), which we append to $GITHUB_OUTPUT afterwards.
set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE not set (this script runs inside a GitHub Action)}"
: "${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH not set}"
: "${VVD_IMAGE:?image input not set}"

# Bridge file for step outputs: created on the host (so the runner user owns it),
# written by the container as /workspace/<name>, read back here.
bridge_name=".vvd_output_$$"
bridge_host="${GITHUB_WORKSPACE}/${bridge_name}"
: > "$bridge_host"
trap 'rm -f "$bridge_host"' EXIT

rc=0
# VVD_CONTAINER_OPTS is intentionally unquoted to allow multiple extra flags.
# shellcheck disable=SC2086
docker run --rm \
  --privileged --device /dev/kvm --init \
  -v "${GITHUB_WORKSPACE}:/workspace" \
  -v "${GITHUB_ACTION_PATH}:/action:ro" \
  -e VVD_SCRIPT \
  -e VVD_PRE_LAUNCH \
  -e VVD_BOOT_TIMEOUT \
  -e VVD_WORKDIR \
  -e VVD_CAPTURE \
  -e VVD_SHOT_PATH \
  -e "GITHUB_OUTPUT=/workspace/${bridge_name}" \
  ${VVD_CONTAINER_OPTS:-} \
  --entrypoint /action/entrypoint.sh \
  "$VVD_IMAGE" || rc=$?

# Propagate the container's step outputs to the real runner output file.
if [[ -n "${GITHUB_OUTPUT:-}" && -s "$bridge_host" ]]; then
  cat "$bridge_host" >> "$GITHUB_OUTPUT"
fi

exit "$rc"
