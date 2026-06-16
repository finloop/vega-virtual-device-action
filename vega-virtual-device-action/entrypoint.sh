#!/usr/bin/env bash
# Container side of vega-virtual-device-action (runs inside vega-virtual-device-host).
#
# Flow (mirrors reactivecircus/android-emulator-runner): optional pre-launch hook
# -> boot the VVD -> wait until ready -> run the user script -> screenshot ->
# teardown. Deliberately NOT `set -e`: the user script's exit code is captured so
# we still screenshot and tear down on failure, then propagate that code.
set -uo pipefail

: "${HOME:=/root}"
export PATH="${HOME}/vega/bin:/scripts:${PATH}"

WORKDIR="/workspace/${VVD_WORKDIR:-.}"
BOOT_TIMEOUT="${VVD_BOOT_TIMEOUT:-300}"
SHOT_PATH="${VVD_SHOT_PATH:-vvd-screenshot.png}"
CAPTURE="${VVD_CAPTURE:-true}"
OUT="${GITHUB_OUTPUT:-/dev/null}"

emit()  { echo "$1=$2" >> "$OUT"; }
group() { echo "::group::$*"; }
endg()  { echo "::endgroup::"; }

# Capture a screenshot to the user-requested path (no-op if disabled). Used both
# after the script and on the boot-timeout failure path.
capture_shot() {
  [[ "$CAPTURE" == "false" ]] && return 0
  local out="${WORKDIR%/}/${SHOT_PATH}"
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  if /scripts/vvd-screenshot.sh "$out" >/dev/null 2>&1; then
    emit screenshot "$SHOT_PATH"
    echo "Saved screenshot to ${out}"
  else
    echo "WARNING: screenshot capture failed"
  fi
}

# Readiness heuristic: the VVD guest has no getprop/systemctl, and
# `vega virtual-device status` is unreliable for our direct-launch path, so we
# gate on a non-black framebuffer — the proven, quantifiable "device shows real
# UI" signal (a black capture decompresses to ~all-zero bytes; the live home
# screen is high-signal). Exit 0 if non-black, 1 if black, 2 if unreadable.
is_nonblack() {
  python3 - "$1" <<'PY'
import sys, zlib, struct
try:
    d = open(sys.argv[1], "rb").read()
except OSError:
    sys.exit(2)
if d[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit(2)
i, idat = 8, bytearray()
while i + 8 <= len(d):
    ln = struct.unpack(">I", d[i:i + 4])[0]
    typ = d[i + 4:i + 8]
    if typ == b"IDAT":
        idat += d[i + 8:i + 8 + ln]
    i += 12 + ln
    if typ == b"IEND":
        break
try:
    raw = zlib.decompress(bytes(idat))
except zlib.error:
    sys.exit(2)
if not raw:
    sys.exit(1)
frac = (len(raw) - raw.count(0)) / len(raw)
sys.stderr.write("nonblack_frac=%.4f\n" % frac)
sys.exit(0 if frac > 0.02 else 1)
PY
}

# 1. Optional pre-launch hook (before the VVD starts).
if [[ -n "${VVD_PRE_LAUNCH:-}" ]]; then
  group "VVD pre-launch script"
  if ! ( cd "$WORKDIR" && bash -c "$VVD_PRE_LAUNCH" ); then
    echo "pre-launch script failed"; emit boot-status failed; endg; exit 1
  fi
  endg
fi

# 2. Boot the VVD. start-vvd.sh is run (not sourced) so its `set -e`/`exit` stay
#    contained; it backgrounds the emulator (setsid & disown) so it outlives the
#    script and returns once the emulator console is up.
group "Boot Vega Virtual Device"
if ! VVD_BOOT_TIMEOUT="$BOOT_TIMEOUT" /scripts/start-vvd.sh; then
  echo "VVD failed to start"; emit boot-status failed; endg; exit 1
fi
endg

# 3. Re-export the GL/display/console env start-vvd.sh set in its own process, so
#    the readiness gate and the user script also use the llvmpipe software-GL path.
export DISPLAY=:99 \
       LIBGL_ALWAYS_SOFTWARE=1 \
       GALLIUM_DRIVER=llvmpipe \
       __GLX_VENDOR_LIBRARY_NAME=mesa \
       MESA_LOADER_DRIVER_OVERRIDE=llvmpipe \
       VVD_CONSOLE_PORT="${VVD_CONSOLE_PORT:-5554}"

# 4. Readiness gate (bounded by boot-timeout): adapter up, then non-black screen.
group "Wait for VVD ready (timeout ${BOOT_TIMEOUT}s)"
timeout 60 vega exec vda wait-for-device >/dev/null 2>&1 || true
status="timeout"
probe="$(mktemp -d)/probe.png"
deadline=$((SECONDS + BOOT_TIMEOUT))
while (( SECONDS < deadline )); do
  if /scripts/vvd-screenshot.sh "$probe" >/dev/null 2>&1 && is_nonblack "$probe"; then
    status="ready"; break
  fi
  sleep 5
done
emit boot-status "$status"
echo "boot-status=${status}"
endg
if [[ "$status" != "ready" ]]; then
  echo "VVD did not reach a ready screen within ${BOOT_TIMEOUT}s"
  capture_shot
  exit 1
fi

# 5. Run the user script (exit code captured; failure does not skip teardown).
group "Run script"
cd "$WORKDIR" || { echo "working-directory ${WORKDIR} not found"; exit 1; }
bash -c "$VVD_SCRIPT"
script_rc=$?
endg

# 6. Screenshot (success or failure, if enabled).
capture_shot

# 7. Teardown.
vega virtual-device stop >/dev/null 2>&1 || pkill -9 vega-virtual-de 2>/dev/null || true

exit "$script_rc"
