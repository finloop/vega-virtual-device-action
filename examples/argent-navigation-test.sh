#!/usr/bin/env bash
# Navigate the pre-installed-in-CI Kepler Video App on a booted VVD and screenshot
# every step — a software-GL rendering smoke test. It exercises focus changes,
# carousel scrolling and full screen transitions (browse → details → player →
# settings), so a run of distinct, non-black frames is direct proof the CPU render
# path (Mesa llvmpipe) keeps drawing correctly as the UI changes.
#
# Run INSIDE the vega-virtual-device-host container with the VVD booted and ready —
# e.g. as the `script:` of vega-virtual-device-action.
#
# INPUT: D-pad input is injected with `inputd-cli` over `adb shell`. Argent's own
# automation channel (its `remote`/`describe`) does NOT function on the CI VVD —
# only screenshots do — so we drive the device's input daemon directly. Screenshots
# still go through Argent (that path works). The app is installed from $VPKG if the
# device doesn't already have it (a stock VVD has no user apps).
#
# Rendering caveats: the sample app's UI renders fully in CI (posters + hero art).
# The video PLAYER frame is best-effort — its surface may not read back through the
# emulator console under software GL — so it never fails the run; every other screen
# is asserted non-black.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=examples/lib/argent-common.sh
source "${HERE}/lib/argent-common.sh"

OUT_DIR="${OUT_DIR:-artifacts}"
APP_ID="${APP_ID:-com.amazondeveloper.keplervideoapp.main}"
PKG_ID="${APP_ID%.main}"                 # com.amazondeveloper.keplervideoapp
MIN_FRAC="${MIN_NONBLACK_FRAC:-0.004}"   # dark UI: rendered ~0.01+, black ~0.000
mkdir -p "$OUT_DIR"

echo "::group::Environment"
echo "node $(node -v)"; adb version | head -1; echo "argent target: ${ARGENT_TARBALL##*/}"
echo "app: ${APP_ID}"
echo "::endgroup::"

argent_install      || exit 1
argent_start_server || exit 1
adb_wait_device     || exit 1

echo "::group::Discover Vega device"
SERIAL="$(argent_vega_serial)"           # amazon-… serial, for argent screenshots
[ -n "$SERIAL" ] || { echo "ERROR: no Vega device in argent list-devices after retries"; exit 1; }
# adb serial of the same VVD (e.g. emulator-5554), for shell input injection.
ADB_SERIAL="${ADB_SERIAL:-$(adb devices | awk '/emulator-/{print $1; exit}')}"
echo "Vega serial: $SERIAL ; adb serial: ${ADB_SERIAL:-<none>}"
[ -n "$ADB_SERIAL" ] || { echo "ERROR: no adb device for shell input"; exit 1; }
echo "::endgroup::"

echo "::group::Ensure Kepler Video App is installed"
# A stock VVD has NO pre-installed user apps; install from $VPKG if absent (CI
# downloads the prebuilt vpkg from the repo release). No-op on a warm dev VVD.
if argent run list-installed-apps --udid "$SERIAL" 2>/dev/null | grep -q "$PKG_ID"; then
  echo "$PKG_ID already installed."
elif [ -n "${VPKG:-}" ] && [ -f "$VPKG" ]; then
  echo "Installing $PKG_ID from $VPKG"
  vega device install-app -p "$VPKG"     # --device optional: only the VVD is present
else
  echo "ERROR: $PKG_ID is not installed and no usable VPKG was provided."
  echo "Set VPKG to a keplervideoapp_aarch64.vpkg (CI downloads it from the release), or pre-install the app."
  exit 1
fi
echo "::endgroup::"

# --- input over adb shell --------------------------------------------------
devsh() { adb -s "$ADB_SERIAL" shell "$@"; }
# Map friendly button names to inputd-cli keycodes (select = ENTER, not SELECT).
_keycode() {
  case "$1" in
    up) echo KEY_UP;; down) echo KEY_DOWN;; left) echo KEY_LEFT;; right) echo KEY_RIGHT;;
    select) echo KEY_ENTER;; back) echo KEY_BACK;; home) echo KEY_HOME;; menu) echo KEY_MENU;;
    *) echo "$1";;
  esac
}
key() {  # key <name> [repeat]
  local name="$1" reps="${2:-1}" code i
  code="$(_keycode "$name")"
  for ((i = 0; i < reps; i++)); do
    devsh "inputd-cli button_press $code" >/dev/null 2>&1 || true
    sleep 0.4
  done
}

