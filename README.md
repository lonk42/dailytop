# dailytop

A containerised KDE Plasma desktop in your browser, built on
[LinuxServer's webtop](https://docs.linuxserver.io/images/docker-webtop/) (Fedora KDE /
[selkies](https://github.com/selkies-project/selkies)). Supports several variants
packaged for Kubernetes, [Coder](https://coder.com) workspaces and Docker.

## What it adds to webtop

dailytop is a much fatter base including support for a larger variety of desktop tools.

- **Multiple deployment targets.** Single host via compose, Kubernetes, or a Coder
  workspace, selected with `--target`. Working examples for
  [Kubernetes](examples/k8s/dailytop.yaml) and
  [Coder](examples/coder-template/main.tf) are included.
- **Coder workspace support.** The agent runs as an s6 service rather than the container
  entrypoint. Subdomain apps, no HTTP basic auth, and TLS material kept out of the
  workspace volume.
  [Detail](docs/image-design.md#the-agent-is-a-service-not-the-entrypoint)
- **An unprivileged variant** that runs as an arbitrary non-root uid with no
  capabilities under Kubernetes' `restricted` PodSecurity, with no policy exception.
  [Detail](docs/unprivileged.md)
- **GPU acceleration for Wayland.** NVIDIA runtime wiring, and the glvnd EGL-on-X11
  configs that hardware video decode in Firefox needs but the GPU operator does not
  provide. [Detail](docs/image-design.md#firefox-egl-on-x11-then-vaapi)
- **Flatpak support**, with Flathub configured, apps where the KDE menu can find them,
  and bwrap functioning under the NVIDIA container runtime.
- **A KDE lock screen**, optionally engaged at session start and unlocked with an
  account password applied at container start.
  [Detail](docs/image-design.md#the-kde-lock-screen)
- **A cloud and Kubernetes toolkit** in `base`, inherited by every variant: aws, az and
  gcloud; kubectl, helm, oc, k9s and argocd; Terraform and OpenTofu; kustomize, rclone,
  restic and s3cmd; VS Code, Firefox and Chromium.
- **Customisable.** Package lists, flatpak lists, tool versions and the base image pin
  are all build args. [Detail](docs/building.md)

## Variants

| Target | What it is | Notable contents |
|---|---|---|
| `base` | Upstream fixes, the CLI toolkit, VS Code. | Firefox, Chromium, gh, aws/az/gcloud, helm, kubectl, oc, k9s, argocd, Terraform/OpenTofu; no flatpaks |
| `desktop` | `base` + a full desktop session. | flatpak + Flathub, Spotify, claude-desktop |
| `full` | `desktop` + a workstation toolchain. | sshd, yakuake, runtime password setup |
| `k8s` | `desktop` + NVIDIA wiring for a cluster. | VAAPI/NVDEC for Firefox, glvnd EGL-on-X11 configs, no sshd |
| `coder` | A [Coder](https://coder.com) workspace. | `base` + the Coder agent as an s6 service; no flatpaks, no HTTP basic auth |

| Variant | GPU support | Docker in Docker | Lockscreen | Unprivileged |
|---|:---:|:---:|:---:|:---:|
| `base` | ❌ | ❌ † | ❌ | ❌ |
| `desktop` | ✅ | ❌ † | ✅ | ❌ |
| `full` | ✅ | ✅ | ✅ | ❌ |
| `k8s` | ✅ ‡ | ❌ | ✅ | ❌ |
| `coder` | ❌ | ❌ | ❌ | ✅ § |

- **†** `base` and `desktop` still carry the upstream `svc-docker` service with no OCI
  runtime behind it, so dockerd restart-loops and [stacks a tmpfs on
  `/tmp`](docs/troubleshooting.md#svc-docker-restart-loop-stacks-tmpfs-on-tmp). `full`
  installs `runc`; `k8s` and `coder` remove the service.
- **‡** `k8s` adds VAAPI/NVDEC and the glvnd EGL-on-X11 configs on top of `desktop`'s
  NVIDIA flatpak GL hook.
- **§** Opt-in, via `--build-arg UNPRIVILEGED=true` — published as the `coder-unpriv`
  variant.

```
base ──> desktop ──> full
     │           └──> k8s
     └──> coder
```

`coder` branches off `base`, not `desktop`, so it does not inherit the lock screen,
flatpak runtimes or NVIDIA hooks and needs nothing disabled afterwards. It also means
`--target coder` builds with plain `docker build` and no BuildKit entitlement.

## Quick start

Access is **HTTPS on port 3001** in every case. On plain `:3000` the client refuses to
start with `FATAL: Not in a secure context. WebCodecs require HTTPS.`

### Docker

```bash
git clone <this repo> && cd dailytop
cp .env.example .env && $EDITOR .env      # set USER_PASSWORD at minimum
./build.sh full
docker compose up -d
```

Open <https://localhost:3001/>. The session starts at the KDE lock screen; unlock it with
the `USER_PASSWORD` you set, or set `LOCK_ON_STARTUP=false` to skip it.

### Kubernetes

```bash
./build.sh k8s
docker tag dailytop:k8s <registry>/dailytop:k8s && docker push <registry>/dailytop:k8s
$EDITOR examples/k8s/dailytop.yaml        # image, storage class, NVIDIA paths
kubectl apply -f examples/k8s/dailytop.yaml
```

Exposes a `dailytop` Service on 3000/3001; route to 3001 with your own Ingress. The 2 GiB
`/dev/shm` `emptyDir` that Chromium and Electron need is already in the manifest.

The example targets a **GPU node**: `runtimeClassName: nvidia` and two `hostPath` mounts
for the driver-locked `libnvidia-egl-*` libraries are live, with paths as a Debian node
spells them. Fix those paths for your nodes, or delete all three for a software-rendered
deployment.

### Coder

The published image needs no build:

```bash
$EDITOR examples/coder-template/main.tf   # locals: namespace, image, ca_cert_secret
cd examples/coder-template && coder templates push dailytop
```

Set `local.image` to `ghcr.io/lonk42/dailytop:coder-unpriv-ls286-<version>` and
`local.unprivileged = true` on a cluster that forbids root containers. Behind an internal
CA, `local.ca_cert_secret` is required — without it the agent's first curl fails `x509`
and the workspace never reports healthy, with the desktop up the whole time.

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
`securityContext.procMount: Unmasked` is a narrower grant than `privileged` and does the
same job for flatpak's bwrap; a variant with no flatpaks needs neither.
[Measured comparison](docs/troubleshooting.md#what-privileged-actually-buys-unmasked-proc)

## Upstream fixes carried here

These are defects in the base image and its selkies build rather than features of this
one. They are documented so they can be dropped when upstream fixes them:

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
- **Flatpaks fail under the NVIDIA runtime.** The toolkit's overmount on
  `/proc/driver/nvidia/params` trips the kernel's `mount_too_revealing` check and bwrap
  cannot start. [Detail](docs/image-design.md#nvidia-proc-overmount-breaks-flatpak)
- **No lock screen.** kwin is launched with `--no-lockscreen`, and on Plasma 6 Wayland
  kwin is what registers the ScreenSaver DBus service.
  [Detail](docs/image-design.md#the-kde-lock-screen)
- **Flatpak apps missing from the KDE menu**, because the session is not a login shell.
  [Detail](docs/image-design.md#flatpak-apps-in-the-kde-menu)

Every patch against the base is grep-guarded, so the build fails when upstream changes
the line a patch targets rather than the patch quietly ceasing to apply.

## Documentation

| | |
|---|---|
| [docs/building.md](docs/building.md) | Build args, `build.sh`, the flatpak entitlement |
| [docs/releasing.md](docs/releasing.md) | Tagging, the published image tags, what to pin |
| [docs/image-design.md](docs/image-design.md) | What each stage does and why |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms, causes, fixes |
| [docs/unprivileged.md](docs/unprivileged.md) | Running as a non-root uid with no capabilities |
| [docs/selkies-layer-analysis.md](docs/selkies-layer-analysis.md) | What LinuxServer's layer adds on top of selkies, and where the lag comes from |
| [certs/README.md](certs/README.md) | Mounting extra root CAs |

## Credits

Built on [LinuxServer.io](https://www.linuxserver.io/)'s webtop images and the
[selkies](https://github.com/selkies-project/selkies) project. Neither is affiliated with
this repo.
