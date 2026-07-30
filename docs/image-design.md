# Image design

Why each stage does what it does. The Dockerfile keeps comments to one line; this is
where the reasoning lives. For symptoms and fixes see
[troubleshooting.md](troubleshooting.md); for build args see [building.md](building.md).

## Stage graph

```
base ──> desktop ──> full
     │           └──> k8s
     └──> coder
```

`coder` branches off `base`, not `desktop`, and that is what makes it lean: it never
receives the lock screen, the flatpak runtimes or the NVIDIA hooks, so there is nothing
to disable or revert afterwards. It also means no `RUN --security=insecure` instruction
is in coder's build graph, so `--target coder` builds with plain `docker build` and no
BuildKit entitlement.

## Conventions

**Every `sed` is grep-guarded.** The guard asserts the upstream line is still what we
think it is, before and after. A guard failure means the base changed — revalidate the
patch, or delete it if upstream fixed the bug. Never loosen a guard to get a build
passing; that failure is the removal signal.

**Anything environment-specific is a build arg or runtime env with a neutral default.**
Nothing about one deployment belongs in the Dockerfile body.

**s6 services park rather than exit.** An s6 longrun that exits is restarted immediately
and forever, which is the [`svc-docker` failure
mode](troubleshooting.md#svc-docker-restart-loop-stacks-tmpfs-on-tmp) in miniature. A
parked service with one clear log line is the safe failure: the desktop still comes up.

### The init hooks

`/custom-cont-init.d` runs after `init-adduser`/`init-config` and before any `svc-*`, so
every service sees whatever these change. Verified against the compiled s6-rc database
rather than assumed:

```bash
s6-rc-db -c <db> all-dependencies init-custom-files | grep -x init-selkies-config
```

| Hook | Stage | Purpose |
|---|---|---|
| `00-ca-certs.sh` | base | [Trust mounted CAs](#extra-ca-trust) |
| `01-set-passwords.sh` | full | [Account passwords from `$USER_PASSWORD`](#account-passwords) |
| `02-nvidia-proc-unmount.sh` | desktop | [Restore `/proc` for bwrap](#nvidia-proc-overmount-breaks-flatpak) |
| `03-nvidia-flatpak-gl.sh` | desktop | [Match the host driver](#nvidia-flatpak-gl-extension) |
| `04-no-gpu.sh` | coder | [Neutralise the GPU autodetect](#neutralising-the-gpu-autodetect) |
| `05-unpriv-passwd.sh` | coder, `UNPRIVILEGED=true` only | [A passwd entry for an arbitrary uid](unprivileged.md#what-the-image-changes) |

## base

### The base pin

`WEBTOP_BASE_IMAGE` is pinned to a specific LinuxServer release rather than the rolling
`:fedora-kde` tag, which drifts and silently relocates the session scripts the seds
patch.

Bumping the pin does **not** pick up upstream selkies fixes — LinuxServer builds selkies
from their own `lsio` vendor branch, which has diverged from upstream main. See
[selkies-layer-analysis.md](selkies-layer-analysis.md) and [bumping the base
pin](troubleshooting.md#bumping-the-base-pin).

### Extra CA trust

Certificates are mounted at runtime, never baked. Full rationale and behaviour in
[certs/README.md](../certs/README.md). In short: an internal CA is environment-specific,
so keeping it out of the image means one image works everywhere, a rotation needs no
rebuild, and a published image discloses nobody's infrastructure.

The hook is numbered `00-` because everything that touches the network is downstream of
it — notably `svc-coder-agent`, whose first act is curling the Coder access URL.

### Terraform and k9s use curl, not wget

Both `wget` and `unzip` arrive via `BASE_PACKAGES`, and the download step must survive
`--build-arg BASE_PACKAGES=""`. `curl` is part of the upstream base (its own mod-init
uses it), so it is always present; `unzip` is installed on demand, which is a no-op in a
default build.

### kwin DISPLAY strip

kwin's GL init could historically deadlock when `DISPLAY` pointed at a pre-bound but
unserved X socket — xcb-connect to its own listener blocked in `poll()` forever, s6
restart-looped the desktop, and each iteration leaked a kwin. The wrapper that caused it
is gone from current bases (kwin spawns Xwayland itself), but the strip is kept as
zero-cost insurance: kwin never needs `DISPLAY`, and the rest of the session still gets
it from startwm's own export.

It lives in `base` so every variant benefits. The lock-screen half of the same upstream
line is patched separately in `desktop`, which is why both stages grep for it.

### The selkies patch

A temporary patch for leaked monitor tasks and a blocking `nvidia-smi` on the asyncio
event loop. It is what makes a long-lived desktop degrade. Full detail, measurements and
the exact delete-check in [upstream patches carried
here](troubleshooting.md#upstream-patches-carried-here-and-when-to-delete-them).

## desktop

### Flatpak apps in the KDE menu

The session is launched from `/defaults/startwm_wayland.sh`, not a login shell, so
`/etc/profile.d/flatpak.sh` — which normally adds the flatpak export dirs to
`XDG_DATA_DIRS` — is never sourced. plasmashell and `kbuildsycoca6` therefore never scan
`/var/lib/flatpak/exports/share/applications` and flatpak apps do not appear in the
menu.

Baking `XDG_DATA_DIRS` as container-wide env makes every process see it. It is
idempotent: the profile.d snippet will not double-add paths already present, so login
shells stay correct too. The order matches profile.d's own output — user install, system
install, then base.

### NVIDIA proc overmount breaks flatpak

The nvidia-container-toolkit bind-mounts a tmpfs over `/proc/driver/nvidia/params` at
container creation. That overmount hides part of `/proc`, which trips the kernel's
`mount_too_revealing` check: an unprivileged user namespace can no longer mount a fresh
procfs. flatpak's bwrap sandbox does exactly that in its new PID namespace, so every
`flatpak run` dies with:

```
bwrap: Can't mount proc on /newroot/proc: Operation not permitted
error: ldconfig failed, exit status 256
```

Unmounting it as root at startup restores full `/proc` visibility. Harmless when the
overmount is not there, i.e. without the NVIDIA runtime.

### NVIDIA flatpak GL extension

The extension ref encodes the driver version exactly (`610.43.02` →
`nvidia-610-43-02`), and a mismatch is quiet: flatpak apps start, but `libcuda.so.1` and
`nvidia_drv_video.so` fail to resolve inside the sandbox and GPU acceleration is dead.

Resolving it at startup rather than baking a version keeps the image host-agnostic — the
same image runs on any host, and a host driver bump needs no rebuild. The cost is a
one-off flathub download on the first start of each new container, since
`/var/lib/flatpak` is image state rather than `/config`.

It runs after `02-` because the extension's `apply_extra` step needs a working bwrap,
which needs the overmount gone. Check a mismatch with:

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader
flatpak list --runtime | grep nvidia
```

The extension is deliberately not installed at build time: flatpak cannot resolve the
ref without knowing the host driver, and there is no GPU in the builder.

### The KDE lock screen

`startwm_wayland.sh` launches kwin with `--no-lockscreen`. On Plasma 6 Wayland it is
kwin, not ksmserver, that registers the `org.freedesktop.ScreenSaver` DBus service, so
with that flag the KDE lock screen does nothing at all. Dropping the flag makes kwin
provide the locker.

Locking once at session start has no ordinary path. plasmashell is launched directly
inside a `dbus-run-session` from `startwm_wayland.sh`, so there is no
startplasma/plasma-session (`~/.config/autostart` is never read) and no logind session
(`loginctl lock-session` does not work). The only reliable route is the ScreenSaver DBus
service driven from *inside* that session bus — hence a small helper backgrounded from
the same `bash -c` block, just before plasmashell, where `DBUS_SESSION_BUS_ADDRESS` is
set.

The helper honours `LOCK_ON_STARTUP` so a deployment that authenticates users ahead of
the stream can turn it off at runtime.

> The lock screen is only usable if the `abc` account has a password. Enabling it with
> no password produces an unopenable desktop. See [account
> passwords](#account-passwords).

## full

### Docker-in-Docker and explicit runc

`runc` is installed explicitly and must stay that way while the base needs it. The
LinuxServer base ships `svc-docker` enabled by default plus moby-engine, containerd and
containerd-shim-runc-v2 — but current Fedora bases do not pull in an OCI runtime, and
moby-engine no longer depends on one. Without runc, dockerd dies instantly and s6
restart-loops it every ~4s forever.

The log noise is not the damage — [each restart stacks another tmpfs on
`/tmp`](troubleshooting.md#svc-docker-restart-loop-stacks-tmpfs-on-tmp), which buries
the session D-Bus socket and makes flatpak apps fail silently.

With `INSTALL_DIND=false` the service is **removed** instead. That removal is mandatory
for any image without the docker toolchain, which is why `k8s` and `coder` both do it
too.

Drop `runc` and its assertion once the base ships an OCI runtime again:

```bash
docker run --rm --entrypoint sh <base image> -c 'command -v runc || command -v crun'
```

Harmless to keep either way — unlike the selkies patch, this one just installs a package
that may already be present.

### sshd

Runs unprivileged as `abc`, which is why the shipped config is key-only:
password/PAM authentication needs root. Put your public key in
`/config/.ssh/authorized_keys`. Host keys are generated into `/config` on first start,
so they survive container replacement. Override the config with `SSHD_CONFIG` at
runtime.

### Account passwords

Not baked into the image. They are applied at container start from `$USER_PASSWORD`,
which keeps the password out of git and out of the image layers while still giving the
lock screen an unlockable account. The heredoc delimiter is quoted so `${USER_PASSWORD}`
stays literal in the script and expands at container start.

`INSTALL_ACCOUNT_HOOK` is named to avoid tripping BuildKit's `SecretsUsedInArgOrEnv`
lint rule — it is a boolean switch, and no password is ever a build arg.

## k8s

### Firefox: EGL on X11, then VAAPI

Firefox runs under XWayland here — set `MOZ_ENABLE_WAYLAND=0` in your deployment,
because Firefox's native-Wayland path freezes in an unconditional
`wp_color_manager_v1` roundtrip against this kwin. Firefox also removed the GLX backend,
so on X11 it is EGL or software.

NVIDIA's EGL-on-X11 support lives in two external platform libraries
(`libnvidia-egl-xcb.so.1`, `libnvidia-egl-xlib.so.1`) that the GPU operator does **not**
inject into containers. Without them glvnd falls through to Mesa, which cannot drive the
NVIDIA card (`failed to create dri2 screen`), and Firefox lands on software WebRender —
which in turn sets gfxVars disabling *all* hardware video decode (`Hw codec disabled by
gfxVars`).

The libraries are driver-version-locked, so mount them from the node with a `hostPath`;
the static glvnd configs pointing at them are baked into the image.

`MOZ_DISABLE_RDD_SANDBOX=1` is required for VAAPI inside Firefox's RDD sandbox. It
weakens the sandbox around the media decoder process — acceptable for a single-user
desktop behind authentication, but worth knowing.

### AV1

YouTube serves AV1 to any browser claiming support, and software dav1d decode is exactly
the lag this variant exists to avoid. NVIDIA AV1 hardware decode only arrived with
Ampere, so on Pascal and Turing cards disabling AV1 makes YouTube fall back to VP9,
which those cards decode in hardware. Set `FIREFOX_DISABLE_AV1=false` on Ampere or newer.

## coder

### The agent is a service, not the entrypoint

Coder's stock docker/kubernetes templates make `coder_agent.init_script` the container
ENTRYPOINT. That cannot work here: s6-overlay is PID 1 and owns the whole Wayland
session tree, so overriding the entrypoint gets you an agent and no desktop. The agent
runs as one more s6 longrun instead, and the template hands the init script in as an env
var — so your template must set **no** command or args on the container.

### The init script must be base64

s6-envdir [truncates every env value at the first
newline](troubleshooting.md#container-env-is-truncated-at-the-first-newline). A
multi-line init script passed as a plain env var arrives as just its shebang, the agent
never starts, and the failure looks like nothing happening at all — no error, no log.
Base64 is single-line, so it survives.

Decoding to a *file* rather than piping into a shell also keeps s6 supervising the agent
directly: the init script ends in `exec ./coder agent`, so with an exec'd file the final
process is the agent itself and not a shell wrapping it.

The agent runs as `abc` with `HOME=/config` — this image's home is `/config`, not
`/home/coder`, so the workspace volume must be mounted there. The desktop env is
exported too, so anything launched from `coder ssh` or the web terminal lands on the
running stream instead of failing with "cannot open display".

`DISPLAY=:0` tracks current bases; it was `:1` on older ones and [it will move
again](troubleshooting.md#the-x-display-number-changes-between-base-versions).

### CPU encode is baked in

selkies encoder names are output modes, not hardware backends — see [the encoder
model](troubleshooting.md#the-encoder-model-read-this-first). The LinuxServer base bakes
`SELKIES_ENCODER=x264enc,jpeg`, whose first entry is the *hardware* path, so inheriting
that default into a GPU-less image means a deployment that forgets the override silently
lands on a backend that is not there.

`SELKIES_USE_CPU` must be `true|locked`, not a bare `locked`, which parses to the exact
opposite of the intent.

### Neutralising the GPU autodetect

"No GPU here, so nothing sets `DRINODE`" is not true in practice: a privileged container
gets the host's `/dev`, so on a GPU node `/dev/dri` leaks in and `init-selkies-config`
auto-selects it — with no userspace driver behind it.

Two env families with **opposite polarity** make this a trap, and getting the second one
wrong produces a flat `#181818` desktop while everything reports success. The full
analysis is in [blank flat-colour desktop: the compositor's GPU
probe](troubleshooting.md#blank-flat-colour-desktop-the-compositors-gpu-probe).

`LIBGL_ALWAYS_SOFTWARE=1` keeps *applications* off the driverless render node too. It is
defence in depth, not part of the fix — on its own it does nothing for the blank stream,
because the compositor's probe is Rust/Smithay talking to GBM directly, not mesa GL.

### Sandboxing for Chromium and VS Code

`chrome-sandbox` is not setuid in the base, and a seccomp filter blocks the user-namespace
fallback, so both abort or fail to start wherever a filter is active — which includes a
stock `docker run` (`Seccomp: 2`), not just a restricted pod.

The base's own `wrapped-chromium` already tests `/proc/1/status` for `Seccomp: 0` and adds
`--no-sandbox --test-type` when a filter is present, but only for its own menu launcher.
This stage extends the identical test to the two paths it misses: an appended
`/etc/chromium/chromium.conf` line, so a bare `chromium-browser` behaves like the launcher,
and a `/usr/local/bin/code` wrapper that the `code` desktop entries are repointed at
(`/usr/local/sbin` is a symlink to `bin`, so it wins in `PATH` too).

Deciding at runtime rather than baking the flag in is the point: **a privileged container
keeps its sandbox**. Do not simplify these to an unconditional `--no-sandbox`.

### No HTTP basic auth

The base turns `PASSWORD` into an `/etc/nginx/.htpasswd` entry and switches `auth_basic`
on for both listeners. Coder already authenticates every request at its proxy before it
reaches the workspace, so that is a second login prompt guarding a port only Coder can
route to. The `PASSWORD` block and the four commented `auth_basic` lines it uncomments
are removed from this stage, which makes `PASSWORD` and `CUSTOM_USER` inert here. The
consequence to be deliberate about: run this image standalone with `:3000` published and
there is no password in front of it — the desktop is only as private as the network path
to it.

Worth knowing about the mechanism that goes with them: enabling basic auth is a blanket
`sed -i 's/#//g'` over the rendered config. Nothing else in the file is commented today,
so it does exactly what it means to — and would silently enable anything a future base
happens to comment out.

### TLS material lives in /run

The base self-signs a certificate into `/config/ssl` on first start and reuses whatever
it finds there afterwards. `/config` is the user's mount, which makes an ephemeral
service credential part of the persisted workspace: a volume that came from another uid
leaves `cert.key` (mode 600) unreadable, and a `/config` the session cannot write to
means no certificate at all. Either way nginx fails to load it and exits — and nginx
failing takes the desktop with it, because the stream is served through it.

This stage generates into `/run/ssl` instead, so the certificate is created fresh each
start by whichever uid is running, and no deployment has to reason about a volume's
history. `/run` is already required to be writable — [an `emptyDir` on it is fatal to
omit](unprivileged.md#what-the-deployment-must-supply) — so this needs nothing new from
the deployment.

The other stages keep `/config/ssl`: there the certificate is one a human accepts an
exception for in a browser, and regenerating it on every restart re-prompts them.

### The stock :80 server block

Fedora's `nginx.conf` ships a default `server { listen 80; }` serving
`/usr/share/nginx/html`. LinuxServer never touches it — the desktop is a separate
`conf.d/default.conf` on 3000/3001 — so it is dead weight that nothing routes to, and it
is removed here.

It is not merely untidy. Binding a port below 1024 needs `CAP_NET_BIND_SERVICE` unless
`net.ipv4.ip_unprivileged_port_start` is 0, and that sysctl is **not** uniform across
container runtimes: Docker and most containerd/kubelet setups default it to 0, CRI-O does
not. So the identical unprivileged image binds :80 happily on one cluster and dies with
`bind() to 0.0.0.0:80 failed (13: Permission denied)` on another — and nginx exiting
takes the desktop with it.

Beware the ordering when reading logs: nginx parses its whole configuration before it
binds anything, so a certificate it cannot load masks a port it cannot bind. Fixing the
first is what reveals the second.

### Running unprivileged

`UNPRIVILEGED=true` builds this stage to run as any non-root uid with no capabilities.
It is off by default because it makes `PUID`/`PGID` inert and relaxes group permissions on
paths the init scripts write. What it changes, what the deployment must supply, and why
`SETUID`/`SETGID` cannot help: [unprivileged.md](unprivileged.md).

The `svc-selkies` `PULSE_RUNTIME_PATH` patch is applied to this stage **unconditionally**,
because it is a strict generalisation — unset, the behaviour is byte-identical to upstream.
