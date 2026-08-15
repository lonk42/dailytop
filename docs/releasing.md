# Releasing

Pushing any git tag runs two workflows:
[`build-images.yml`](../.github/workflows/build-images.yml) publishes the images, and
[`publish-chart.yml`](../.github/workflows/publish-chart.yml) publishes the Helm chart.
Tags carry **no `v` prefix** — tag `0.0.1`, not `v0.0.1`.

## Images

Each released *variant* pushes two image tags per build, both pointing at the same
digest:

| Tag | Moves? | Use for |
|---|---|---|
| `dailytop:coder` | yes | trying it out |
| `dailytop:coder-ls290-0.0.1` | no | **deployments** |
| `dailytop:coder-unpriv` | yes | trying the unprivileged build |
| `dailytop:coder-unpriv-ls290-0.0.1` | no | **unprivileged deployments** |
| `dailytop:k8s` | yes | trying the GPU build |
| `dailytop:k8s-ls290-0.0.1` | no | **GPU deployments** |

A variant is a stage plus the build args that define it. `coder` and `coder-unpriv` are
both `--target coder`, differing only by `UNPRIVILEGED` — see
[unprivileged.md](unprivileged.md). Because each variant owns its tag name, adding one
never moves the tag another variant's deployments follow.

The immutable form is `<variant>-<lsNNN>-<version>`, where `lsNNN` is the LinuxServer
build number lifted from the base pin (`WEBTOP_BASE_IMAGE` →
`fedora-kde-1cad2397-ls290` → `ls290`) and the version is the git tag verbatim. The full
base reference is recorded as the `org.dailytop.base-image` label.

Pin deployments to an immutable tag. A moving tag plus `imagePullPolicy: IfNotPresent`
will serve a node's stale cache under a pod that reports healthy —
[the details](troubleshooting.md#build-environment-gotchas).

The `coder` stage is released in both variants, and `k8s` in one; add another by
appending it to `RELEASE_VARIANTS` in the workflow's `prepare` job. `workflow_dispatch`
builds any single stage on demand, with an `unprivileged` checkbox and the option to skip
the push.

## The chart

The same tag publishes [`charts/dailytop`](../charts/dailytop/README.md) to
`oci://ghcr.io/<owner>/charts/dailytop`, versioned with the git tag and stamped with
appVersion `<lsNNN>-<version>` — `ls290-0.0.1`. The chart composes its default image tag
from that appVersion and `image.variant`, so a chart pulled at `--version 0.0.1` deploys
the images the same tag built, with nothing to keep in step by hand.

Helm requires SemVer 2 for a chart version, which is stricter than a git tag or a Docker
tag. A tag that is not SemVer fails the workflow before packaging.

Pull requests touching `charts/**` lint the chart and render every
`charts/dailytop/ci/*-values.yaml`. Each of those files is a deployment shape that has to
keep working — the defaults, GPU, unprivileged — so add one alongside a feature rather
than only documenting it.
