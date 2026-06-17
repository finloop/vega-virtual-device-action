#!/usr/bin/env bash
# Shared Argent (Vega) bootstrap helpers for the example scripts that drive a
# booted VVD. SOURCE this file — do not execute it.
#
# Requires node, npm, adb, python3 and curl on PATH — all baked into the
# vega-virtual-device-host image. Provides:
#   argent_install        install the Argent CLI from $ARGENT_TARBALL (idempotent)
#   argent_start_server   start a detached shared tool-server; export ARGENT_TOOLS_URL
#   adb_wait_device       ensure adb sees the VVD
#   argent_vega_serial    echo the amazon-… Vega serial (stdout), retrying on miss
#   nonblack <png>        exit 0 if the PNG is >2% non-zero bytes, else 1

# Pin the Argent (Vega variant) build. The classification fix this needs is only
# in the finloop fork; see argent-screenshot-test.sh's header note.
ARGENT_TARBALL="${ARGENT_TARBALL:-https://github.com/finloop/argent/releases/download/v0.10.2-vega/swmansion-argent-0.10.2-vega.tgz}"
ARGENT_PORT="${ARGENT_PORT:-3001}"

argent_install() {
  # Skip when a usable argent is already on PATH (fast local re-runs); set
  # ARGENT_FORCE_INSTALL=1 to always (re)install the pinned tarball. In CI the
  # container is fresh, so this always installs.
  if [ -z "${ARGENT_FORCE_INSTALL:-}" ] && command -v argent >/dev/null 2>&1; then
    echo "argent already on PATH: $(argent --version 2>/dev/null)"
    return 0
  fi
  echo "::group::Install Argent (${ARGENT_TARBALL##*/})"
  if ! npm install -g "$ARGENT_TARBALL" >/tmp/argent-install.log 2>&1; then
    tail -20 /tmp/argent-install.log; return 1
  fi
  echo "argent $(argent --version)"
  echo "::endgroup::"
}

argent_start_server() {
  # Run a persistent shared tool-server and point `argent run` at it via
  # ARGENT_TOOLS_URL. Without this, a cold `argent run` spawns its OWN ephemeral
  # server and blocks until that server's idle timeout before returning. A shared
  # server makes each call a fast client request AND keeps the Vega inventory warm
  # (so the amazon-… serial classifies as Vega, not Android → simulator-server).
  #
  # Start it fully detached: `argent server start --detach` does not reliably
  # return when stdout is a pipe (as in CI), so background a foreground server
  # ourselves with redirected fds. Detach with setsid where available (Linux/CI)
  # and fall back to nohup (e.g. macOS, for local dry-runs) — both keep the server
  # alive independent of this script's controlling terminal.
  echo "::group::Start Argent tool-server (port ${ARGENT_PORT})"
  local server_cmd="argent server start --no-auth --idle-timeout 0 --port ${ARGENT_PORT}"
  if curl -fsS -o /dev/null "http://127.0.0.1:${ARGENT_PORT}/tools" 2>/dev/null; then
    echo "tool-server already running on ${ARGENT_PORT}"
  elif command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$server_cmd" </dev/null >/tmp/argent-server.log 2>&1 &
    disown 2>/dev/null || true
  else
    nohup bash -c "$server_cmd" </dev/null >/tmp/argent-server.log 2>&1 &
    disown 2>/dev/null || true
  fi
  export ARGENT_TOOLS_URL="http://127.0.0.1:${ARGENT_PORT}"
  local ready=""
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${ARGENT_PORT}/tools" 2>/dev/null; then ready=1; break; fi
    sleep 1
  done
  if [ -z "$ready" ]; then
    echo "ERROR: Argent tool-server did not become ready"; cat /tmp/argent-server.log 2>/dev/null; return 1
  fi
  echo "::endgroup::"
}

adb_wait_device() {
  echo "::group::adb sees the VVD"
  adb start-server >/dev/null 2>&1 || true
  if ! timeout 60 adb wait-for-device; then echo "ERROR: adb never saw the device"; return 1; fi
  adb devices -l
  echo "::endgroup::"
}

# Slice the JSON object out of `argent run --json` output (it prints an update
# banner first) and echo the first vega device's serial, or nothing.
_extract_vega_serial() {
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

# Echo the Vega serial on stdout. `vega device list` only enumerates the device a
# short while after boot, so retry until the Vega entry appears. Progress goes to
# stderr to keep stdout capturable: SERIAL="$(argent_vega_serial)".
argent_vega_serial() {
  local serial=""
  for attempt in $(seq 1 12); do
    serial="$(argent run list-devices --json 2>/dev/null | _extract_vega_serial)"
    [ -n "$serial" ] && break
    echo "attempt ${attempt}: no Vega device yet; retrying..." >&2
    sleep 5
  done
  printf '%s' "$serial"
}

# nonblack <png> [min_frac] — exit 0 if the PNG's non-zero-byte fraction exceeds
# min_frac (default 0.02), i.e. it rendered something; else 1. Prints
# "WxH nonblack_frac=…" to stderr. Decodes IDAT directly — no Pillow needed.
# A lower min_frac suits dark UIs (e.g. a media app: black background + sparse
# text sits around 0.01), while a fully-black/broken frame is ~0.000.
nonblack() {
  python3 - "$1" "${2:-0.02}" <<'PY'
import sys, zlib, struct
min_frac = float(sys.argv[2])
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
sys.exit(0 if frac > min_frac else 1)
PY
}
