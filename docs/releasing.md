# Releasing

Releases are listed on the [releases page](https://github.com/lonk42/dailytop/releases).
Each one carries the image references and digests, the install commands for that version, and the chart and a pinned Coder template as assets with `SHA256SUMS`.

To release:

1. Set `version` in [`charts/dailytop/Chart.yaml`](../charts/dailytop/Chart.yaml) to the new version, and `appVersion` to `<lsNNN>-<version>` for the base pin, e.g. `ls296-2.1.0`.
2. Commit, then tag that commit with the version. Tags carry **no `v` prefix**: `2.1.0`, not `v2.1.0`.
3. Push the tag.

The tag runs [`release.yml`](../.github/workflows/release.yml).
It fails before publishing anything if the tag does not match `version`, if `appVersion` does not match, or if [`test.yml`](../.github/workflows/test.yml) fails.
It then calls [`build-images.yml`](../.github/workflows/build-images.yml) and [`publish-chart.yml`](../.github/workflows/publish-chart.yml), and creates the GitHub release once both succeed.
Only `X.Y.Z` tags trigger it.

## Images

Each released *variant* pushes two image tags per build, both pointing at the same
digest:

| Tag | Moves? | Use for |
|---|---|---|
| `dailytop:coder` | yes | trying it out |
| `dailytop:coder-ls296-0.0.1` | no | **deployments** |
| `dailytop:coder-unpriv` | yes | trying the unprivileged build |
| `dailytop:coder-unpriv-ls296-0.0.1` | no | **unprivileged deployments** |
| `dailytop:k8s` | yes | trying the GPU build |
| `dailytop:k8s-ls296-0.0.1` | no | **GPU deployments** |

A variant is a stage plus the build args that define it. `coder` and `coder-unpriv` are
both `--target coder`, differing only by `UNPRIVILEGED` — see
[unprivileged.md](unprivileged.md). Because each variant owns its tag name, adding one
never moves the tag another variant's deployments follow.

The immutable form is `<variant>-<lsNNN>-<version>`, where `lsNNN` is the LinuxServer
build number lifted from the base pin (`WEBTOP_BASE_IMAGE` →
`fedora-kde-531f6f7b-ls296` → `ls296`) and the version is the git tag verbatim. The full
base reference is recorded as the `org.dailytop.base-image` label.

Pin deployments to an immutable tag. A moving tag plus `imagePullPolicy: IfNotPresent`
will serve a node's stale cache under a pod that reports healthy —
[the details](troubleshooting.md#build-environment-gotchas).

The `coder` stage is released in both variants, and `k8s` in one; add another by
appending it to `RELEASE_VARIANTS` in `build-images.yml`'s `prepare` job. `workflow_dispatch`
builds any single stage on demand, with an `unprivileged` checkbox and the option to skip
the push.

## The chart

The same tag publishes [`charts/dailytop`](../charts/dailytop/README.md) to `oci://ghcr.io/<owner>/charts/dailytop` at the version in `Chart.yaml`.
The chart composes its default image tag from `appVersion` and `image.variant`, so a chart pulled at `--version 2.0.0` deploys the images the same tag built.

Every pull request lints the chart and renders every
`charts/dailytop/ci/*-values.yaml`. Each of those files is a deployment shape that has to
keep working — the defaults, GPU, unprivileged — so add one alongside a feature rather
than only documenting it.
