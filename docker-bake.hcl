# The SDK version is centralized in .sdk-version and read by the Dockerfiles at
# build time — it is intentionally NOT defined here.

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

target "full" {
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
  args = {
    SKIP_VVD_INSTALL = "false"
  }
  # Untagged by default; tag at build time, e.g.
  #   docker buildx bake --set "*.tags=${IMAGE_HOST}:local"
}

target "build-only" {
  dockerfile = "Dockerfile.build-only"
  platforms  = ["linux/amd64"]
}
