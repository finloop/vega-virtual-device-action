#!/usr/bin/env bash
# Build and run the sample Vega app end-to-end against a running VVD.
#
# Run INSIDE the vega-virtual-device-host container with the VVD already booted
# and ready — e.g. as the `script:` of vega-virtual-device-action. It:
#   1. scaffolds a fresh app from the hello-world Vega template,
#   2. builds the RELEASE vpkg,
#   3. installs + launches it on the VVD,
#   4. waits for it to be running so the action's post-script screenshot shows it.
#
# The image already provides the Vega SDK (vega CLI), Node 20 and npm (baked into
# the Dockerfile). The action captures the screenshot after this script returns,
# so the final step just waits for the app to render.
set -euo pipefail

APP_NAME="${APP_NAME:-HelloVega}"
# Don't use `amazon` as the company/package id (reserved per Vega CLI docs).
PACKAGE_ID="${PACKAGE_ID:-com.vegacicd.hellovega}"
APP_DIR="${APP_DIR:-hello-vega}"
TEMPLATE="${TEMPLATE:-helloWorld}"
APP_ID="${PACKAGE_ID}.main"

echo "::group::Environment"
echo "vega $(vega -v 2>/dev/null || echo '<unknown>')"
echo "node $(node -v)"
echo "npm  $(npm -v)"
echo "::endgroup::"

# The CLI device name (e.g. VirtualDevice / Simulator) is whatever `vega device
# list` reports for the booted VVD — resolve it instead of hardcoding, since the
# label differs across SDK versions. DEVICE can be overridden via env.
resolve_device() {
  vega device list 2>/dev/null | awk -F' *: *' '/ : / {print $1; exit}'
}
DEVICE="${DEVICE:-}"
if [ -z "$DEVICE" ]; then
  echo "::group::Resolve VVD device name"
  for attempt in $(seq 1 12); do
    DEVICE="$(resolve_device)"
    [ -n "$DEVICE" ] && break
    echo "attempt ${attempt}: no device in 'vega device list' yet; retrying..."
    sleep 5
  done
  echo "::endgroup::"
fi
if [ -z "$DEVICE" ]; then
  echo "ERROR: no device found via 'vega device list'"; vega device list || true; exit 1
fi
echo "Using device: ${DEVICE}"

echo "::group::Create app from '${TEMPLATE}' template"
vega project list-templates
# Generate into a clean directory so reruns on a warm checkout don't collide.
# Template names are camelCase (e.g. helloWorld) — see `vega project list-templates`.
rm -rf "$APP_DIR"
vega project generate \
  --template "$TEMPLATE" \
  --name "$APP_NAME" \
  --packageId "$PACKAGE_ID" \
  --outputDir "$APP_DIR"
echo "::endgroup::"

cd "$APP_DIR"

echo "::group::Install dependencies"
npm install
echo "::endgroup::"

echo "::group::Build release"
npm run build:release
echo "Build artifacts:"
ls -R build 2>/dev/null || true
echo "::endgroup::"

echo "::group::Install release build on ${DEVICE}"
# --dir . auto-detects the device architecture and picks the matching .vpkg.
vega device install-app --dir . -b Release --device "$DEVICE"
echo "::endgroup::"

echo "::group::Launch app (${APP_ID})"
vega device launch-app --dir . --device "$DEVICE"
echo "::endgroup::"

echo "::group::Wait for app to be running"
running=""
for attempt in $(seq 1 30); do
  if vega device running-apps --device "$DEVICE" 2>/dev/null | grep -q "$PACKAGE_ID"; then
    running=1; echo "app ${APP_ID} is running"; break
  fi
  echo "attempt ${attempt}: ${APP_ID} not running yet; retrying..."
  sleep 2
done
if [ -z "$running" ]; then
  echo "WARNING: ${APP_ID} not seen in running-apps; screenshotting anyway"
  vega device running-apps --device "$DEVICE" || true
fi
# Give the UI a moment to render before the action captures the screenshot.
sleep 10
echo "::endgroup::"
