# `pr-screenshot-comment` (local composite action)

Posts CI screenshot(s) as a single **inline pull-request comment**. The PNGs are
uploaded to a dedicated branch (`ci-screenshots` by default) via the GitHub
Contents API and embedded with `github.com/<repo>/raw/<branch>/<path>` URLs, which
render inline even for **private** repos (a `raw.githubusercontent.com` URL would
not — GitHub's image proxy can't authenticate to private content).

- **One** matched image → rendered inline (`![title](url)`).
- **Several** → rendered as a 2-column HTML grid (one cell per file, labelled with
  its name).
- The comment is **created once and updated in place** on re-runs, deduped by a
  hidden `<!-- marker -->`.

It replaces the per-workflow copies of this logic; the repo's screenshot-posting
workflows ([`vega-app-build.yml`](../../workflows/vega-app-build.yml),
[`vvd-navigation-test.yml`](../../workflows/vvd-navigation-test.yml),
[`vvd-appium-test.yml`](../../workflows/vvd-appium-test.yml)) all call it.

## Usage

The repo must be checked out first (`actions/checkout`) so the action is present,
and the job needs `permissions: { contents: write, pull-requests: write }`.

```yaml
- name: Comment PR with screenshots
  if: always() && github.event_name == 'pull_request'
  continue-on-error: true            # a commenting hiccup must not fail the build
  uses: ./.github/actions/pr-screenshot-comment
  with:
    github-token: ${{ github.token }}
    marker: my-screenshots           # unique per workflow
    title: My screenshots
    intro: "Captured at commit `${{ github.event.pull_request.head.sha }}`."
    images: artifacts/[0-9][0-9]-*.png   # or a single file, e.g. artifacts/app.png
    summary-file: artifacts/summary.md   # optional; appended if it exists
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `github-token` | yes | — | Token with `contents:write` + `pull-requests:write` (`${{ github.token }}`). |
| `marker` | yes | — | Unique slug → hidden `<!-- marker -->` used to dedup/update the comment (and the default upload sub-path). |
| `title` | yes | — | Heading above the screenshots (and single-image alt text). |
| `intro` | no | `''` | Markdown under the heading; interpolate SHA / boot status at the call site. |
| `images` | no | `artifacts/[0-9][0-9]-*.png` | Glob of PNGs. One match → inline; many → grid. |
| `summary-file` | no | `''` | Markdown file appended to the body when it exists. |
| `branch` | no | `ci-screenshots` | Branch used to host the PNGs. |
| `slug` | no | `marker` | Sub-path component under `screenshots/pr-<n>/`. |

The PR number, head SHA, repo, base ref and run id are read from the runner
environment, so callers don't pass them.
