# Fixing VVD Screenshots in Docker (no GPU) — Full Walkthrough

**Status:** ✅ Working · **Date:** 2026-06-15 · **Image:** `vega-virtual-device-host:sdk-0.22.5600`

A non-black screenshot of the Vega Virtual Device, captured **inside Docker on a
machine with no GPU** (pure CPU/llvmpipe software rendering):

![VVD screenshot from Docker](vvd-docker-screenshot.png)

`1920×1080`, `1,853,706 / 2,073,600` non-black pixels. This is the real
"Kepler Virtual Device is ready" home screen — not a window grab, captured via
the emulator console from inside the container.

---

## TL;DR — the three things that were wrong

The existing `start-vvd.sh` forced `hw.gpu.mode = swiftshader_indirect` and
`--gl-accel=false`. Both produce a **black** image. The fix is three changes:

1. **Enable IPv6 on loopback.** QEMU binds a GNSS chardev on `::1`; containers
   ship with IPv6 disabled on `lo`, so QEMU aborts before booting.
2. **Use `-gpu host`, not swiftshader/swangle/off.** Only the host-GL path posts
   a color buffer the emulator can read back. The CLI won't emit `-gpu host`, so
   we relaunch the emulator binary directly.
3. **Provide a software host-GL context (Mesa llvmpipe) + an Xvfb display.**
   `-gpu host` needs a real GL context; with no GPU, llvmpipe (CPU) supplies it.

**No GPU is required.** The renderer that did the work is
`llvmpipe (LLVM 22.1.3)` from `swrast_dri.so`.

---

## Run the container

```bash
docker run -d --name vvd \
  --privileged --device /dev/kvm --init \
  --entrypoint /bin/bash vega-virtual-device-host:sdk-0.22.5600 -c 'sleep infinity'
```

- `--device /dev/kvm` — the emulator needs KVM.
- `--init` — **critical.** PID 1 must reap zombies. The default
  `bash sleep infinity` does not, so killed emulators linger as `<defunct>` and
  the SDK's "virtual device is already running. pid=N" check keys on the zombie,
  blocking every relaunch.
- `--network=host` is **not** needed (the script fixes `::1` itself), which keeps
  the container network-isolated.

## What the image needs

Already present in `vega-virtual-device-host`, but make them explicit in the Dockerfile:

- `libgl1-mesa-dri` → provides `swrast_dri.so` (llvmpipe). **This is the renderer.**
- `xvfb`, `x11-utils` → virtual display + `xdpyinfo`.
- `libgl1`, `libegl1`, `libx11-xcb1`, `libxcb1` → GL/X loaders.
- `python3` → console capture + screenshot save.

## The procedure (what `scripts/start-vvd.sh` automates)

### 1. Enable IPv6 loopback
```bash
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.lo.disable_ipv6=0
```
Without this the emulator dies with:
```
-chardev socket,...host=::1,...id=gnss: address resolution failed for ::1: Name or service not known
QEMU main loop exits abnormally with code 1
```

### 2. Start Xvfb + export software-GL env
```bash
export DISPLAY=:99
Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
       __GLX_VENDOR_LIBRARY_NAME=mesa MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
```

### 3. Phase 1 — let the CLI create the instance & download the binary
```bash
vega virtual-device start --gui=false --gl-accel=true &
```
- The x86_64 emulator binary (`vega-virtual-device`, ~22 MB) is **not shipped in
  the image** — it is downloaded on the first `start`. You cannot pre-shim it.
- The CLI resolves `hw.gpu.mode = swangle_indirect` (software ANGLE) regardless of
  `config.ini` — this boots but captures **black**. We only use phase 1 to create
  the instance dir and grab the emulator's exact argv.

### 4. Phase 2 — relaunch the same instance directly with `-gpu host`
Read the running emulator's argv, kill the CLI chain, relaunch the binary with
`-gpu host` prepended (it must come before `-qemu`):
```bash
mapfile -d '' -t ARGV < /proc/$(pgrep -x vega-virtual-de)/cmdline
pkill -9 virtualdevice; pkill -9 -x node; pkill -9 vega-virtual-de; sleep 3
AGENT=.../vmtools/agent
export LD_LIBRARY_PATH=$AGENT/lib64/libstdc++:$AGENT/lib64/gles_swiftshader:$AGENT/lib64
setsid "${ARGV[0]}" -gpu host "${ARGV[@]:1}" &
```
- `LD_LIBRARY_PATH` is required so `libvirglrenderer.1.so` loads (the CLI sets it;
  a direct launch must set it too, else: `error while loading shared libraries:
  libvirglrenderer.1.so`).
- The emulator log should show `library_mode host  gpu mode host` and only a
  harmless `Failed to create Vulkan instance` (it falls back to GL).
- A direct launch **does** open the telnet console on `5554` once `::1` works.

### 5. Capture (the only non-black path)
The emulator console `screenrecord screenshot` reads the gfxstream color buffer:
```bash
# auth token in ~/.emulator_console_auth_token, console on 127.0.0.1:5554
printf 'auth %s\nscreenrecord screenshot /out/\nquit\n' "$(cat ~/.emulator_console_auth_token)" \
  | some-telnet 127.0.0.1 5554
```
`scripts/vvd-screenshot.sh /out/shot.png` does this in Python.
**Do not** use QMP `screendump` — it reads the emulated display scanout and is
always black, GPU or not.

---

## Dead-ends & gotchas (so you don't repeat them)

| Symptom | Cause | Fix |
|---|---|---|
| Screenshot 10,579 bytes, all `(0,0,0)` | `swangle_indirect` / `swiftshader_indirect` — renders but never posts a color buffer | `-gpu host` |
| `address resolution failed for ::1` → exit 1 | IPv6 disabled on `lo` in the container | `sysctl ...disable_ipv6=0` |
| `error while loading shared libraries: libvirglrenderer.1.so` | direct launch lacks the launcher's lib path | set `LD_LIBRARY_PATH` to `agent/lib64*` |
| `Failed to launch: virtual device is already running. pid=N` where N is `<defunct>` | PID 1 (`bash`) doesn't reap zombies | run container with `--init` |
| Shim over the emulator binary disappears | the SDK re-extracts the binary on each `start` | don't shim; relaunch the binary directly (phase 2) |
| Direct launch has no telnet console | earlier it was crashing on `::1` before opening the console | fix `::1` first |
| `Failed to create Vulkan instance` | no Vulkan in the container | harmless — GL fallback is what we use |

## Proof that it is software rendering (no GPU)

```
$ glxinfo  # with the env above
OpenGL renderer string: llvmpipe (LLVM 22.1.3, 256 bits)
```
The running emulator had `/usr/lib/x86_64-linux-gnu/dri/swrast_dri.so` mapped and
produced the 1 MB non-black PNG above. A real GPU only makes it faster; for
static-UI screenshots llvmpipe is sufficient.
