# Vega Virtual Device Action

Boots the **Vega Virtual Device (VVD)** — a QEMU-based emulator for Amazon's Vega
(React Native for Fire TV) platform — inside the `vega-virtual-device-host`
container, waits until it shows a real (non-black) screen, runs a script you
provide against it, and captures a screenshot. It is the Vega analogue of
[`reactivecircus/android-emulator-runner`](https://github.com/ReactiveCircus/android-emulator-runner).

It runs on a **free GitHub-hosted `ubuntu` runner** — no GPU and no self-hosted
runner required (see [No GPU needed](#no-gpu-needed)).

## Usage

No image reference and no registry login: the action builds the
`vega-virtual-device-host` image on your runner the first time it runs and caches
the build via the GitHub Actions cache, like `android-emulator-runner` does for the
Android SDK.

```yaml
jobs:
  vvd-test:
    runs-on: ubuntu-22.04
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4

      - name: Enable KVM       # grants the runner user access to /dev/kvm
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
            | sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm

      - name: Boot VVD and run tests
        id: vvd
        uses: <owner>/vega-virtual-device-action/vega-virtual-device-action@main
        with:
          boot-timeout: 300
          screenshot-path: artifacts/home.png
          script: |
            # device is live here; vega / vda / vvd-screenshot.sh are on PATH
            vega exec vda devices
            ./run-tests.sh        # produces ./artifacts/

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: vvd-artifacts
          path: artifacts/
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `script` | _(required)_ | Command(s) run inside the container once the VVD is ready. `vega`, `vda`, `vvd-screenshot.sh` are on `PATH`; cwd is the checkout (or `working-directory`). |
| `image` | _(empty)_ | Optional. An existing `vega-virtual-device-host` image to run instead of building. Empty (default) → the action builds the image locally from its bundled Dockerfile and caches it via the GitHub Actions cache. Set only if you host your own image. |
| `boot-timeout` | `300` | Seconds to wait for a ready (non-black) home screen before failing. |
| `working-directory` | `.` | Sub-directory of the checkout to `cd` into for the script (and where `screenshot-path` is resolved). |
| `pre-launch-script` | `''` | Optional command(s) run inside the container **before** the VVD starts. |
| `capture-screenshot` | `true` | Capture a screenshot after the script (and on boot/run failure). |
| `screenshot-path` | `vvd-screenshot.png` | Where to write the screenshot, relative to `working-directory`. |
| `pull` | `true` | When `image` is set, `docker pull` it before running. Ignored when the action builds the image locally. |
| `container-options` | `''` | Extra flags appended to `docker run` (advanced) — e.g. additional `-v`/`-e`. |

## Outputs

| Output | Description |
|---|---|
| `screenshot` | Path (relative to `working-directory`) of the captured screenshot, or empty. |
| `boot-status` | `ready` \| `timeout` \| `failed`. |

## How it works

The action is a **composite action** that issues its own `docker run`. A Docker
*container* action (`runs.using: docker`) cannot be given `--privileged`,
`--device /dev/kvm`, or `--init`, all of which the VVD requires — so the action
runs the container itself with exactly those flags:

```
docker run --rm --privileged --device /dev/kvm --init \
  -v <checkout>:/workspace -v <action>:/action:ro ... <image>
```

Inside the container, [`entrypoint.sh`](entrypoint.sh):

1. runs the optional `pre-launch-script`;
2. boots the VVD via the image's `start-vvd.sh` (enables IPv6 loopback, starts
   Xvfb + llvmpipe software GL, and relaunches the emulator with `-gpu host` — the
   only path that yields a non-black framebuffer; see
   [`docs/vvd-docker-screenshot-fix.md`](../docs/vvd-docker-screenshot-fix.md));
3. **waits for readiness** — see below;
4. runs your `script` (its exit code becomes the step's result);
5. captures a screenshot (on success *and* failure, if enabled);
6. tears the emulator down.

### Readiness gate

The VVD guest is a Poky/Yocto Linux, not Android: it has no `getprop` or
`systemctl`, and `vega virtual-device status` is unreliable because the emulator
is relaunched directly (bypassing the CLI's process tracking). So readiness is
gated on a **non-black framebuffer** — the proven, quantifiable "the device is
showing real UI" signal. The action polls the emulator-console screenshot until
the decoded image is non-black (a black capture decompresses to ~all-zero bytes;
the live home screen is high-signal), bounded by `boot-timeout`. `vda
wait-for-device` is used first as a cheap "adapter is up" pre-check.

### No GPU needed

`-gpu host` does **not** require a GPU. It means "use the host's GL stack to post
a color buffer," and that stack is supplied **in software** by Mesa **llvmpipe**
(CPU) + Xvfb, baked into the image. The thing that *does* need hardware is **KVM**
(VM acceleration), and free GitHub-hosted Linux runners expose `/dev/kvm` once the
"Enable KVM" udev step above is applied — exactly as `android-emulator-runner`
requires.

## Notes & caveats

- **Image is built on your runner.** By default the action builds the
  `vega-virtual-device-host` image from its bundled Dockerfile on your runner, like
  `android-emulator-runner` sets up the Android SDK. The build is cached via the
  GitHub Actions cache, so only the first run pays the full build; later runs
  restore the build layers. No GHCR login or `packages:` permission is needed. Pass
  `image:` only to run your own pre-built image.
- **First-boot download.** The ~22 MB emulator binary is downloaded on the first
  `vega virtual-device start` *inside the container*; `boot-timeout` must cover
  that download plus a cold llvmpipe boot. `300` s is a safe default.
- **Artifacts** land under the bind-mounted checkout, so a normal
  `actions/upload-artifact` step on the runner picks them up.

## Maintaining the SDK version

The Vega SDK version is centralized in a single file at the repo root,
**`.sdk-version`**. The Dockerfiles read it at build time — nothing else hardcodes
it (a CI check enforces this). To bump it:

```bash
tools/bump-sdk-version.sh            # write the latest (isLatest) SDK
tools/bump-sdk-version.sh 0.22.9999  # or pin an explicit version
```

Then open a PR. The action builds the host image from `.sdk-version` on each
consumer's runner, so consumers pick up the new SDK version once they update the
action ref — no image is published from this repo.
