# The SDK version is centralized in .sdk-version and read by the host-base /
# builder-base Dockerfiles at build time — it is intentionally NOT defined here.

# Full image = the QEMU device host (apt deps + Node + platform-tools + SDK + VVD)
# wrapped with /scripts/. Composed of:
#   * `host-base`  — heavy layers + SDK install. Built by docker-base-publish.yml.
#   * `host`       — thin wrapper that adds /scripts/ on top of host-base.
variable "IMAGE_HOST" {
  default = "vega-virtual-device-host"
}

variable "IMAGE_HOST_BASE" {
  default = "vega-virtual-device-host-base"
}

# Build-only image = the Vega SDK for build/lint/test, with no emulator.
# Published as a "base" directly (it has no wrapper layers).
variable "IMAGE_BUILDER_BASE" {
  default = "vega-sdk-builder"
}

# Default base image reference used when building the `host` wrapper locally
# (no override file). CI overrides this via `--set host.args.BASE_IMAGE=...`
# so the wrapper pins a specific sdk-X.Y.Z tag.
variable "BASE_IMAGE" {
  default = "vega-virtual-device-host-base:local"
}

# Default group for the wrapper publisher — only the thin wrapper. The heavy
# bases are built by a separate `bases` group invoked from a different workflow.
group "default" {
  targets = ["host"]
}

group "bases" {
  targets = ["host-base", "builder-base"]
}

# Populated at CI time by docker/metadata-action bake file outputs.
# When building locally these are no-ops (empty inherits are fine in buildx).
target "_meta-host" {}
target "_meta-host-base" {}
target "_meta-builder-base" {}

target "host-base" {
  inherits   = ["_meta-host-base"]
  dockerfile = "Dockerfile.host-base"
  platforms  = ["linux/amd64"]
  args = {
    SKIP_VVD_INSTALL = "false"
  }
  # Tags inherited from _meta-host-base in CI; see note on the `host` target.
}

target "builder-base" {
  inherits   = ["_meta-builder-base"]
  dockerfile = "Dockerfile.builder-base"
  platforms  = ["linux/amd64"]
  # Tags inherited from _meta-builder-base in CI; see note on the `host` target.
}

target "host" {
  inherits   = ["_meta-host"]
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    BASE_IMAGE = "${BASE_IMAGE}"
  }
  # Tags come from docker/metadata-action via the inherited _meta-host target in CI.
  # Do NOT set `tags` here: a child target's tags REPLACE the inherited ones, which
  # would drop the branch/semver/latest tags and publish only sdk-<version>.
  # Local builds (no meta file) produce an untagged image; tag via
  #   docker buildx bake --set "*.tags=${IMAGE_HOST}:local"
}
