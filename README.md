# dailytop

A full KDE Plasma desktop in your browser, built on
[LinuxServer's webtop](https://docs.linuxserver.io/images/docker-webtop/) (Fedora KDE /
[selkies](https://github.com/selkies-project/selkies)) — five variants from one
`Dockerfile`, with package lists, flatpaks, tool versions and the base image all exposed
as build args.

## What it adds to webtop

Stock webtop needs a surprising amount of help to be a *daily driver*. dailytop fixes:

- **A session that degrades over days.** Upstream selkies leaks a monitor task per
  browser reconnect and calls `nvidia-smi` synchronously on the asyncio event loop.
  Measured on one container after 11 days: ~32 leaked monitors, the event loop blocked
  in 38 of 40 samples, choppy stream and clipboard timeouts.
  [Detail](docs/troubleshooting.md#upstream-patches-carried-here-and-when-to-delete-them)
- **A Docker-in-Docker service that breaks the desktop.** The base enables `svc-docker`
  but current Fedora bases ship no OCI runtime, so dockerd restart-loops and stacks a
  tmpfs on `/tmp` every 4 seconds until the session D-Bus socket is buried and flatpak
  apps fail silently.
  [Detail](docs/troubleshooting.md#svc-docker-restart-loop-stacks-tmpfs-on-tmp)
- **Flatpaks that die under the NVIDIA runtime.** The toolkit's overmount on
  `/proc/driver/nvidia/params` trips the kernel's `mount_too_revealing` check and bwrap
  cannot start. [Detail](docs/image-design.md#nvidia-proc-overmount-breaks-flatpak)
- **No lock screen.** kwin is launched with `--no-lockscreen`, and on Plasma 6 Wayland
  kwin is what registers the ScreenSaver DBus service.
  [Detail](docs/image-design.md#the-kde-lock-screen)
- **Flatpak apps missing from the KDE menu**, because the session is not a login shell.
  [Detail](docs/image-design.md#flatpak-apps-in-the-kde-menu)
- **Hardware video decode in Firefox on NVIDIA**, which needs glvnd EGL-on-X11 configs
  the GPU operator does not provide.
  [Detail](docs/image-design.md#firefox-egl-on-x11-then-vaapi)
- **A Coder workspace that actually keeps its desktop**, by running the agent as an s6
  service instead of the container entrypoint.
  [Detail](docs/image-design.md#the-agent-is-a-service-not-the-entrypoint)

Every patch against the base is grep-guarded, so it fails the build loudly when upstream
catches up instead of silently degenerating.

## Variants

| Target | What it is | Notable contents |
|---|---|---|
| `base` | The minimum worth running. Upstream fixes, the CLI toolkit, VS Code. | Firefox, Chromium, gh, aws/az/gcloud, helm, kubectl, oc, k9s, argocd, Terraform/OpenTofu; no flatpaks, no lock screen |
| `desktop` | `base` + a human-facing desktop. | KDE lock screen, flatpak + Flathub, Spotify, claude-desktop |
| `full` | `desktop` + a workstation toolchain. | Docker-in-Docker, sshd, yakuake, runtime password setup |
| `k8s` | `desktop` + NVIDIA wiring for a cluster. | VAAPI/NVDEC for Firefox, glvnd EGL-on-X11 configs, no DinD/sshd |
| `coder` | A [Coder](https://coder.com) workspace. | `base` + the Coder agent as an s6 service; GPU-less, no lock screen, no flatpaks, no HTTP basic auth |

```
base ──> desktop ──> full
     │           └──> k8s
     └──> coder
```

`coder` branches off `base`, not `desktop`, so it never *receives* the lock screen,
flatpak runtimes or NVIDIA hooks — there is nothing to disable afterwards. It also means
`--target coder` builds with plain `docker build` and no BuildKit entitlement.

## Quick start

```bash
git clone <this repo> && cd dailytop
cp .env.example .env && $EDITOR .env      # set USER_PASSWORD at minimum
./build.sh full
docker compose up -d
```

Then open **<https://localhost:3001/>**. It must be HTTPS — on plain `:3000` the client
refuses to start with `FATAL: Not in a secure context. WebCodecs require HTTPS.`

You will be greeted by the KDE lock screen; unlock it with the `USER_PASSWORD` you set.
Set `LOCK_ON_STARTUP=false` to skip it.

The GPU-less workspace variant needs no compose file or entitlement at all:

```bash
docker build --target coder -t dailytop:coder .
```

## Using it

### NVIDIA

Uncomment the two blocks marked **NVIDIA** in
[`docker-compose.yaml`](docker-compose.yaml) and set
`SELKIES_ENCODER=x264enc,x264enc-striped,jpeg` in `.env`. The file runs software-rendered
by default.

Exposing the device nodes is not enough — only the NVIDIA container runtime injects the
userspace driver, and without it you get software rendering and no NVENC with no obvious
error.
[Detail](docs/troubleshooting.md#nvidia-exposing-devices-is-not-injecting-the-driver)

### CA certificates

Extra root CAs are mounted at runtime rather than built in, so one image works across
environments that trust different CAs. Mount a directory of `*.crt` / `*.pem` at
`/certs`; they are installed before any service starts. See
[certs/README.md](certs/README.md).

### Runtime environment

Beyond [webtop's own variables](https://docs.linuxserver.io/images/docker-webtop/):

| Variable | Default | Effect |
|---|---|---|
| `USER_PASSWORD` | *(unset)* | Sets `abc`/`root` passwords at start. Required to unlock the lock screen |
| `LOCK_ON_STARTUP` | `true` | Lock the session at start |
| `CA_CERT_DIR` | `/certs` | Where to load extra root CAs from |
| `PRIVATE_REGISTRY` | *(empty)* | Registry `host[:port]` to trust from the inner DinD daemon |
| `SSHD_CONFIG` | `/defaults/sshd_config` | Use your own sshd config |
| `SELKIES_ENCODER` | per variant | Ordered fallback list — [read this first](docs/troubleshooting.md#the-encoder-model-read-this-first) |

### Deploying

- **Single host** — [`docker-compose.yaml`](docker-compose.yaml); NVIDIA support is
  inline and commented out.
- **Kubernetes** (`k8s` target) — [`examples/k8s/dailytop.yaml`](examples/k8s/dailytop.yaml).
- **Coder** (`coder` target) —
  [`examples/coder-template/main.tf`](examples/coder-template/main.tf). Coder
  authenticates at its proxy, so this variant drops webtop's own basic auth
  (`PASSWORD`/`CUSTOM_USER` are inert) and self-signs its nginx certificate into `/run`
  rather than the workspace volume.

`shm_size: "2gb"` (or a 2 GiB `/dev/shm` `emptyDir`) is required — Chromium and Electron
apps crash on Docker's 64 MB default. On Kubernetes,
`securityContext.procMount: Unmasked` is a far narrower grant than `privileged` and does
the same job for flatpak's bwrap; a variant with no flatpaks needs neither.
[Measured comparison](docs/troubleshooting.md#what-privileged-actually-buys-unmasked-proc)

## Releases

Pushing any git tag runs
[`.github/workflows/build-images.yml`](.github/workflows/build-images.yml), which builds
and publishes to GHCR. Tags carry **no `v` prefix** — tag `0.0.1`, not `v0.0.1`. Each
released *variant* pushes two image tags per build, both pointing at the same digest:

| Tag | Moves? | Use for |
|---|---|---|
| `dailytop:coder` | yes | trying it out |
| `dailytop:coder-ls286-0.0.1` | no | **deployments** |
| `dailytop:coder-unpriv` | yes | trying the unprivileged build |
| `dailytop:coder-unpriv-ls286-0.0.1` | no | **unprivileged deployments** |

A variant is a stage plus the build args that define it. `coder` and `coder-unpriv` are
both `--target coder`, differing only by `UNPRIVILEGED` — see
[docs/unprivileged.md](docs/unprivileged.md). Because each variant owns its tag name,
adding one never moves the tag another variant's deployments follow.

The immutable form is `<variant>-<lsNNN>-<version>`, where `lsNNN` is the LinuxServer
build number lifted from the base pin (`WEBTOP_BASE_IMAGE` →
`fedora-kde-37cda392-ls286` → `ls286`) and the version is the git tag verbatim. The full
base reference is recorded as the `org.dailytop.base-image` label.

Pin deployments to an immutable tag. A moving tag plus `imagePullPolicy: IfNotPresent`
will serve a node's stale cache under a pod that reports perfectly healthy —
[the details](docs/troubleshooting.md#build-environment-gotchas).

Only the `coder` stage is released today, in both variants; add one by appending it to
`RELEASE_VARIANTS` in the workflow's `prepare` job. `workflow_dispatch` builds any single
stage on demand, with an `unprivileged` checkbox and the option to skip the push.

## Documentation

| | |
|---|---|
| [docs/building.md](docs/building.md) | Build args, `build.sh`, the flatpak entitlement |
| [docs/image-design.md](docs/image-design.md) | What each stage does and why |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms, causes, fixes |
| [docs/unprivileged.md](docs/unprivileged.md) | Running as a non-root uid with no capabilities |
| [docs/selkies-layer-analysis.md](docs/selkies-layer-analysis.md) | What LinuxServer's layer adds on top of selkies, and where the lag comes from |
| [certs/README.md](certs/README.md) | Mounting extra root CAs |

## Credits

Built on [LinuxServer.io](https://www.linuxserver.io/)'s webtop images and the
[selkies](https://github.com/selkies-project/selkies) project. Neither is affiliated with
this repo.
