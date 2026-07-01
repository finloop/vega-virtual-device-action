#!/usr/bin/env bash
# Bump the centralized Vega SDK version.
#
# The version lives in exactly ONE place: .sdk-version (repo root). The
# Dockerfiles read it at build time, so this is the only file a bump needs to
# change; the action builds the host image from it on each consumer's runner.
#
# Usage:
#   tools/bump-sdk-version.sh             # resolve & write the latest (isLatest) SDK
#   tools/bump-sdk-version.sh 0.22.9999   # write an explicit version
#
# After bumping: open a PR. Consumers pick up the new SDK once they update the
# action ref — no image is published from this repo.
#
# Requires: docker + jq (only when auto-resolving the latest version). Set
# BUILDER_IMAGE to reuse an existing image with the vega CLI instead of building.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$repo_root/.sdk-version"
builder_image="${BUILDER_IMAGE:-}"

new="${1:-}"
if [[ -z "$new" ]]; then
  if [[ -z "$builder_image" ]]; then
    # We no longer publish/pull a builder image, so build the build-only image
    # locally and query it for the latest remote SDK version.
    builder_image="vega-sdk-builder:bump-query"
    echo "Building ${builder_image} locally to query the latest SDK version ..." >&2
    docker buildx bake -f "$repo_root/docker-bake.hcl" \
      --set "*.tags=${builder_image}" --load build-only >&2
  fi
  echo "Querying latest SDK version from ${builder_image} ..." >&2
  new="$(docker run --rm "$builder_image" 'vega sdk list-remote --json' \
        | jq -r '.versions[] | select(.isLatest == true) | .version')"
fi

if [[ ! "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: could not determine a valid version (got: '${new}')" >&2
  exit 1
fi

old="$(tr -d '[:space:]' < "$version_file" 2>/dev/null || true)"
if [[ "$old" == "$new" ]]; then
  echo "Already at ${new} — nothing to do." >&2
  exit 0
fi

printf '%s\n' "$new" > "$version_file"
echo "Bumped SDK version: ${old:-<none>} -> ${new}" >&2
git -C "$repo_root" --no-pager diff -- .sdk-version || true
