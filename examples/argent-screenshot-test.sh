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
# serial as Android and routes to the glibc-2.39 simulator-server). Point
# ARGENT_TARBALL at that release.
set -euo pipefail

ARGENT_TARBALL="${ARGENT_TARBALL:-https://github.com/finloop/argent/releases/download/v0.10.2-vega/swmansion-argent-0.10.2-vega.tgz}"
OUT_DIR="${OUT_DIR:-artifacts}"
mkdir -p "$OUT_DIR"

echo "::group::Environment"
echo "node $(node -v)"
adb version | head -1
echo "ANDROID_HOME=${ANDROID_HOME:-<unset>}"
echo "::endgroup::"

echo "::group::Install Argent (${ARGENT_TARBALL##*/})"
npm install -g "$ARGENT_TARBALL" >/tmp/argent-install.log 2>&1 || { tail -20 /tmp/argent-install.log; exit 1; }
echo "argent $(argent --version)"
echo "::endgroup::"

echo "::group::Start Argent tool-server"
# Run a persistent shared tool-server and point `argent run` at it via
# ARGENT_TOOLS_URL. Without this, a cold `argent run` spawns its OWN ephemeral
# server and blocks until that server's idle timeout (~30 min) before returning.
# A shared server makes each `argent run` a fast client call AND keeps the Vega
# inventory warm across calls (so the amazon-… serial classifies as Vega, not
# Android → simulator-server).
#
# Start it fully detached with setsid + redirected fds: `argent server start
# --detach` does NOT reliably return when stdout is a pipe (as in CI) and hangs
# the job, so background the foreground server ourselves.
ARGENT_PORT="${ARGENT_PORT:-3001}"
setsid bash -c "argent server start --no-auth --idle-timeout 0 --port ${ARGENT_PORT}" \
  </dev/null >/tmp/argent-server.log 2>&1 &
export ARGENT_TOOLS_URL="http://127.0.0.1:${ARGENT_PORT}"
ready=""
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${ARGENT_PORT}/tools" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "ERROR: Argent tool-server did not become ready"; cat /tmp/argent-server.log; exit 1
fi
echo "::endgroup::"

echo "::group::adb sees the VVD"
adb start-server >/dev/null 2>&1 || true
timeout 60 adb wait-for-device || { echo "ERROR: adb never saw the device"; exit 1; }
adb devices -l
echo "::endgroup::"

echo "::group::Discover Vega device"
# `argent run --json` prints an update banner before the JSON; slice from the
# first '{' and decode just the JSON object. `vega device list` only enumerates
# the device a short while after boot, so retry until the Vega entry appears.
extract_vega_serial() {
  python3 -c '
import sys, json
s = sys.stdin.read()
try:
    obj = json.JSONDecoder().raw_decode(s[s.index("{"):])[0]
except ValueError:
    sys.exit(0)
print(next((d["serial"] for d in obj.get("devices", []) if d.get("platform") == "vega"), ""))
'
}
VEGA_SERIAL=""
for attempt in $(seq 1 12); do
  VEGA_SERIAL="$(argent run list-devices --json 2>/dev/null | extract_vega_serial)"
  [ -n "$VEGA_SERIAL" ] && break
  echo "attempt ${attempt}: no Vega device yet; retrying..."
  sleep 5
done
if [ -z "$VEGA_SERIAL" ]; then
  echo "ERROR: no Vega device in argent list-devices after retries"; exit 1
fi
echo "Vega serial: $VEGA_SERIAL"
echo "::endgroup::"

echo "::group::Argent screenshot"
SHOT="$OUT_DIR/argent-vega.png"
# Use the Vega serial (amazon-…), NOT emulator-5554: the adb serial routes to
# Argent's simulator-server backend, the Vega serial uses `adb emu screenrecord`.
nonblack() {
  python3 - "$1" <<'PY'
import sys, zlib, struct
try:
    d = open(sys.argv[1], "rb").read()
except OSError:
    sys.exit(1)
if d[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit(1)
i, idat, w, h = 8, bytearray(), 0, 0
while i + 8 <= len(d):
    ln = struct.unpack(">I", d[i:i + 4])[0]; t = d[i + 4:i + 8]
    if t == b"IHDR": w, h = struct.unpack(">II", d[i + 8:i + 16])
    if t == b"IDAT": idat += d[i + 8:i + 8 + ln]
    i += 12 + ln
    if t == b"IEND": break
raw = zlib.decompress(bytes(idat))
frac = (len(raw) - raw.count(0)) / len(raw)
sys.stderr.write(f"{w}x{h} nonblack_frac={frac:.4f}\n")
sys.exit(0 if frac > 0.02 else 1)
PY
}
captured=""
for attempt in 1 2 3 4 5; do
  rm -f "$SHOT"
  argent run screenshot --udid "$VEGA_SERIAL" --out "$SHOT" --json >/dev/null 2>&1 || true
  if nonblack "$SHOT"; then captured=1; break; fi
  echo "attempt ${attempt}: screenshot missing/black; retrying..."
  sleep 5
done
if [ -z "$captured" ]; then
  echo "ERROR: no non-black Argent screenshot"; exit 1
fi
echo "OK: Argent Vega screenshot is non-black -> ${OUT_DIR}/argent-vega.png"
echo "::endgroup::"
