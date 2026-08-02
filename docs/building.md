# Building

```bash
./build.sh <base|desktop|full|k8s|coder> [extra docker buildx args...]
```

The image is loaded into the local docker daemon as `$IMAGE_NAME:$TAG`. Publishing is
separate — see [releasing.md](releasing.md).

| Environment variable | Default | Effect |
|---|---|---|
| `IMAGE_NAME` | `dailytop` | image name |
| `TAG` | the target name | tag override |
| `BUILDER` | `dailytop-builder` | buildx builder name |
| `PLATFORM` | *(unset)* | `--platform` value |

```bash
./build.sh coder
./build.sh k8s
./build.sh desktop --build-arg FLATPAKS=""
```

Every default reproduces the reference image, so no args are required. Package-list args
are space-separated, and an empty value skips the step.

## The flatpak entitlement

`desktop`, `full` and `k8s` install flatpaks, whose deploy step uses bwrap and therefore
needs BuildKit's `security.insecure` entitlement. `build.sh` creates a suitable
`docker-container` builder for those targets automatically and uses the default builder
for `base` and `coder`, which need none.

The `# syntax` directive must stay on the `labs` channel: `RUN --security=insecure` is a
labs-only feature and the stable frontend fails to parse it with `unknown flag:
security`.

> **Don't build inside a container whose Docker uses `fuse-overlayfs`.** BuildKit falls
> back to the native snapshotter, which full-copies the multi-GB base rootfs per layer
> and runs out of space regardless of free disk. Build on a host with `overlay2`.

More in [build environment gotchas](troubleshooting.md#build-environment-gotchas).

## Build args

### base

| Arg | Default | Notes |
|---|---|---|
| `WEBTOP_BASE_IMAGE` | `lscr.io/linuxserver/webtop:fedora-kde-37cda392-ls286` | Pinned deliberately, not rolling — see [the base pin](image-design.md#the-base-pin) |
| `BASE_PACKAGES` | *(the CLI toolkit — see the Dockerfile)* | From Fedora's repos |
| `INSTALL_VSCODE` | `true` | Needs Microsoft's repo, hence its own switch |
| `INSTALL_GCLOUD` | `true` | Needs Google's repo, hence its own switch; pulls `gcloud` and the GKE auth plugin, ~449 MB |
| `TERRAFORM_VERSION` | `1.14.8` | Not packaged in Fedora, so a pinned download |
| `K9S_VERSION` | `0.51.0` | Not packaged in Fedora, so a pinned download |
| `OC_VERSION` | `4.22.6` | OpenShift client, from `mirror.openshift.com` |
| `ARGOCD_VERSION` | `3.4.6` | Not packaged in Fedora, so a pinned download |

### desktop

| Arg | Default | Notes |
|---|---|---|
| `DESKTOP_PACKAGES` | *(empty)* | Extra packages for the desktop lineage; `flatpak` is installed regardless |
| `INSTALL_CLAUDE_DESKTOP` | `true` | Third-party repo |
| `FLATPAKS` | `com.spotify.Client` | Empty installs none but keeps flatpak usable at runtime |
| `ENABLE_LOCK_SCREEN` | `true` | Needs an account password to be openable — [why](image-design.md#the-kde-lock-screen) |
| `ENABLE_NVIDIA_FLATPAK_GL` | `true` | [Startup hook that matches the host driver](image-design.md#nvidia-flatpak-gl-extension) |

### full

| Arg | Default | Notes |
|---|---|---|
| `FULL_PACKAGES` | `sshpass irssi mutt` | |
| `FULL_FLATPAKS` | *(empty)* | Extra flatpaks for this target only, e.g. `org.gimp.GIMP` |
| `INSTALL_DIND` | `true` | `false` **removes** the base's `svc-docker`, which is mandatory without the toolchain — [why](image-design.md#docker-in-docker-and-explicit-runc) |
| `INSTALL_SSHD` | `true` | [Unprivileged sshd, key auth only](image-design.md#sshd) |
| `SSHD_PORT` | `2222` | |
| `INSTALL_ACCOUNT_HOOK` | `true` | [Sets `abc`/`root` passwords at start from `$USER_PASSWORD`](image-design.md#account-passwords) |

### k8s

| Arg | Default | Notes |
|---|---|---|
| `K8S_PACKAGES` | `libva-utils iproute plocate` | `vainfo` plus cluster debugging conveniences |

`FIREFOX_DISABLE_AV1` is a runtime environment variable, not a build arg — this stage
defaults it to `true`. [Set `false` on Ampere or newer](image-design.md#av1).

### coder

| Arg | Default | Notes |
|---|---|---|
| `CODER_PACKAGES` | *(empty)* | The rest of the variant is deliberately fixed |
| `UNPRIVILEGED` | `false` | Runs as a non-root uid with no capabilities, for clusters that forbid root containers. Makes `PUID`/`PGID` inert — [what it changes and what the deployment must supply](unprivileged.md) |
| `UNPRIVILEGED_PATHS` | *(the paths the init scripts write — see the Dockerfile)* | Made group-root and group-writable. Extending this list is the fix for a new "Permission denied" from an init script |
