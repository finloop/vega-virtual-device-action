variable "VEGA_SDK_VERSION" {
  default = "0.22.5600"
}

variable "IMAGE_BASE" {
  default = "vegaos"
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
  tags = ["${IMAGE_BASE}-full:sdk-${VEGA_SDK_VERSION}"]
}

target "build-only" {
  inherits   = ["_meta-build-only"]
  dockerfile = "Dockerfile.build-only"
  platforms  = ["linux/amd64"]
  args = {
    VEGA_SDK_VERSION = VEGA_SDK_VERSION
  }
  tags = ["${IMAGE_BASE}-build:sdk-${VEGA_SDK_VERSION}"]
}
