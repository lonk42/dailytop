# Troubleshooting

Notes on the LinuxServer webtop / selkies stack. Most of these are failures where
**everything reports success** and the only symptom is that something looks wrong, so
the diagnostic step matters more than the fix.

Logs live **only** in the container's stdout — `docker logs <container>` or
`kubectl logs <pod>`. There is no journal and nothing on disk inside the container.

- [The encoder model (read this first)](#the-encoder-model-read-this-first)
- [Blank flat-colour desktop: the compositor's GPU probe](#blank-flat-colour-desktop-the-compositors-gpu-probe)
- [NVIDIA: exposing devices is not injecting the driver](#nvidia-exposing-devices-is-not-injecting-the-driver)
- [What `privileged` actually buys: unmasked `/proc`](#what-privileged-actually-buys-unmasked-proc)
- [Container env is truncated at the first newline](#container-env-is-truncated-at-the-first-newline)
- [`svc-docker` restart loop stacks tmpfs on `/tmp`](#svc-docker-restart-loop-stacks-tmpfs-on-tmp)
- ["Waiting for stream" — the VAAPI fd leak](#waiting-for-stream--the-vaapi-fd-leak)
- [The desktop restarted and the stream never came back](#the-desktop-restarted-and-the-stream-never-came-back)
- [Never restart selkies to fix the desktop](#never-restart-selkies-to-fix-the-desktop)
- [The nested dockerd takes the container's network down](#the-nested-dockerd-takes-the-containers-network-down)
- [Stuck modifier key](#stuck-modifier-key)
- [The X display number changes between base versions](#the-x-display-number-changes-between-base-versions)
- [Upstream patches carried here, and when to delete them](#upstream-patches-carried-here-and-when-to-delete-them)
- [Builds inside the desktop copy every layer](#builds-inside-the-desktop-copy-every-layer)
- [Build environment gotchas](#build-environment-gotchas)
- [Container hangs at `mod-init` on a tunnelled host (MTU)](#container-hangs-at-mod-init-on-a-tunnelled-host-mtu)

---

## The encoder model (read this first)

The selkies `SELKIES_ENCODER` names are **output modes, not hardware backends**:

| Value | What it actually is |
|---|---|
| `jpeg` | CPU, MJPEG |
| `x264enc` | H.264 full-frame. **The HARDWARE path.** pixelflux picks the backend at runtime from the *driver behind `DRI_NODE`*: `i915`/`amdgpu` → VAAPI, `nvidia` → NVENC (CUDA + `libnvidia-encode`). Zero-copy when `DRINODE == DRI_NODE`. |
| `x264enc-striped` | H.264 striped, **forced CPU** (libx264) |

So `x264enc` on a machine with no usable GPU driver is a misconfiguration, not a
graceful default — and it is what the LinuxServer base bakes. `SELKIES_ENCODER` is an
ordered fallback list; the first entry is the default.

`SELKIES_USE_CPU=true|locked` forces the CPU encoder regardless of `DRI_NODE`. **The
`|locked` suffix is load-bearing and `locked` alone silently does the opposite.**
`selkies/settings.py` parses bools as:

```python
is_locked    = '|locked' in val_str
base_val_str = val_str.split('|')[0]
bool_value   = base_val_str in ['true', '1']
```

A bare `locked` therefore yields `(False, False)` — CPU mode **off** and **unlocked**.
`|locked` is what stops the browser UI flipping the encoder back to GPU mid-session.

---

## Blank flat-colour desktop: the compositor's GPU probe

**Symptom:** the stream connects, capture starts, the encoder runs, the browser decodes
frames — and every frame is a single flat colour (`#181818` with the default Plasma
theme). Nothing logs an error downstream.

**Cause:** there are *two* independent GPU probes, and disarming only the encoder's
leaves the other one live. pixelflux is itself a **Smithay compositor** — it is the
`wayland-1` that `kwin_wayland --xwayland` nests inside — and it runs its own
`auto_gpu` probe, which **defaults to on**. If it finds a render node with no userspace
driver behind it, it half-initialises GL/GBM and falls back to Pixman:

```
[Wayland] AUTO_GPU enabled. Selected: /dev/dri/renderD128
MESA-LOADER: failed to open nvidia-drm: /usr/lib64/gbm/nvidia-drm_gbm.so
pci id for fd 16: 10de:1e84, driver (null)
[Wayland] Warning: Failed to bind EGL to Wayland Display: EglExtensionNotSupported
KMS: DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied
[Wayland] GPU Initialization failed: … Falling back to Software Renderer (Pixman).
```

**That fallback is not equivalent to starting in Pixman.** The half-initialised GL state
means no client buffer is ever imported into the software renderer. kwin composes
correctly the entire time; nothing downstream can see it. Measured on one such session:
**1 distinct colour** over 1600x900, **~28 KB of video across ~1800 frames**.

So *"capture started + blank frames + idle encoder"* is the signature of **this** bug,
not of a dead session. Don't go hunting kwin.

**Fix:** `SELKIES_AUTO_GPU=false` (and `AUTO_GPU=false`), which makes the compositor
never touch `/dev/dri` at all:

```
[Wayland] No render node. Initializing Software Renderer (Pixman).
```

The same session then paints a full Plasma desktop — **37,744 distinct colours**
measured. No `MESA-LOADER` errors anywhere either: with no dmabuf global advertised on
`wayland-1`, kwin and its clients stay on `wl_shm` and never probe the dead node. **This
stack software-renders correctly; the probe must never be allowed to run.**

`LIBGL_ALWAYS_SOFTWARE=1` should be set too, to keep *applications* (plasmashell,
Firefox, VS Code, Electron) off a driverless node — but it is defence in depth, **not**
the fix. On its own it does nothing for the blank stream, because the compositor's probe
is Rust/Smithay talking to GBM directly, not mesa GL.

### The two variable families have opposite polarity

The two families are read differently, and it is easy to get backwards:

- `DRI_NODE` / `DRINODE` / `SELKIES_RENDER_DRI` are read with **set-ness guards**
  (`[ -z ${DRI_NODE+x} ]`), so they must be **deleted**. An empty-but-set value still
  reads as "configured" and suppresses nothing downstream.
- `SELKIES_AUTO_GPU` / `AUTO_GPU` are read as
  `os.environ.get("SELKIES_AUTO_GPU") or os.environ.get("AUTO_GPU") or "true"`, so
  **deleting them turns the probe ON**. They must be present and literally `"false"`.

Note also that a **privileged container gets the host's `/dev`**, so "there's no GPU in
this pod, therefore nothing sets `DRINODE`" is false on any GPU-capable host:

```bash
docker run --rm --privileged <image> -c 'ls -l /dev/dri'
# crw-rw-rw- 1 root root 226, 128 /dev/dri/renderD128
# (unprivileged: "No such file or directory")
```

`init-selkies-config` then autodetects it — its guard only checks that `renderD128`
exists, `renderD129` does not, and `DRI_NODE` is unset — and writes **both** `DRI_NODE`
and `DRINODE` into `/run/s6/container_environment`. The `coder` target's
`/custom-cont-init.d/04-no-gpu.sh` corrects this. That it runs at the right moment was
verified against the *compiled* s6-rc database, not assumed:

```
init-selkies-config → init-video → … → init-custom-files → init-services → svc-*
s6-rc-db -c <db> all-dependencies init-custom-files | grep -x init-selkies-config   # matches
```

i.e. `/custom-cont-init.d` runs **after** the autodetect and **before** any service.

### Scoring a frame objectively

Eyeballing a dark desktop is unreliable, and there is no server-side screenshot to
cross-check with: `grim` needs `zwlr_screencopy`, and pixelflux advertises only
`wl_shm`, `xdg_wm_base`, `zwlr_layer_shell_v1`, `zwlr_data_control_*` and (in GL mode)
`zwp_linux_dmabuf_v1`. **The browser canvas is the only ground truth.** Read the pixels
off `#videoCanvas` (`drawImage` → `getImageData` → count distinct RGB): **1 distinct
colour = the bug, tens of thousands = a real desktop.**

Reproducing a GPU-less cluster deployment locally is much faster than a cluster
round-trip, and `--privileged` reproduces the `/dev/dri` leak exactly:

```bash
docker run -d --name dt --privileged --shm-size=2gb \
  -p 3010:3000 -p 3011:3001 -e PUID=1000 -e PGID=1000 <image>
```

Then open **`https://<host>:3011/`** — it must be HTTPS. On plain `:3000` the client
refuses to start with `FATAL: Not in a secure context. WebCodecs require HTTPS.`

---

## NVIDIA: exposing devices is not injecting the driver

`privileged: true` exposes the device nodes and `/proc/driver/nvidia`, but it **does not
inject the userspace driver**. Only the NVIDIA container runtime mounts `nvidia-smi`,
`libGLX_nvidia`, `libnvidia-allocator` (the GBM backend), `libcuda` and
`libnvidia-encode`. Without injection you get `MESA-LOADER: failed to open nvidia-drm …
nvidia-drm_gbm.so`, a fallback to software rendering, and no NVENC.

Required, on Docker:

```yaml
runtime: nvidia
environment:
  - NVIDIA_VISIBLE_DEVICES=all        # REQUIRED -- empty/unset ⇒ no injection at all
  - NVIDIA_DRIVER_CAPABILITIES=all    # needs compute,video (NVENC/CUDA) + graphics (EGL)
  - DRINODE=/dev/dri/renderD128
  - DRI_NODE=/dev/dri/renderD128      # ⇒ NVENC; zero-copy when == DRINODE
```

On Kubernetes the equivalent is `runtimeClassName: nvidia`.

**Confirm injection before debugging anything else:**

```bash
docker exec <container> nvidia-smi                              # must list the GPU
docker inspect -f '{{.HostConfig.Runtime}}' <container>          # must say: nvidia
docker logs <container> | grep -E 'Driver:|NVENC|Mode:'          # NVENC initialized
nvidia-smi dmon -s u                                            # ENC > 0 while streaming
```

If `nvidia-smi` works but GL is still llvmpipe, the image is missing EGL glue —
add `egl-wayland` / `libglvnd`.

Two further notes: GeForce Pascal has a low concurrent-NVENC-session cap (~2–3, fine for
one stream). And the **flatpak** NVIDIA GL extension ref encodes the exact host driver
version (`org.freedesktop.Platform.GL.nvidia-610-43-02`), so it cannot be baked into a
host-agnostic image — this repo installs it at container start instead
(`/custom-cont-init.d/03-nvidia-flatpak-gl.sh`). A mismatch is quiet: flatpak apps
start, but `libcuda.so.1` and `nvidia_drv_video.so` fail to resolve inside the sandbox.
Check with:

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader
flatpak list --runtime | grep nvidia
```

---

## What `privileged` actually buys: unmasked `/proc`

flatpak's bwrap failure is about **`/proc` masking**, not capabilities. Measured against
this image with `bwrap --ro-bind / / --proc /proc --unshare-pid --unshare-user`:

| container settings | result |
|---|---|
| default | `No permissions to creating new namespace` |
| `seccomp=unconfined` | `bwrap: Can't mount proc on /newroot/proc` |
| `seccomp=unconfined` + `--cap-add SYS_ADMIN` | `Can't mount proc on /newroot/proc` |
| `seccomp=unconfined` + `--security-opt systempaths=unconfined` | **OK** |
| `--privileged` | **OK** |

Docker and Kubernetes mask 13 paths under `/proc` (`/proc/bus`, `/proc/fs`, `/proc/irq`,
`/proc/sys`, `/proc/kcore`, …) and those masks trip the kernel's `mount_too_revealing`
check. **`SYS_ADMIN` alone does not help.** The Kubernetes equivalent of
`systempaths=unconfined` is `securityContext.procMount: Unmasked` — a narrower grant
than `privileged: true`, and it avoids the `/dev/dri` leak described above. Keep
`privileged: true` only as a fallback.

If your image has no flatpaks at all (like the `coder` target), you need none of this.

---

## Container env is truncated at the first newline

s6-overlay exposes container env through `/run/s6/container_environment`, which
`with-contenv` reads via **`s6-envdir` — and that keeps only up to the first `\n` of
each value.** Any multi-line env var (a script, a PEM, a JSON blob) arrives as its first
line only, with **no error**.

Reproduce it in two lines:

```bash
mkdir /tmp/e && printf 'line1\nline2\n' > /tmp/e/FOO
/command/s6-envdir /tmp/e printenv FOO      # prints only "line1"
```

This is why the Coder agent init script is passed as `CODER_AGENT_INIT_SCRIPT_B64`:
base64 is single-line, so it survives intact. Verified failure mode without it: a 4-line
script arrives as just `#!/usr/bin/env sh`, the agent never starts, and it looks like
nothing happened.

Pass anything multi-line as base64 and decode it in the run script. Decoding to a
**file** and `exec`ing that (rather than piping into a shell) also matters when the
script ends in `exec <daemon>`: s6 then supervises the daemon directly instead of a
shell wrapping it.

Related: **an s6 longrun that exits gets restarted immediately, forever.** For services
that can be misconfigured, park (`exec sleep infinity`) with one clear log line instead
of exiting. See the next section for why that matters here.

---

## `svc-docker` restart loop stacks tmpfs on `/tmp`

The LinuxServer webtop base ships `svc-docker` (an s6 service running
`/usr/local/bin/dind` → `dockerd`) **enabled by default**, and current Fedora bases ship
`moby-engine` + `containerd` + `containerd-shim-runc-v2` but **no OCI runtime** — Fedora
44's `moby-engine` no longer depends on one. Without `runc`, `dockerd` dies instantly:

```
error initializing buildkit: error creating buildkit instance: failed to find runc binary
```

and s6 restarts it **every ~4 seconds forever**.

**The noise is not the damage.** Each `dind` start mounts a tmpfs on `/tmp` and nothing
unmounts them, so they **stack** — one anonymous tmpfs over `/tmp` per restart (192
observed in one case). The session D-Bus socket lives at `/tmp/dbus-XXXXXXXX`, so it
gets buried, and the failure is confusing: `ss -xl` shows the socket `LISTEN`ing
while `ls /tmp` and even `find /` cannot see it, and anything written to `/tmp` vanishes
within seconds. Flatpak apps needing the session bus then fail **silently** — they exit
0 with no window and no error.

**Diagnose:**

```bash
grep -c " /tmp " /proc/self/mountinfo   # healthy = 1-2, and FLAT over time
pgrep -x dind                          # should find nothing
```

So: any image without the docker toolchain **must** remove the service
(`rm /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker`), and any image with it must
ensure an OCI runtime is present. Both are handled by the `INSTALL_DIND` build arg.

---

## nginx exits on the certificate in `/config`

**Symptom:** no desktop and no stream at all; `docker logs` / `kubectl logs` end with

```
nginx: [emerg] cannot load certificate "/config/ssl/cert.pem": BIO_new_file() failed
```

or `cannot load certificate key … Permission denied`. nginx serves the stream, so nginx
refusing to start looks like the whole image is broken.

**Cause:** the base self-signs into `/config/ssl` on first start and reuses whatever it
finds there. `/config` is the user's volume, so the certificate outlives the container
and its ownership does not have to match the uid now running:

- a volume written by an earlier deployment under a different uid leaves `cert.key`
  (mode 600) unreadable — the `Permission denied` form, and the one arbitrary-uid
  platforms hit;
- a `/config` the session cannot write to means the `openssl req` never produced a
  certificate — the `BIO_new_file()` form.

**Check** which it is before changing anything:

```bash
kubectl exec <pod> -- ls -ln /config/ssl   # missing, or owned by a uid that is not yours
kubectl exec <pod> -- id
```

**Fix:** delete `/config/ssl` and restart — the init script regenerates it under the
current uid. The `coder` stage sidesteps the class entirely by generating into `/run/ssl`
instead; see [TLS material lives in
/run](image-design.md#tls-material-lives-in-run). On `full` and `k8s` the certificate
stays in `/config` deliberately, so a browser exception survives a restart.

---

## nginx cannot bind :80 as a non-root uid

**Symptom:** no desktop, and

```
nginx: [emerg] bind() to 0.0.0.0:80 failed (13: Permission denied)
```

on a cluster that runs the container as an arbitrary uid — while the same image is fine
under Docker and on k3s.

**Cause:** two things compounding. Fedora's stock `nginx.conf` carries a default
`server { listen 80; }` block that has nothing to do with the desktop (that is
`conf.d/default.conf` on 3000/3001), and binding below 1024 needs
`CAP_NET_BIND_SERVICE` unless `net.ipv4.ip_unprivileged_port_start` is 0. Docker and most
containerd/kubelet setups set that sysctl to 0; **CRI-O leaves it at 1024**, so the
runtime decides whether the image works.

**Fix:** the `coder` stage removes the block — [the stock :80 server
block](image-design.md#the-stock-80-server-block). Elsewhere, either delete the block
from `/etc/nginx/nginx.conf` or set the sysctl in the pod:

```yaml
securityContext:
  sysctls:
    - name: net.ipv4.ip_unprivileged_port_start
      value: "0"
```

Do not add `CAP_NET_BIND_SERVICE` to fix this: [k8s never sets ambient
capabilities](unprivileged.md#no-capabilities-are-needed), so a non-root process does not
get it anyway.

**Reproduce it locally** on a runtime that would otherwise hide it:
`docker run --sysctl net.ipv4.ip_unprivileged_port_start=1024 …`

---

## Firefox: cannot open display :0

**Symptom:** Firefox refuses to start with `Error: cannot open display: :0` while Chromium
and the rest of the desktop are fine. Seen only when running as a non-root uid.

**Cause:** three things lining up.

1. The base's `startwm_wayland.sh` creates Xwayland's socket directory with
   `sudo mkdir -p /tmp/.X11-unix`.
2. `sudo` cannot elevate in an unprivileged container — it is setuid, and
   `allowPrivilegeEscalation: false` sets `NoNewPrivs`. So the command fails and the
   directory is never created. (The session user could have created it unaided; `/tmp` is
   `1777`. The `sudo` is what breaks it.)
3. Xwayland has nowhere to bind its socket, so **there is no X display at all** — while
   the same script exports `DISPLAY=:0` and `MOZ_ENABLE_WAYLAND=0`, pinning Firefox to
   X11.

Chromium hides the problem because it uses the Wayland ozone backend and never touches
X. Any X11-only application fails the same way Firefox does.

**Check:**

```bash
ls -ld /tmp/.X11-unix      # missing = this bug
pgrep -a Xwayland          # nothing = confirmed
```

**Fix:** the `coder` stage drops the two `sudo` prefixes, so the session creates the
directory itself. Without a rebuild, `mkdir -p /tmp/.X11-unix && chmod 1777
/tmp/.X11-unix` in the pod followed by a restart of the desktop is the same thing, or
launch Firefox with `MOZ_ENABLE_WAYLAND=1` to bypass X entirely.

Leaving `MOZ_ENABLE_WAYLAND=0` alone is deliberate: X11 is the path the NVIDIA
[EGL-on-X11 VAAPI wiring](image-design.md#firefox-egl-on-x11-then-vaapi) depends on, and
that should not differ between stages for a reason this narrow.

---

## Dashboard loads, then flashes every few seconds

**Symptom:** the selkies web UI appears but reloads on a short cycle, and the nginx error
log repeats

```
connect() failed (111: Connection refused) while connecting to upstream,
upstream: "http://127.0.0.1:8082/websockets…"
```

**Cause:** nginx is fine — it serves the dashboard as static files and only needs selkies
for the websocket. Port 8082 is selkies' data websocket, so a refusal means **the selkies
python process is not running**. Confirm before going further:

```bash
pgrep -af selkies            # nothing = selkies never started
pgrep -a pulseaudio          # see below
```

Two ways selkies fails to be there, and they look identical from the browser:

1. **It never started.** `svc-selkies` waits for pulseaudio's pidfile before it execs
   selkies, and in the stock base that wait is unbounded and pulseaudio's output is
   discarded — so a pulseaudio that refuses to start silently costs you the desktop. See
   [when pulseaudio does not start](unprivileged.md#when-pulseaudio-does-not-start). The
   usual trigger is an unset `PULSE_RUNTIME_PATH` on a non-root deployment.
2. **It is crash-looping.** selkies logs to the container log, so look for a Python
   traceback repeating on the same interval as the flashing.

Do not restart selkies to test a fix — [it is the parent of the whole Wayland
session](#never-restart-selkies-to-fix-the-desktop).

---

## "Waiting for stream" — the VAAPI fd leak

Historical, on the Intel/VAAPI path: plain `x264enc` (VAAPI) **leaked
`/dev/dri/renderD128` fds on every browser reconnect** until the GPU ran out of encode
surfaces. The backend then logs success but emits no frames, and the browser shows
"Waiting for stream" indefinitely.

Symptom check: sample the `renderD128` fds held by the selkies PID across reconnect
cycles. A healthy encoder stays flat; a leaking one climbs and never releases. There is
no in-place way to drain the leak — fix the encoder choice instead of restarting.

Mitigation was `SELKIES_ENCODER=x264enc-striped,jpeg` plus
`SELKIES_USE_CPU=true|locked` to stay on CPU. This is a **VAAPI-specific** code path;
NVENC is separate, so re-test it fresh rather than assuming it leaks too.

Measured on NVENC (RTX 2070 SUPER) across five browser reconnect cycles: total fds,
`nvidia`/`dri` fds and dmabufs all flat at 73 / 29 / 8. **NVENC does not leak.** A
"Waiting for stream" on the NVENC path is the next section, not this one.

---

## The desktop restarted and the stream never came back

The browser sits on "Waiting for stream" forever. Everything reports healthy: the pod is
`Running` with no restarts, `s6-svstat` says every service is `up`, and the logs show a
complete, successful pipeline start on each connect —

```
[Wayland] Nvidia Encoder detected. Initializing NVENC...
[NVENC] Initialized successfully (4:4:4 mode: false).
[Wayland] Decision: Zero-Copy path active.
Stream settings active -> Res: 2560x1300 | FPS: 60.0 | ...
```

— and then no frames, ever. Audio works. The WebSocket is alive and chatty: a 20-second
connection takes ~800 frames totalling ~10 KB, which is stats and cursor updates with
**zero video payload**. Forcing damage by launching an app changes nothing.

### Cause

In `PIXELFLUX_WAYLAND` mode selkies is the outer compositor and kwin nests inside it as
a client. selkies binds its screen capture to the desktop session **once**. Upstream's
`svc-de/run` waits only for the socket to exist:

```bash
SOCKET_PATH="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY:-wayland-1}"
while [ ! -e "${SOCKET_PATH}" ]; do sleep 0.5; done
```

That cannot distinguish a fresh selkies from one that already bound an earlier session.
So when the desktop dies on its own and s6 restarts it, the new kwin connects to the old
socket, is accepted at the protocol level, and is never captured.

The coupling only exists in one direction: restarting selkies takes the desktop down
with it, but restarting the desktop leaves selkies untouched. s6 healing `svc-de` is
precisely what produces the broken state, which is why nothing anywhere reports a fault.

Confirm it by comparing service ages — the desktop far younger than selkies is the tell:

```bash
s6-svstat -o updownfor /run/service/svc-selkies   # e.g. 682067
s6-svstat -o updownfor /run/service/svc-de        # e.g. 157764
```

### Recovery on a running container

Restarting `svc-de` alone does **not** work — verified; it reproduces the same dead
stream. Restart selkies, which brings the desktop back with it:

```bash
s6-svc -r /run/service/svc-selkies
```

This kills every open app, for the reason in
[never restart selkies](#never-restart-selkies-to-fix-the-desktop). There is no in-place
way to re-bind the capture.

### The fix carried here

`base` inserts a guard ahead of that socket wait: if the socket already exists **and**
selkies has been up more than 60 seconds, the desktop is starting against a selkies
that served an earlier session, so it restarts selkies and exits rather than joining a
pairing that cannot stream. s6 brings the desktop back behind it. The guard lives in
`run` rather than `finish` so it never executes during container shutdown, and the
60-second floor is what stops it from firing on its own restart — at boot the two start
seconds apart.

The chart's probes carry the same check independently, so an older image still recovers:
see `probes.sessionCommand` in `values.yaml`.

---

## No audio: the output sink was never created

The desktop is otherwise perfect — video streams, apps run, the browser's audio toggle
does nothing. `docker logs` shows one line repeating on every browser connect:

```
[pcmflux] Attempting to connect to PulseAudio device: output.monitor (latency 10ms)
[pcmflux] SUCCESS: Connected to PulseAudio.
[pcmflux] ERROR: PulseAudio source not found: 'output.monitor'
ERROR:data_websocket:Failed to start pcmflux audio pipeline: audio capture failed to start
```

Note the two lines are not contradictory: pcmflux connects to the **server** fine, then
fails to find the **source**. PulseAudio itself is healthy throughout, which is what
sends people looking in the wrong place.

selkies records the monitor of a null sink named `output`. Confirm it is missing:

```bash
pactl list short sinks     # expect: output, input.  Bug: a lone `auto_null`
pactl list short sources   # expect: output.monitor
pactl list short modules   # bug: nothing past the stock default.pa modules
```

**`auto_null` is the tell.** It is `module-always-sink`'s fallback, loaded only when no
sink exists at all — so its presence proves the setup never ran, rather than having run
and produced something wrong. Applications happily play into it and are never captured.

### Cause

Upstream's `svc-selkies/run` created the sinks like this:

```bash
if [ ! -f '/dev/shm/audio.lock' ]; then
  until [ -f /defaults/pid ]; do sleep .5; done   # (1)
  pactl load-module module-null-sink sink_name="output" ...
  pactl load-module module-null-sink sink_name="input"  ...
  touch /dev/shm/audio.lock                        # (2)
fi
```

Two defects compound:

1. **The pidfile is not readiness.** PulseAudio writes it early in startup, before
   `module-native-protocol-unix` opens the socket. Lose that race and both `pactl` calls
   fail.
2. **The lock is stamped regardless of outcome.** Nothing checks the exit status, so a
   lost race is latched for the life of the container, and the retry that would fix it
   never happens.

Because it is a race, it is intermittent: the same image can boot fine a hundred times
and fail on the hundred-and-first. Nothing has to change for it to start happening.

### The fix carried here

`base` replaces the whole block with `/usr/local/bin/selkies-audio-setup`, which:

- waits for **`pactl info` to succeed** — the server answering, not a file existing —
  bounded at 60s, and resolves the socket from `PULSE_RUNTIME_PATH` rather than a
  hardcoded path;
- creates each sink only if absent, so it is idempotent;
- **only touches the lock once `output.monitor` actually exists**, so a failure is
  retried on the next start instead of being frozen in;
- logs what it did either way.

`base` also stops discarding pulseaudio's stderr (`--log-level=0` keeps it to errors),
because the original block's failure was completely invisible in `docker logs`.

### Recovering a running container without restarting it

Restarting the container fixes it, but selkies parents the whole Wayland session, so that
kills every open app — see [never restart selkies](#never-restart-selkies-to-fix-the-desktop).
Create the sinks in place instead:

```bash
docker exec -u abc <container> env PULSE_RUNTIME_PATH=/defaults sh -c '
  pactl load-module module-null-sink sink_name=output sink_properties=device.description=output
  pactl load-module module-null-sink sink_name=input  sink_properties=device.description=input
  pactl set-default-sink output
  for i in $(pactl list short sink-inputs | cut -f1); do pactl move-sink-input $i output; done'
```

`auto_null` unloads itself as soon as a real sink appears, and already-running streams
have to be moved across explicitly — they stay on the old sink otherwise. Audio resumes
on the next browser reconnect, since capture only starts when a client sends
`START_AUDIO`.

---

## No icons anywhere, and every flatpak fails with `Permission denied`

On a **fresh named volume** only. The menu has entries but none of them draw an icon, the
panel is bare, `flatpak run` exits `error: Permission denied`, and the log carries
`dconf will not work properly`.

Build-time tools run as root with `HOME=/config`, so `flatpak`, `terraform` and `vim`
leave root-owned `.cache`, `.config`, `.local`, `.terraform.d` and `.viminfo` in the
image. Docker seeds an empty named volume from the image, droppings and all, and `abc`
cannot write its own cache. Plasma silently renders no icon at all when it cannot create
`$XDG_CACHE_HOME/*.kcache`; `ksycoca` is written earlier and survives, which is why the
menu keeps its entries.

```bash
docker exec <c> find /config -mindepth 1 -maxdepth 1 ! -user abc -printf '%u %p\n'
docker exec <c> ls /config/.cache/*.kcache        # absent = this fault
```

Each stage now strips them at the end of its build, so the fix is to rebuild. To recover a
volume already seeded from an older image, `chown -R abc:abc /config` and restart the
container — the permissions alone are not enough, because the running Plasma built its
cache objects at session start and does not retry.

A **bind** mount is immune: it masks the image's `/config` entirely and seeds nothing.
That is why this never appears on a deployment that binds a host directory.

---

## Video caps the stream around 20fps, but the desktop is smooth

The desktop feels fine and the selkies FPS counter reaches 60, until a video plays — then
it settles near 20 and stays there. The instinct is to look at the encoder. It is not the
encoder.

Selkies encodes what changes. If the stream reports 20fps, the screen is *changing* 20
times a second, and the browser is what cannot paint faster. Confirm before touching
anything else: during playback, selkies and kwin sit in single-digit CPU, NVENC
utilisation is low, and the **Firefox parent process** burns well over 100%.

The check that settles it — the RDD process is where Firefox decodes video:

```bash
main=$(pgrep -o -f /usr/lib64/firefox/firefox)
for p in $main $(pgrep -P $main); do
  printf '%-18s dri=%s\n' "$(cat /proc/$p/comm)" "$(ls -l /proc/$p/fd | grep -c /dev/dri)"
done
nvidia-smi --query-gpu=utilization.decoder --format=csv,noheader   # 0% while playing
```

`RDD Process dri=0` during playback means every frame is decoded on the CPU. Three things
have to be true together, and any one missing produces exactly this symptom:

1. The EGL-on-X11 platform libraries are mounted, so Firefox gets hardware WebRender —
   [image-design.md](image-design.md#firefox-egl-on-x11-then-vaapi). Software WebRender
   disables hardware decode wholesale, whatever the prefs say.
2. `MOZ_DISABLE_RDD_SANDBOX=1`, or the RDD process cannot open `/dev/dri` at all.
3. `LIBVA_DRIVER_NAME=nvidia` and `NVD_BACKEND=direct`. Verify the driver itself with
   `vainfo`: a working setup prints `VA-API NVDEC driver [direct backend]` and lists the
   profiles, and it is worth checking first because it clears the whole lower half of the
   stack in one command.

A passing `vainfo` alongside `RDD dri=0` narrows it to 1 or 2 — the driver works and
Firefox is not reaching it.

---

## Never restart selkies to fix the desktop

In pixelflux/Wayland mode (`PIXELFLUX_WAYLAND=true`), **selkies is the parent of the
whole Wayland session.** Restarting it — or the container — tears down and recreates the
desktop, killing every open app.

`svc-de` (kwin + plasma) and `svc-selkies` are separate s6 services, and kwin is *not* a
process-child of selkies, so it looks safe to bounce selkies alone. **It is not** —
doing so still takes Plasma down (observed twice). The process-tree independence is
misleading; there is an s6-rc/capture coupling.

---

## The nested dockerd takes the container's network down

Networking works for the first few seconds after start, then stops — around the time
`svc-docker` brings the inner dockerd up. Only with `/var/lib/docker` on a **persistent**
mount; without it the same image is fine, which makes the mount look like the culprit.

It is not. The mount only makes the inner dockerd's networks survive a restart, and one
of them overlaps the subnet the container itself is on.

Docker allocates bridge subnets from `172.17.0.0/16`–`172.31.0.0/16`. The inner dockerd
does that **inside this container's own network namespace**, where the container's own
address already lives — and on any ordinary Docker host that address is in the same
range. When dockerd restores a network whose subnet matches, its bridge takes the
container's gateway address and a second route for that subnet appears. Traffic leaves
by the wrong interface and the container goes dark.

Confirm it — compare what the container is on against what the inner daemon has stored:

```bash
docker inspect <container> --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} gw={{.Gateway}}{{end}}'
sudo strings /path/to/dind/network/files/local-kv.db | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | sort -u
```

An address in the second list that covers the address in the first is the fault. Note
that the inner default bridge at `172.17.0.0/16` is a red herring unless the container
happens to be on it; the one that bites is whichever network was created **later**,
since that is the one that drifts into a subnet already in use.

### The fix carried here

`full` writes `default-address-pools` into the inner daemon's `/etc/docker/daemon.json`,
moving its allocations to `DIND_ADDRESS_POOL` (`10.201.0.0/16` in `/24`s) — clear of the
range outer Docker hands out. Both are build args.

**Pools only apply to networks created afterwards.** A network already in the persistent
data root keeps its subnet, so an existing deployment has to recreate it (`docker
network rm` inside the DinD, or `docker compose up` for the project that owns it) or
drop `network/files/local-kv.db` to have the daemon rebuild from scratch.

Pinning the *outer* network somewhere outside `172.16/12` fixes it independently of the
image, and is the quicker move on a running deployment:

```yaml
networks:
  default:
    ipam:
      config:
        - subnet: 10.99.42.0/24
```

Keep that subnet and `DIND_ADDRESS_POOL` apart, or the fix becomes the bug.

---

## Stuck modifier key

**Symptom:** the desktop behaves as if a modifier is permanently held — clicks
rubber-band-select (Shift), shortcuts fire (Ctrl), menus no-op (Alt), or everything
types uppercase (Shift *or* Caps Lock) — and the user cannot release it from the browser.

**Diagnose before injecting anything: there are two faults with opposite fixes**, and a
latched Caps Lock is indistinguishable from a stuck Shift by symptom alone. Read the
real modifier mask off the X server:

```bash
export XDG_RUNTIME_DIR=/config/.XDG DISPLAY=:0   # probe the display first, see below
/lsiopy/bin/python3 -c "
from Xlib import display
d=display.Display()
m=d.screen().root.query_pointer().mask
names=['Shift','Lock','Control','Mod1(Alt)','Mod2(Num)','Mod3','Mod4(Super)','Mod5(AltGr)']
print('mask=0x%x' % m, [n for i,n in enumerate(names) if m & (1<<i)])
"
```

- `Lock` set (`mask=0x2`) ⇒ **Caps Lock is latched.** The fix is a *single toggling
  press*: `xdotool key Caps_Lock`. The down→up cycle below **will not fix this**, and
  loops that defensively skip lock keys skip the only key that is actually stuck.
- Anything else ⇒ a genuine stuck modifier; use the down→up cycle.

Use this mask, **not** `xdotool getmodifiers` — the latter returned empty output (exit
1) while `Lock` was demonstrably set. `xmodmap -pm` also prints an empty modifier map
here, so it is no help either.

**Mental model:** in this stack kwin gets **all** input via the **libei/EIS portal from
selkies**. kwin holds a `/memfd:eis keymap` fd and **no `/dev/input/event*` fds at all**
(check `ls -l /proc/<kwin-pid>/fd`). Consequences:

- Host input devices visible inside a privileged container are a **red herring** —
  their keystrokes do not flow into this session through evdev.
- The stuck modifier is latched in **kwin's per-seat xkb state**, on the EIS keyboard
  **selkies owns**. Browser key-taps and full page reloads don't clear it, because
  selkies keeps that EIS device alive across websocket reconnects.

**The fix (non-destructive, no restarts):** Xwayland here runs with
`-enable-ei-portal`, so **XTEST synthetic input is forwarded into kwin's Wayland seat
over EIS**, and kwin's xkb state is per-seat and keyed by keycode, not by device. A bare
`xdotool keyup` does nothing (X emits no release for a key it thinks is already up), so
send a real **down→up cycle**:

```bash
export XDG_RUNTIME_DIR=/config/.XDG DISPLAY=:0
for k in Alt_L Alt_R Control_L Control_R Shift_L Shift_R Super_L Super_R Meta_L ISO_Level3_Shift; do
  xdotool keydown "$k"; xdotool keyup "$k"
done
```

Then re-read the mask to confirm (`0x0` means the latch is gone). That check is
authoritative for the X side; the Wayland seat is not directly observable, so have the
user test in the stream too. `wtype` cannot help — kwin disables the Wayland
virtual-keyboard protocol (`Compositor does not support the virtual keyboard protocol`).

---

## The X display number changes between base versions

**Always probe; never assume.** It decides whether any `xdotool`/XTEST recovery works at
all, and it has genuinely differed between LinuxServer releases — `:1` on some (where
`:0` is unreachable), `:0` on others (where `startwm_wayland.sh` does
`unset DISPLAY; export DISPLAY=:0`). Both were true at different times, so a flat claim
either way is a trap.

```bash
pgrep -af Xwayland                  # the ":N" it was started with is authoritative
for d in :0 :1; do DISPLAY=$d xdpyinfo >/dev/null 2>&1 && echo "$d live"; done
```

Wayland clients use `WAYLAND_DISPLAY=wayland-0` (kwin); pixelflux is `wayland-1`.

---

## Upstream patches carried here, and when to delete them

The `Dockerfile` carries four patches that are **workarounds for upstream bugs, not
choices**. All are guarded so **the build fails once the bug is gone** — that failure
is the removal signal, not a regression. Do not "fix" a guard failure by loosening the
guard.

(The kwin `--no-lockscreen` removal and the lock-on-startup injection are a *different*
category — deliberate behaviour changes, and they stay.)

| # | Patch | Stage | Delete when |
|---|-------|-------|-------------|
| 1 | selkies monitor-task leak + blocking `nvidia-smi` | `base` | `lsio` picks up upstream `47d2c1346` — **the leak half only**, see below |
| 2 | explicit `runc` install | `full` | the base ships an OCI runtime again |
| 3 | audio sink setup replaced by `selkies-audio-setup` | `base` | upstream's block waits on real readiness **and** checks `pactl` succeeded before stamping its lock |
| 4 | `svc-de` restarts selkies rather than joining a stale capture | `base` | `svc-de/run` checks the socket belongs to a selkies that has not already bound a session |

### 1. selkies leaked monitor tasks

selkies creates per-connection system/GPU/network monitor tasks as `self._X_task_ws` but
cancels them via `locals()["_X_task_ws"]`, which is never true for an instance
attribute. Every browser reconnect therefore leaks an immortal `while True` loop, each
calling `GPUtil.getGPUs()` (a synchronous `nvidia-smi`, ~38 ms) **on the asyncio event
loop**.

Symptoms are a choppy stream, climbing reported latency (that number is a frame-ACK
round trip, so it measures the blocked loop), and a flood of `Error reading Wayland
clipboard` — which is `asyncio.wait_for` timing out against a **blocked loop**, not a
slow compositor.

The leak half is fixed upstream by **`47d2c1346`**. The `to_thread` half is **ours, not
a backport** — `689a201ee` is commonly cited for it but is actually a cursor/latency
commit and does not contain it, so no upstream merge will ever deliver that half. Both
are still carried here because LinuxServer builds selkies from their own `lsio` branch,
which has diverged from `main` — **bumping the LinuxServer pin alone does NOT pick these
up.** Verified on ls286, ls289 and ls290: all three pin `a4aadef97` and ship a
byte-identical `selkies.py`. See [selkies-layer-analysis.md](selkies-layer-analysis.md).

**Applied at the creation site, deliberately.** The sed turns each task into a genuine
per-connection local via chained assignment (`_x = self._x = asyncio.create_task(...)`),
leaving upstream's `locals()` cleanup to work as written. The obvious alternative —
rewriting the cleanup to `getattr(self, "_x_task_ws", None)` — is wrong with **two
browser tabs open**: the instance attribute is overwritten by each new connection, so
tab A disconnecting cancels tab B's monitors, leaking A's loop *and* silently killing
the stats of a tab that is still connected. Verified by AST that all four creation sites
and all four cleanup sites live in the same function (`ws_handler`), so the locals are
in scope for `locals()`.

Consequence for the guards: this patch **keeps** the `locals()` form and asserts it is
still present *after* the sed. The removal signal is therefore either the `create_task`
shape changing or the `locals()` cleanup disappearing.

Upstream's own fix takes the same shape: `47d2c1346` binds a per-connection local,
assigns it to `self._X_task_ws` on the following line, and drops the `locals()` lookups
in favour of iterating those locals directly. So when `lsio` picks it up, the first
guard stops matching `self._gpu_monitor_task_ws = asyncio.create_task(` and the build
fails — which is the signal working as intended.

```bash
# Has the lsio fork caught up?
# NOTE the direction: for `lsio...main`, ahead_by = commits main has that lsio LACKS
# (how far lsio trails), and behind_by = lsio's own commits. The merge signal is
# **ahead_by 0**, NOT behind_by 0 — an earlier version of this recipe had it inverted
# and would never have fired. (As of 2026-08-11: ahead_by 99, behind_by 6.)
curl -s https://api.github.com/repos/selkies-project/selkies/compare/lsio...main \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['status'],'ahead_by',d['ahead_by'],'behind_by',d['behind_by'])"

# Is the fix commit still absent from lsio?  (prints it if lsio still lacks it)
curl -s https://api.github.com/repos/selkies-project/selkies/compare/lsio...main \
  | python3 -c "import sys,json;[print(c['sha'][:9],c['commit']['message'].splitlines()[0]) for c in json.load(sys.stdin)['commits'] if c['sha'].startswith('47d2c1346')]"

# What selkies commit does the base currently pin?
curl -s https://raw.githubusercontent.com/linuxserver/docker-baseimage-selkies/fedora44/Dockerfile \
  | grep -o 'selkies/archive/[0-9a-f]\{40\}'

# Definitive: does the actual base image still have the bug?
docker run --rm --entrypoint sh lscr.io/linuxserver/webtop:fedora-kde-<newtag> -c \
  'F=$(ls /lsiopy/lib/python3.*/site-packages/selkies/selkies.py); \
   echo "bug lookups (0 = fixed): $(grep -c "_task_ws\" in locals()" $F)"'
```

If that count is **0**, upstream's restructure has landed and the leak half is done.
Delete the creation-site sed and the three guards that reference `create_task` and
`locals()` — the first of them will otherwise fail the build.

**Keep the `to_thread` sed and its count guard.** That half is ours; a count of 0 says
nothing about it, and `47d2c1346` does not touch `GPUtil.getGPUs()`. Deleting the whole
`RUN SELKIES_PY=...` block puts the blocking `nvidia-smi` back on the event loop with no
guard left to notice.

### 2. explicit `runc`

See [`svc-docker` above](#svc-docker-restart-loop-stacks-tmpfs-on-tmp) for why a missing
OCI runtime is destructive rather than just noisy.

```bash
docker run --rm --entrypoint sh lscr.io/linuxserver/webtop:fedora-kde-<newtag> -c \
  'command -v runc || command -v crun || echo STILL-MISSING'
```

If a runtime is present, drop `runc` from the install list and the `command -v runc`
assertion. Harmless to keep either way, so this one is low-priority — unlike patch 1,
which fails the build once upstream fixes it.

### 3. audio sink setup

Upstream's `svc-selkies/run` treats pulseaudio's pidfile as readiness and stamps its
once-only lock whether or not `pactl` succeeded, so a lost race means no audio for the
life of the container. Full analysis:
[no audio](#no-audio-the-output-sink-was-never-created).

The whole block is replaced with `/usr/local/bin/selkies-audio-setup`. Three guards hold
it to the exact upstream shape — the `# Default sink setup` comment, the
`until [ -f /defaults/pid ]` loop, and the `touch /dev/shm/audio.lock` — so any rework
upstream fails the build.

Check whether it can go:

```bash
docker run --rm --entrypoint sh lscr.io/linuxserver/webtop:fedora-kde-<newtag> -c \
  'sed -n "/^# Default sink setup$/,/^fi$/p" /etc/s6-overlay/s6-rc.d/svc-selkies/run'
```

Delete the patch only if that block both waits on something that implies the socket is
accepting (not the pidfile) **and** makes the `touch` conditional on the sinks existing.
Fixing only the wait is not enough: the unconditional lock is what makes a failure
permanent.

### 4. `svc-de` rebuilds the pair instead of joining a stale capture

Upstream's `svc-de/run` treats the existence of selkies' compositor socket as permission
to start, which cannot tell a fresh selkies from one that already bound its capture to
an earlier desktop. Full analysis:
[the desktop restarted](#the-desktop-restarted-and-the-stream-never-came-back).

Three guards hold it to the upstream shape — the `SOCKET_PATH` assignment, the
`while [ ! -e "${SOCKET_PATH}" ]` wait, and the absence of any `svc-selkies` reference in
the file — so any rework upstream fails the build.

```bash
docker run --rm --entrypoint sh lscr.io/linuxserver/webtop:fedora-kde-<newtag> -c \
  'grep -c svc-selkies /etc/s6-overlay/s6-rc.d/svc-de/run'
```

If that count is **non-zero**, upstream has taken a view on the coupling: read what it
does before deleting this. Only drop the patch if a desktop restarting alone either
restarts selkies or re-binds the capture — reconnecting to the socket is not enough, and
is exactly the behaviour that fails.

### Bumping the base pin

The `Dockerfile` pins a specific LinuxServer release rather than the rolling
`:fedora-kde` tag, because the rolling tag silently relocates the session scripts the
seds patch. Every sed is grep-guarded against the exact upstream line, so a reworked
base **fails the build** instead of shipping unpatched scripts. Bumping
`WEBTOP_BASE_IMAGE` therefore means re-verifying those guards — and re-probing the X
display number.

---

## Builds inside the desktop copy every layer

Building the image from inside the `full` desktop takes hours and dies with `no space
left on device` while `df` still reports tens of gigabytes free. Each layer costs a full
copy of the parent rootfs rather than a diff.

The cause is the **filesystem under the nested Docker's data root**, and it propagates
through two hops:

1. The desktop container's own rootfs is `overlayfs` on any host using `overlay2` or the
   containerd snapshotter.
2. `/var/lib/docker` is part of that rootfs — the writable layer — unless something is
   mounted over it. `overlay2` cannot use an `overlayfs` directory as its `upperdir`, so
   the nested `dockerd` falls back to `fuse-overlayfs`.
3. A buildx `docker-container` builder keeps its state in a **named volume**, which lives
   under `/var/lib/docker/volumes/` — back on the container's `overlayfs`.
4. BuildKit probes that directory, cannot create an overlay mount there, and selects the
   **native snapshotter**, which has no copy-on-write. Every layer becomes a physical
   copy of the parent snapshot.

Note the second hop is the one that matters. It is not that overlayfs cannot stack on
fuse-overlayfs — it is that BuildKit's state directory sits on the desktop container's
overlay rootfs, and overlay-`upperdir`-on-overlay is what the kernel refuses.

**Diagnose:**

```bash
docker info | grep 'Storage Driver'          # fuse-overlayfs => hop 2 already lost
docker buildx create --name probe --driver docker-container
docker buildx inspect --bootstrap probe
docker logs buildx_buildkit_probe0 2>&1 | grep 'auto snapshotter'
```

`using native` is the failure; `using overlayfs` is the fix. The same answer is on disk
as `runc-native` vs `runc-overlayfs` in the builder's state volume.

**Fix:** mount a directory from a real filesystem over `/var/lib/docker`, so the nested
data root is no longer on the container's overlay rootfs. Both hops clear at once — the
nested `dockerd` gets `overlay2`, and named volumes (so every builder's state) land on
that filesystem and get the overlayfs snapshotter. The commented mount in
`docker-compose.yaml` does this. Setting `data-root` in the nested
`/etc/docker/daemon.json` to a path on an already-mounted volume works equally well and
needs no change to the deployment.

Size it for the work: a full copy of the image plus BuildKit's cache, not just the image.

---

## Build environment gotchas

**A validation command in a `RUN` can leave state in the layer.** `nginx -t` is the one
that bit here: a config *test* creates `/run/nginx.pid` and empty nginx logs, root-owned,
which then ship in the image and break an unprivileged container that has no `emptyDir`
masking `/run`. Anything run as a build-time check needs its side effects deleted in the
same instruction — see [nginx as a non-root
master](unprivileged.md#nginx-as-a-non-root-master).

**Flatpak steps need an entitlement.** `desktop`, `full` and `k8s` install flatpaks,
whose deploy step uses bwrap, so they need
`docker buildx build --allow security.insecure` against a builder created with
`--buildkitd-flags '--allow-insecure-entitlement security.insecure'`. `build.sh` handles
this. `base` and `coder` install no flatpaks and need nothing.

That last part works because **BuildKit validates entitlements per target graph, not per
Dockerfile.** A `RUN --security=insecure` in a stage that the requested `--target` does
not depend on is never solved, so it never demands the entitlement. Verified directly:

```dockerfile
# syntax=docker/dockerfile:1-labs
FROM alpine:3.20 AS base
RUN echo base
FROM base AS desktop
RUN --security=insecure echo needs-entitlement
FROM base AS coder
RUN echo coder
```

`--target coder` builds with no `--allow`; `--target desktop` fails with
`failed to load LLB: security.insecure is not allowed`. This is why keeping the flatpak
steps out of the `coder` lineage is done structurally rather than with a
conditional — a `RUN --security=insecure` whose *body* is skipped by a shell `if` would
still require the entitlement.

**The `# syntax` directive must be a `labs` channel.** `RUN --security=insecure` is a
labs-only feature; the stable frontend fails to parse it with `unknown flag: security`.
Note that `docker buildx build --check` substitutes its own stable frontend regardless of
the directive, so `--check` cannot lint a file containing `RUN --security` — strip those
flags into a scratch copy if you want to lint the rest.

**A mutable tag plus `imagePullPolicy: IfNotPresent` serves stale images.** These images
are large enough that `IfNotPresent` is tempting, but a node that has already cached
`:coder` will keep serving the **old** build under a pod that starts and reports
healthy. Re-pull on every node after a push (`crictl pull`), or use immutable
tags. This is the easiest way to conclude "my fix didn't work" when it did.

**Baked image env can differ from your compose file.** The image sets some env itself
(`SELKIES_ENCODER`, `SELKIES_AUTO_GPU`, `LIBGL_ALWAYS_SOFTWARE`, VAAPI vars); check
`docker inspect` rather than trusting the compose file alone.

---

## Container hangs at `mod-init` on a tunnelled host (MTU)

**Symptom:** the container is stuck at `[mod-init] Running Docker Modification Logic` in
its logs and the desktop never comes up.

This bites when the host routes traffic through a tunnel with a smaller MTU than
Docker's default interface MTU of 1500 — a WireGuard interface at 1420, for example.
Containers emit full-size TLS packets that exceed the tunnel and get **silently
dropped** (DF set, no working PMTUD). TCP connections *open* and then stall mid-handshake.

What makes it fatal rather than slow: `DOCKER_MODS=linuxserver/mods:universal-package-install`
runs `curl … https://ghcr.io/token?scope=…` at init, s6 **blocks the whole Wayland
session** on it, and that curl hangs forever on the TLS handshake.

**Confirm:**

```bash
docker exec <container> sh -c 'ps aux | grep curl'   # the ghcr.io token curl
ping -M do -s 1450 1.1.1.1                           # 100% loss = MTU cliff
ping -M do -s 1392 1.1.1.1                           # succeeds
```

DNS is a red herring — the connection reaches `ESTABLISHED`.

**Fix:** MSS-clamp forwarded TCP down to the tunnel path MTU (this covers TCP only;
large-packet UDP would still need a lower Docker MTU):

```bash
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o <tunnel-if> \
  -j TCPMSS --clamp-mss-to-pmtu
```

Make it persistent however your host manages that interface, then restart the container
so its hung mod-init reconnects.

Separately, after a host **kernel update** the Docker-in-Docker daemon can fail with
`iptables … Module ip_tables not found` — it uses iptables-*legacy* and the NAT modules
weren't autoloaded for the new kernel. `modprobe ip_tables iptable_nat`, and persist it
(e.g. `/etc/modules-load.d/`).
