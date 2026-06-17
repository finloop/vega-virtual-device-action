#!/usr/bin/env bash
# Drive the pre-installed Kepler Video App on a booted VVD with **Appium** and
# screenshot every step — the Appium analogue of examples/argent-navigation-test.sh.
#
# Run INSIDE the vega-virtual-device-host container with the VVD booted and ready —
# e.g. as the `script:` of vega-virtual-device-action. This bootstrap:
#   1. installs Appium + the Vega "kepler" driver (npm; the image only ships
#      node/npm/adb/vega — like Argent, the test tool is installed at runtime),
#   2. installs the WebdriverIO client (examples/appium/),
#   3. installs the app from $VPKG (a stock VVD has no user apps),
#   4. enables the automation toolkit and starts the Appium server,
#   5. runs examples/appium/navigation_test.mjs, which creates the session,
#      navigates with D-pad key injection and screenshots each step.
#
# The job's pass/fail tracks whether Appium DROVE the app; whether Appium's own
# screenshots read back non-black under software GL (llvmpipe) is reported (set
# SCREENSHOT_POLICY=require to make black frames fail). Produces artifacts/NN-*.png,
# NN-*.txt (page source) and summary.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pinned per https://developer.amazon.com/docs/vega/0.22/appium-install.html;
# override via env / the workflow's dispatch inputs.
APPIUM_VERSION="${APPIUM_VERSION:-2.2.2}"
KEPLER_DRIVER_VERSION="${KEPLER_DRIVER_VERSION:-3.30.0}"
APPIUM_PORT="${APPIUM_PORT:-4723}"
APPIUM_URL="http://127.0.0.1:${APPIUM_PORT}"
APP_ID="${APP_ID:-com.amazondeveloper.keplervideoapp.main}"
PKG_ID="${APP_ID%.main}"
OUT_DIR="${OUT_DIR:-artifacts}"
# Keep the driver install and the server start pointed at the same APPIUM_HOME so
# the server finds the driver we just installed.
export APPIUM_HOME="${APPIUM_HOME:-$HOME/.appium}"
export APP_ID OUT_DIR APPIUM_URL
mkdir -p "$OUT_DIR"

echo "::group::Environment"
echo "node $(node -v)  npm $(npm -v)"
adb version 2>/dev/null | head -1 || true
echo "vega $(vega -v 2>/dev/null || echo '<unset>')"
echo "appium target: ${APPIUM_VERSION}  kepler driver: ${KEPLER_DRIVER_VERSION}"
echo "app: ${APP_ID}"
echo "::endgroup::"

echo "::group::Install Appium ${APPIUM_VERSION} + kepler driver ${KEPLER_DRIVER_VERSION}"
# Capture command output into a var before matching it: piping a longer-running
# producer straight into `grep -q` trips `set -o pipefail` — grep closes the pipe
# on its first match, the producer gets SIGPIPE, and the pipeline then reports
# failure even though the match succeeded.
appium_v="$(appium --version 2>/dev/null | tail -1)"
if [ "$appium_v" = "${APPIUM_VERSION}" ]; then
  echo "appium ${APPIUM_VERSION} already on PATH"
else
  npm install -g "appium@${APPIUM_VERSION}" >/tmp/appium-install.log 2>&1 \
    || { echo "ERROR: appium install failed"; tail -30 /tmp/appium-install.log; exit 1; }
  echo "appium $(appium --version 2>/dev/null | tail -1)"
fi
# The @amazon-devices/* packages are public on npm (see Dockerfile note), so no
# private-registry auth is needed for the driver. Install is idempotent: if it's
# already present we skip; if an install attempt races "already installed" we
# re-check rather than fail.
drivers="$(appium driver list --installed 2>&1 || true)"
case "$drivers" in
  *kepler*) echo "kepler driver already installed" ;;
  *)
    appium driver install --source=npm "@amazon-devices/appium-kepler-driver@${KEPLER_DRIVER_VERSION}" \
      >/tmp/appium-driver-install.log 2>&1 || true
    drivers="$(appium driver list --installed 2>&1 || true)"
    case "$drivers" in
      *kepler*) echo "kepler driver installed" ;;
      *) echo "ERROR: kepler driver not installed"; tail -40 /tmp/appium-driver-install.log; exit 1 ;;
    esac
    ;;
esac
echo "::endgroup::"

echo "::group::Install WebdriverIO client"
( cd "${HERE}/appium" && npm install --no-audit --no-fund ) >/tmp/wdio-install.log 2>&1 \
  || { echo "ERROR: webdriverio install failed"; tail -30 /tmp/wdio-install.log; exit 1; }
