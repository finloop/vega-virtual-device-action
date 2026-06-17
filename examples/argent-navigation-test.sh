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

# --- navigation flow -------------------------------------------------------
# Key counts are tuned to the Kepler Video App layout; non-black assertions are
# robust to small layout shifts (the app, not its exact geometry, is what matters).
echo "::group::Launch Kepler Video App"
argent run launch-app --udid "$SERIAL" --bundleId "$APP_ID" >/dev/null 2>&1 || true
settle 6
capture home                       # browse: hero banner + Latest Hits + Classics
echo "::endgroup::"

echo "::group::Browse carousels"
press down;    settle 2; capture row-latest-hits   # focus first card (focus scales it up)
press right 3; settle 2; capture row-scrolled      # carousel scrolled right
press down;    settle 2; capture row-classics      # second row (Classics)
echo "::endgroup::"

echo "::group::Open details + play"
press up;      settle 1            # back up to a focused content card
press select;  settle 3; capture details            # details page (Play / Add / Rent + Related)
press select;  settle 6; capture player 0           # video player (BEST-EFFORT, may be black)
press back;    settle 2; capture details-return     # back on details
press back;    settle 2; capture browse-return      # back on browse
echo "::endgroup::"

echo "::group::Side navigation"
press left 8;  settle 2; capture nav-rail           # left rail expands (Home/Search/Settings)
press up 3;    settle 1                              # clamp focus to the top of the rail (Home)
press down 2;  settle 1                              # Home -> Search -> Settings (deterministic from top)
press select;  settle 3; capture settings           # Settings screen (device info, gradient bg)
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
