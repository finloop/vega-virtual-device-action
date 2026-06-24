# CI workflows

This repo is a GitHub Action that boots an Amazon **V**ega **V**irtual **D**evice (VVD) in a
container. CI builds the device image, boots it on free GitHub-hosted runners (KVM), and exercises
the action end-to-end.

## What runs when

`docker-publish.yml` is the only workflow that runs on **push to `main` / tags** (it builds and
publishes the images and writes the registry build cache). Everything else runs on **pull requests**
(path-filtered) and via **manual `workflow_dispatch`**.

| Change to… | publish | smoke | nav | appium | app-build |
|---|:--:|:--:|:--:|:--:|:--:|
| push `main` / tag `v*` | ✅ build + push both images | — | — | — | — |
| `Dockerfile` | ✅ (PR: build-only) | ✅ | ✅ | ✅ | ✅ |
| `.sdk-version` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `scripts/**` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `vega-virtual-device-action/**` | — | ✅ | ✅ | ✅ | ✅ |
| `.github/actions/setup-vvd-host/**` | — | ✅ | ✅ | ✅ | ✅ |
| `examples/lib/**` | — | ✅ | ✅ | — | — |
| `examples/argent-screenshot-test.sh` | — | ✅ | — | — | — |
| `examples/argent-navigation-test.sh` | — | — | ✅ | — | — |
| `examples/appium-navigation-test.sh`, `examples/appium/**` | — | — | — | ✅ | — |
| `examples/build-sample-vega-app.sh` | — | — | — | — | ✅ |
| `.github/actions/pr-screenshot-comment/**` | — | — | ✅ | ✅ | ✅ |
| `Dockerfile.build-only`, `docker-bake.hcl`, `.dockerignore` | ✅ | — | — | — | — |

Legend — **publish**: `docker-publish.yml` · **smoke**: `vvd-action-test.yml` ·
**nav**: `vvd-navigation-test.yml` · **appium**: `vvd-appium-test.yml` ·
**app-build**: `vega-app-build.yml`.

All four PR tests keep full coverage on every core change (Dockerfile / `.sdk-version` / `scripts` /
action code) — runner minutes are free on a public repo, so coverage is not traded away. The
per-test example paths only add that one test on top. None of these are required status checks, so a
red run never blocks a merge on its own.

## Composite actions

- **`.github/actions/setup-vvd-host`** — one place for the per-test runner prep: free disk space,
  enable KVM, set up Buildx, log in to GHCR, and build `vega-virtual-device-host:ci`. Used by all
  four PR tests so the prep (and its cache config) is defined once. Requires the repo to be checked
  out first, and the calling job to grant `permissions: packages: read`.
- **`.github/actions/pr-screenshot-comment`** — posts CI screenshot(s) as one inline PR comment
  (created once, updated in place via a hidden marker; a multi-image grid is collapsed behind a
  `<details>`). Used by nav, appium, and app-build.

## Caching

`docker-publish.yml` builds on push to `main` and writes a **persistent registry build cache** to
GHCR (`…/vega-virtual-device-host:buildcache`, `…/vega-sdk-builder:buildcache`). Unlike `type=gha`
(10 GB repo cap, LRU eviction, branch-scoped), the registry cache is never evicted and is readable
from every branch/PR — so the expensive Vega SDK layer is restored instead of re-downloaded from the
flaky installer. PR builds (via `setup-vvd-host`) read that registry cache and keep a small
supplementary `type=gha` (`scope=host-ci`) for per-PR warmth; only push/tag builds write the
registry cache (PRs lack registry write auth).