echo "webdriverio $(cd "${HERE}/appium" && node -p "require('webdriverio/package.json').version" 2>/dev/null || echo '?')"
echo "::endgroup::"

echo "::group::Devices (informational)"
# The action only runs this script once the VVD is up (it gates on a non-black
# screen), so the device is present. Appium talks to it via the `vda` bridge
# (kepler:device=vda://default); these are just for the log.
adb start-server >/dev/null 2>&1 || true
adb devices -l 2>/dev/null || true
vega exec vda devices 2>&1 || echo "WARN: 'vega exec vda devices' failed (continuing)"
echo "::endgroup::"

echo "::group::Ensure ${PKG_ID} is installed"
# A stock VVD has NO pre-installed user apps, so install from $VPKG if provided
# (CI downloads the prebuilt vpkg from the repo release). On a device that already
# has it (local dev VVD) install-app is harmless; tolerate "already installed".
if [ -n "${VPKG:-}" ] && [ -f "${VPKG}" ]; then
  echo "Installing ${PKG_ID} from ${VPKG}"
  vega device install-app -p "${VPKG}" \
    || echo "WARN: install-app returned non-zero (already installed?) — continuing"
else
  echo "No VPKG provided/found; assuming ${PKG_ID} is already installed."
fi
echo "::endgroup::"

echo "::group::Enable automation toolkit"
# Appium drives the app through the automation toolkit; create its enable file on
# the device (per appium-setup.html). It must exist BEFORE the app launches so the
# toolkit attaches — the Appium session (appURL) launches the app afterwards.
vega exec vda shell "touch /tmp/automation-toolkit.enable" 2>/dev/null \
  || vega exec vda touch /tmp/automation-toolkit.enable 2>/dev/null \
  || echo "WARN: could not create /tmp/automation-toolkit.enable (continuing)"
echo "::endgroup::"

echo "::group::Ensure 'vda' is on PATH (the kepler driver shells out to it)"
# The Appium kepler driver invokes the `vda` device bridge as a bare command, but
# the Vega SDK ships it only as `vega exec vda` — there is no standalone `vda` on
# PATH, in the host image either (/root/vega/bin has vega + kepler/vvman symlinks,
# no vda). Install a tiny shim that forwards to `vega exec vda` so the Appium
# server (started below, inheriting this PATH) can reach the device. The Appium
# docs call this out: "Add vda to your global PATH to enable Appium communication."
if command -v vda >/dev/null 2>&1; then
  echo "vda already on PATH: $(command -v vda)"
else
  SHIM_DIR="${TMPDIR:-/tmp}/vda-shim"
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/vda" <<'EOF'
#!/usr/bin/env bash
# Shim: the Vega SDK exposes the device bridge as `vega exec vda`, not a bare
# `vda`. Forward everything through so tools that call `vda` directly work.
exec vega exec vda "$@"
EOF
  chmod +x "$SHIM_DIR/vda"
  export PATH="$SHIM_DIR:$PATH"
  echo "installed vda shim -> 'vega exec vda' at $SHIM_DIR/vda"
fi
vda_check="$(vda devices 2>&1 || true)"
printf '%s\n' "$vda_check" | sed 's/^/  /'
echo "::endgroup::"

echo "::group::Start Appium server (port ${APPIUM_PORT})"
# Start fully detached with redirected fds so the server keeps running independent
# of this script (a foregrounded `appium` would block the job; setsid/nohup detach
# it — same pattern as the Argent tool-server in argent-common.sh).
appium_cmd="appium --port ${APPIUM_PORT} --relaxed-security --log-timestamp"
if curl -fsS -o /dev/null "${APPIUM_URL}/status" 2>/dev/null; then
  echo "appium server already running on ${APPIUM_PORT}"
elif command -v setsid >/dev/null 2>&1; then
  setsid bash -c "$appium_cmd" </dev/null >/tmp/appium-server.log 2>&1 &
  disown 2>/dev/null || true
else
  nohup bash -c "$appium_cmd" </dev/null >/tmp/appium-server.log 2>&1 &
  disown 2>/dev/null || true
fi
ready=""
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "${APPIUM_URL}/status" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "ERROR: Appium server did not become ready"; cat /tmp/appium-server.log 2>/dev/null; exit 1
fi
echo "::endgroup::"

echo "::group::Run WebdriverIO navigation test"
node "${HERE}/appium/navigation_test.mjs"
rc=$?
echo "::endgroup::"

if [ "$rc" -ne 0 ]; then
  echo "--- appium server log (tail) ---"
  tail -80 /tmp/appium-server.log 2>/dev/null || true
fi
exit "$rc"
