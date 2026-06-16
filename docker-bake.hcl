variable "VEGA_SDK_VERSION" {
  default = "0.22.5600"
}

# Full image = the QEMU device host (SDK + VVD emulator + software-GL stack).
variable "IMAGE_HOST" {
  default = "vega-virtual-device-host"
}

# Build-only image = the Vega SDK for build/lint/test, with no emulator.
variable "IMAGE_BUILDER" {
  default = "vega-sdk-builder"
}

group "default" {
  targets = ["full", "build-only"]
}

# Populated at CI time by docker/metadata-action bake file outputs.
# When building locally these are no-ops (empty inherits are fine in buildx).
target "_meta-full" {}
target "_meta-build-only" {}

target "full" {
  inherits   = ["_meta-full"]
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    VEGA_SDK_VERSION = VEGA_SDK_VERSION
    SKIP_VVD_INSTALL = "false"
  }
  # Tags come from docker/metadata-action via the inherited _meta-full target in CI.
  # Do NOT set `tags` here: a child target's tags REPLACE the inherited ones, which
  # would drop the branch/semver/latest tags and publish only sdk-<version>.
  # Local builds (no meta file) produce an untagged image; tag via
  #   docker buildx bake --set "*.tags=${IMAGE_HOST}:local"
}

target "build-only" {
  inherits   = ["_meta-build-only"]
  dockerfile = "Dockerfile.build-only"
  platforms  = ["linux/amd64"]
  args = {
    VEGA_SDK_VERSION = VEGA_SDK_VERSION
  }
  # See note on the `full` target: tags are inherited from _meta-build-only in CI.
}
