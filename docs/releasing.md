# Releasing

Pushing any git tag runs
[`.github/workflows/build-images.yml`](../.github/workflows/build-images.yml), which
builds and publishes to GHCR. Tags carry **no `v` prefix** — tag `0.0.1`, not `v0.0.1`.
Each released *variant* pushes two image tags per build, both pointing at the same
digest:

| Tag | Moves? | Use for |
|---|---|---|
| `dailytop:coder` | yes | trying it out |
| `dailytop:coder-ls286-0.0.1` | no | **deployments** |
| `dailytop:coder-unpriv` | yes | trying the unprivileged build |
| `dailytop:coder-unpriv-ls286-0.0.1` | no | **unprivileged deployments** |

A variant is a stage plus the build args that define it. `coder` and `coder-unpriv` are
both `--target coder`, differing only by `UNPRIVILEGED` — see
[unprivileged.md](unprivileged.md). Because each variant owns its tag name, adding one
never moves the tag another variant's deployments follow.

The immutable form is `<variant>-<lsNNN>-<version>`, where `lsNNN` is the LinuxServer
build number lifted from the base pin (`WEBTOP_BASE_IMAGE` →
`fedora-kde-37cda392-ls286` → `ls286`) and the version is the git tag verbatim. The full
base reference is recorded as the `org.dailytop.base-image` label.

Pin deployments to an immutable tag. A moving tag plus `imagePullPolicy: IfNotPresent`
will serve a node's stale cache under a pod that reports healthy —
[the details](troubleshooting.md#build-environment-gotchas).

Only the `coder` stage is released today, in both variants; add one by appending it to
`RELEASE_VARIANTS` in the workflow's `prepare` job. `workflow_dispatch` builds any single
stage on demand, with an `unprivileged` checkbox and the option to skip the push.