# Fail loudly if the input channel is dead, rather than silently screenshotting the
# same screen 10 times (Argent's remote does exactly that on the CI VVD).
echo "::group::Input channel health (inputd-cli over adb shell)"
size="$(devsh "inputd-cli get_screen_size" 2>&1 | tr -d '\r')"
echo "inputd-cli get_screen_size -> ${size:-<no output>}"
if ! grep -qE '[0-9]+ *x *[0-9]+' <<<"$size"; then
  echo "ERROR: inputd-cli input channel not usable over adb shell — cannot navigate the app."
  exit 1
fi
echo "::endgroup::"

# --- helpers ---------------------------------------------------------------
step=0
declare -a FAILS=()
declare -a SUMMARY=()

# capture <name> [required] — save element tree (best-effort) + screenshot, assert
# non-black. required defaults to 1 (hard fail on black); pass 0 for best-effort.
capture() {
  local name="$1" required="${2:-1}" tag png tree info
  step=$((step + 1))
  tag="$(printf '%02d-%s' "$step" "$name")"
  png="${OUT_DIR}/${tag}.png"; tree="${OUT_DIR}/${tag}.txt"
  argent run describe --udid "$SERIAL" >"$tree" 2>/dev/null || true   # populated only where the toolkit attaches
  rm -f "$png"
  argent run screenshot --udid "$SERIAL" --out "$png" --json >/dev/null 2>&1 || true
  if info="$(nonblack "$png" "$MIN_FRAC" 2>&1)"; then
    SUMMARY+=("PASS|${tag}|${info}"); echo "  ✓ ${tag} — ${info}"
  elif [ "$required" = "1" ]; then
    FAILS+=("$tag"); SUMMARY+=("FAIL|${tag}|black or missing"); echo "  ✗ ${tag} — BLACK/MISSING (required)"
  else
    SUMMARY+=("WARN|${tag}|black (best-effort)"); echo "  ! ${tag} — black (best-effort, not failing)"
  fi
}

settle() { sleep "${1:-2}"; }

# --- navigation flow -------------------------------------------------------
# Sequence validated against the Kepler Video App via inputd-cli (8/10 distinct
# frames; the 2 repeats are the legitimately re-shown details/browse screens).
# Settles are generous for CI's slower llvmpipe rendering.
echo "::group::Launch Kepler Video App"
argent run launch-app --udid "$SERIAL" --bundleId "$APP_ID" >/dev/null 2>&1 || true
settle 8
capture home                       # browse: hero banner + Latest Hits + Classics
echo "::endgroup::"

echo "::group::Browse carousels"
key down;    settle 3; capture row-latest-hits   # focus first card (focus scales it up)
key right 3; settle 3; capture row-scrolled      # carousel scrolled right
key down;    settle 3; capture row-classics      # second row (Classics)
echo "::endgroup::"

echo "::group::Open details + play"
key up;      settle 2                            # back up to a focused content card
key select;  settle 4; capture details            # details page (Play / Add / Rent + Related)
key select;  settle 8; capture player 0           # video player (BEST-EFFORT, may be black)
key back;    settle 3; capture details-return     # back on details
key back;    settle 3; capture browse-return      # back on browse
echo "::endgroup::"

echo "::group::Side navigation"
key left 8;  settle 3; capture nav-rail           # left rail expands (Home/Search/Settings)
key up 3;    settle 1                             # clamp focus to the top of the rail (Home)
key down 2;  settle 1                             # Home -> Search -> Settings (deterministic from top)
key select;  settle 4; capture settings           # Settings screen (device info, gradient bg)
key back;    settle 2
echo "::endgroup::"

# --- report ----------------------------------------------------------------
echo "::group::Summary"
printf '%s\n' "${SUMMARY[@]}" | sed 's/|/  /g'
echo "::endgroup::"

# Markdown table → artifacts/summary.md (the workflow reads it into the job summary
# and the PR comment); also append to $GITHUB_STEP_SUMMARY when it is set.
{
  echo "### VVD navigation — Kepler Video App (software-GL render check)"
  echo ""
  echo "| Step | Result | Detail |"
  echo "|---|---|---|"
  printf '%s\n' "${SUMMARY[@]}" | awk -F'|' '{printf "| `%s` | %s | %s |\n", $2, $1, $3}'
} | tee "${OUT_DIR}/summary.md" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "${#FAILS[@]}" -ne 0 ]; then
  echo "ERROR: ${#FAILS[@]} required screen(s) black/missing: ${FAILS[*]}"
  exit 1
fi
echo "OK: all required screens rendered non-black -> ${OUT_DIR}/"
