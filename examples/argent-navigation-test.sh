#!/usr/bin/env bash
# Navigate the pre-installed Kepler Video App on a booted VVD and screenshot every
# step — a software-GL rendering smoke test. It exercises focus changes, carousel
# scrolling and full screen transitions (browse → details → player → search), so a
# run of non-black frames is direct proof the CPU render path (Mesa llvmpipe) keeps
# drawing correctly as the UI changes.
#
# Run INSIDE the vega-virtual-device-host container with the VVD booted and ready —
# e.g. as the `script:` of vega-virtual-device-action. Drives the device through
# Argent (the Vega D-pad/automation tool). Produces artifacts/NN-*.png plus
# NN-*.txt element trees, and exits non-zero if any required UI screen is black.
#
# Rendering caveats (see the long investigation in the PR): text and UI chrome
# render reliably, but the sample app's remote poster artwork is not bundled and may
# not resolve, and the video PLAYER surface may not read back through the emulator
# console under software GL. So the player frame is captured BEST-EFFORT (never
# fails the run); every other screen is asserted non-black.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=examples/lib/argent-common.sh
source "${HERE}/lib/argent-common.sh"

OUT_DIR="${OUT_DIR:-artifacts}"
APP_ID="${APP_ID:-com.amazondeveloper.keplervideoapp.main}"
# This app's UI is a dark theme (black background, sparse text, posters that don't
# resolve), so rendered screens sit ~0.7–1.2% non-black while a broken/black frame
# is ~0.00 — a low threshold separates them cleanly. Override via MIN_NONBLACK_FRAC.
MIN_FRAC="${MIN_NONBLACK_FRAC:-0.004}"
mkdir -p "$OUT_DIR"

echo "::group::Environment"
echo "node $(node -v)"; adb version | head -1; echo "argent target: ${ARGENT_TARBALL##*/}"
echo "app: ${APP_ID}"
echo "::endgroup::"

argent_install      || exit 1
argent_start_server || exit 1
adb_wait_device     || exit 1

echo "::group::Discover Vega device"
SERIAL="$(argent_vega_serial)"
[ -n "$SERIAL" ] || { echo "ERROR: no Vega device in argent list-devices after retries"; exit 1; }
echo "Vega serial: $SERIAL"
echo "::endgroup::"

echo "::group::Ensure Kepler Video App is installed"
# A stock VVD has NO pre-installed user apps, so install the app from $VPKG if it
# isn't already present (CI downloads the prebuilt vpkg from the repo's release).
# On a device where it's already installed (e.g. a local dev VVD) this is a no-op.
PKG_ID="${APP_ID%.main}"   # com.amazondeveloper.keplervideoapp
if argent run list-installed-apps --udid "$SERIAL" 2>/dev/null | grep -q "$PKG_ID"; then
  echo "$PKG_ID already installed."
elif [ -n "${VPKG:-}" ] && [ -f "$VPKG" ]; then
  echo "Installing $PKG_ID from $VPKG"
  vega device install-app -p "$VPKG"   # --device optional: only the VVD is present
else
  echo "ERROR: $PKG_ID is not installed and no usable VPKG was provided."
  echo "Set VPKG to a keplervideoapp_aarch64.vpkg (CI downloads it from the release), or pre-install the app."
  exit 1
fi
echo "::endgroup::"

# --- helpers ---------------------------------------------------------------
step=0
declare -a FAILS=()
declare -a SUMMARY=()

press() {  # press <button> [repeat]
  argent run remote --udid "$SERIAL" --button "$1" ${2:+--repeat "$2"} >/dev/null 2>&1 || true
}

# capture <name> [required] — save element tree + screenshot, assert non-black.
# required defaults to 1 (hard fail on black); pass 0 for best-effort frames.
capture() {
  local name="$1" required="${2:-1}" tag png tree info
  step=$((step + 1))
  tag="$(printf '%02d-%s' "$step" "$name")"
  png="${OUT_DIR}/${tag}.png"; tree="${OUT_DIR}/${tag}.txt"
  argent run describe --udid "$SERIAL" >"$tree" 2>/dev/null || true
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

# wait_for <regex> [tries] [sleep] — re-describe until the element tree matches,
# so we screenshot AFTER a transition lands rather than a stale frame. Returns 1
# (and the caller proceeds anyway) if it never matches. Needs the toolkit attached.
wait_for() {
  local re="$1" tries="${2:-6}" nap="${3:-2}" i
  for ((i = 1; i <= tries; i++)); do
    argent run describe --udid "$SERIAL" 2>/dev/null | grep -qiE "$re" && return 0
    sleep "$nap"
  done
  return 1
}

# --- launch + attach automation toolkit ------------------------------------
# The Vega automation toolkit attaches at app launch; on a FRESH install (CI) the
# first launch can race it, leaving an empty tree — the app isn't fully interactive
# yet, so D-pad presses get dropped and screens repeat. Launch, then restart-app
# until describe returns a real UI tree (argent-vega guidance), so the app is loaded
# and focus is deterministic before we navigate.
echo "::group::Launch Kepler Video App + attach toolkit"
argent run launch-app --udid "$SERIAL" --bundleId "$APP_ID" >/dev/null 2>&1 || true
settle 6
for attempt in 1 2 3 4; do
  if wait_for '\[clickable\]' 4 2; then echo "automation toolkit attached (attempt ${attempt})"; break; fi
  echo "toolkit tree empty; restarting app to attach it (attempt ${attempt})..."
  argent run restart-app --udid "$SERIAL" --bundleId "$APP_ID" >/dev/null 2>&1 || true
  settle 8
done
echo "::endgroup::"

# --- navigation flow -------------------------------------------------------
# Key counts are tuned to the Kepler Video App layout; transitions are gated on
# describe (wait_for) so a slow CI render doesn't capture a stale frame.
echo "::group::Browse home"
capture home                       # browse: hero banner + Latest Hits + Classics
echo "::endgroup::"

echo "::group::Browse carousels"
press down;    settle 3; capture row-latest-hits   # focus first card (focus scales it up)
press right 3; settle 3; capture row-scrolled      # carousel scrolled right
press down;    settle 3; capture row-classics      # second row (Classics)
echo "::endgroup::"

echo "::group::Open details + play"
press up;      settle 2                                   # back up to a focused content card
press select;  wait_for 'play-movie' 6 2; settle 2; capture details   # details page
press select;  settle 8; capture player 0                 # video player (BEST-EFFORT, may be black)
press back;    wait_for 'play-movie' 6 2; settle 1; capture details-return
press back;    wait_for 'carousel' 6 2;  settle 1; capture browse-return
echo "::endgroup::"

echo "::group::Side navigation"
press left 8;  settle 3; capture nav-rail           # left rail expands (Home/Search/Settings)
press up 3;    settle 1                              # clamp focus to the top of the rail (Home)
press down 2;  settle 1                              # Home -> Search -> Settings (deterministic from top)
press select;  wait_for 'country code|manufacturer' 6 2; settle 2; capture settings   # Settings screen
press back;    settle 2
echo "::endgroup::"

# --- report ----------------------------------------------------------------
echo "::group::Summary"
printf '%s\n' "${SUMMARY[@]}" | sed 's/|/  /g'
echo "::endgroup::"

# Write a Markdown table to OUT_DIR/summary.md (uploaded as an artifact and read
# into the job summary by the workflow — $GITHUB_STEP_SUMMARY is not passed into
# the action's container). Also append directly when the var IS set (non-container).
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
