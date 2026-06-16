#!/usr/bin/env bash
# CI guard: the Vega SDK version must live ONLY in .sdk-version.
#
# Fails if a hardcoded version literal is reintroduced anywhere else — either an
# image tag (sdk-x.y.z) or an assigned VEGA_SDK_VERSION. This keeps the
# single-source-of-truth invariant from silently regressing.
#
# Exempt: .sdk-version itself, the dated historical fix note, and these tools.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# A literal SDK image tag (sdk-1.2.3) or an assigned version (VEGA_SDK_VERSION: "1.2.3").
pattern='sdk-[0-9]+\.[0-9]+\.[0-9]+|VEGA_SDK_VERSION[[:space:]]*[:=][[:space:]]*["'"'"']?[0-9]+\.[0-9]+\.[0-9]+'

if git grep -nE "$pattern" -- \
    ':(exclude).sdk-version' \
    ':(exclude)docs/vvd-docker-screenshot-fix.md' \
    ':(exclude)tools/check-sdk-version.sh' \
    ':(exclude)tools/bump-sdk-version.sh'; then
  {
    echo
    echo "error: hardcoded SDK version found above."
    echo "The version must only live in .sdk-version — use tools/bump-sdk-version.sh."
  } >&2
  exit 1
fi

echo "OK: no hardcoded SDK version outside .sdk-version."
