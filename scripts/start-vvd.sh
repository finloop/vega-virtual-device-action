#!/usr/bin/env bash
# Starts the Vega Virtual Device (VVD) headless inside Docker so that screen
# capture works (non-black) WITHOUT a GPU.
#
# Run the container with:  --privileged --device /dev/kvm --init
# (--network=host is NOT required; this script enables IPv6 loopback itself.)
#
# Why the three fixes below are needed — see docs/vvd-screen-capture.md:
#   1. IPv6 loopback: QEMU binds a gnss chardev on ::1; containers ship with
#      IPv6 disabled on `lo`, so QEMU aborts with "address resolution failed
#      for ::1". Re-enable it.
#   2. -gpu host (NOT swiftshader/swangle/off): only the host-GL path posts a
#      color buffer the emulator can read back. swiftshader_indirect /
#      swangle_indirect render but never post -> screenshot is all black.
#      `vega virtual-device start` resolves the mode to swangle_indirect and
#      offers no override, so we let it create the instance, then relaunch the
#      emulator binary directly with -gpu host.
#   3. Software host GL via Mesa llvmpipe: -gpu host needs a real GL context.
#      With no GPU, force Mesa's llvmpipe (CPU) and give it an Xvfb display.
set -euo pipefail

TIMEOUT=${VVD_BOOT_TIMEOUT:-180}
DISPLAY_NUM=${VVD_DISPLAY:-:99}

# --- 1. IPv6 loopback (QEMU ::1 gnss chardev) ------------------------------
sysctl -w net.ipv6.conf.all.disable_ipv6=0  >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=0   >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
getent hosts ::1 >/dev/null || echo "::1 localhost" >> /etc/hosts

# --- 2. virtual display + software GL --------------------------------------
export DISPLAY="$DISPLAY_NUM"
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export __GLX_VENDOR_LIBRARY_NAME=mesa
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "Starting Xvfb on ${DISPLAY}..."
    Xvfb "$DISPLAY" -screen 0 1920x1080x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
    for _ in {1..30}; do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 0.5; done
fi

export PATH="${HOME}/vega/bin:${PATH}"

# --- 3a. Let the CLI create the instance + download the emulator binary -----
# It boots in swangle (black); we only need the instance dir + emulator argv.
echo "Creating VVD instance (phase 1)..."
vega virtual-device start --gui=false --gl-accel=true >/tmp/vvd-cli.log 2>&1 &

emu_pid=""
for _ in $(seq 1 "$TIMEOUT"); do
    emu_pid=$(pgrep -x vega-virtual-de | head -1 || true)
    [[ -n "$emu_pid" ]] && break
    sleep 1
done
[[ -z "$emu_pid" ]] && { echo "ERROR: emulator never started in phase 1" >&2; cat /tmp/vvd-cli.log >&2; exit 1; }

# Capture the exact argv the CLI used (null-delimited).
mapfile -d '' -t ARGV < "/proc/${emu_pid}/cmdline"
EMU_BIN="${ARGV[0]}"
EMU_ARGS=("${ARGV[@]:1}")
AGENT_DIR="$(cd "$(dirname "$EMU_BIN")/../.." && pwd)"   # .../vmtools/agent

# --- 3b. Relaunch the SAME instance directly with -gpu host -----------------
echo "Relaunching with -gpu host + llvmpipe (phase 2)..."
pkill -9 virtualdevice 2>/dev/null || true
pkill -9 -x node       2>/dev/null || true
pkill -9 vega-virtual-de 2>/dev/null || true
sleep 3
rm -f /tmp/qmp-socket-*.sock

export LD_LIBRARY_PATH="${AGENT_DIR}/lib64/libstdc++:${AGENT_DIR}/lib64/gles_swiftshader:${AGENT_DIR}/lib64"
setsid "$EMU_BIN" -gpu host "${EMU_ARGS[@]}" >/tmp/vvd.log 2>&1 < /dev/null &
disown

echo "Waiting up to ${TIMEOUT}s for the console + boot..."
deadline=$((SECONDS + TIMEOUT))
while true; do
    if pgrep -x vega-virtual-de >/dev/null && \
       (ss -ltn 2>/dev/null | grep -q ':5554'); then
        echo "VVD console is up (host GL). Boot continues in background."
        break
    fi
    if ! pgrep -x vega-virtual-de >/dev/null; then
        echo "ERROR: emulator exited; see /tmp/vvd.log" >&2
        grep -iE '::1|abnormal|error while load|gpu mode' /tmp/vvd.log >&2 || true
        exit 1
    fi
    [[ $SECONDS -ge $deadline ]] && { echo "ERROR: console not up in ${TIMEOUT}s" >&2; exit 1; }
    sleep 3
done

echo "Ready. Capture a screenshot with: scripts/vvd-screenshot.sh /out/shot.png"
