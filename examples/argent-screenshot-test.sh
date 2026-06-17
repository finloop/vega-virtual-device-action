#!/usr/bin/env bash
# Test Argent's (Vega variant) screenshot tool against a running VVD.
#
# Run INSIDE the vega-virtual-device-host container with the VVD already booted
# and ready — e.g. as the `script:` of vega-virtual-device-action. Produces
# artifacts/argent-vega.png and fails if it is black.
#
# The image already provides Node 20, adb, and ANDROID_HOME (baked into the
# Dockerfile). Argent's Vega screenshot captures via `adb emu screenrecord`
# (host-side); real adb auto-detects the VVD on tcp:5555 as emulator-5554.
#
# NOTE: requires an Argent build whose device classification refreshes the Vega
# inventory on a miss (otherwise a cold `screenshot` misclassifies the amazon-…
# serial as Android and routes to the glibc-2.39 simulator-server). The pinned
# ARGENT_TARBALL in lib/argent-common.sh is such a build; override that env var to
# test another release. The shared bootstrap (install Argent, start the tool-server,
# discover the Vega serial, the nonblack check) lives in lib/argent-common.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=examples/lib/argent-common.sh
source "${HERE}/lib/argent-common.sh"

OUT_DIR="${OUT_DIR:-artifacts}"
mkdir -p "$OUT_DIR"

echo "::group::Environment"
echo "node $(node -v)"
adb version | head -1
echo "ANDROID_HOME=${ANDROID_HOME:-<unset>}"
echo "::endgroup::"

argent_install
argent_start_server
adb_wait_device

echo "::group::Discover Vega device"
VEGA_SERIAL="$(argent_vega_serial)"
if [ -z "$VEGA_SERIAL" ]; then
  echo "ERROR: no Vega device in argent list-devices after retries"; exit 1
fi
echo "Vega serial: $VEGA_SERIAL"
echo "::endgroup::"

echo "::group::Argent screenshot"
SHOT="$OUT_DIR/argent-vega.png"
# Use the Vega serial (amazon-…), NOT emulator-5554: the adb serial routes to
# Argent's simulator-server backend, the Vega serial uses `adb emu screenrecord`.
captured=""
for attempt in 1 2 3 4 5; do
  rm -f "$SHOT"
  # Keep the last attempt's output so a persistent failure is debuggable instead
  # of just "missing/black" with no Argent error.
  argent run screenshot --udid "$VEGA_SERIAL" --out "$SHOT" --json >/tmp/argent-screenshot.log 2>&1 || true
  if nonblack "$SHOT"; then captured=1; break; fi
  echo "attempt ${attempt}: screenshot missing/black; retrying..."
  sleep 5
done
if [ -z "$captured" ]; then
  echo "ERROR: no non-black Argent screenshot"
  echo "--- last 'argent run screenshot' output ---"; tail -30 /tmp/argent-screenshot.log
  exit 1
fi
echo "OK: Argent Vega screenshot is non-black -> ${OUT_DIR}/argent-vega.png"
echo "::endgroup::"
