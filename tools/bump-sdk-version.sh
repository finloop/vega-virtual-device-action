#!/usr/bin/env bash
# Bump the centralized Vega SDK version.
#
# The version lives in exactly ONE place: .sdk-version (repo root). The
# Dockerfiles read it at build time and docker-publish.yml reads it for the
# sdk-<version> image tag, so this is the only file a bump needs to change.
#
# Usage:
#   tools/bump-sdk-version.sh             # resolve & write the latest (isLatest) SDK
#   tools/bump-sdk-version.sh 0.22.9999   # write an explicit version
#
# After bumping: open a PR, merge to main (publishes :latest + :sdk-<new>), and
# optionally `git tag vX.Y.Z && git push origin vX.Y.Z` to publish versioned images.
#
# Requires: docker + jq (only when auto-resolving the latest version).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$repo_root/.sdk-version"
builder_image="${BUILDER_IMAGE:-ghcr.io/finloop/vega-sdk-builder:latest}"

new="${1:-}"
if [[ -z "$new" ]]; then
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
