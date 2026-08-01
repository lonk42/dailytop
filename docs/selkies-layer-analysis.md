# What the LinuxServer webtop layer actually adds on top of selkies

*Research note, 2026-07-24. Measured against `lscr.io/linuxserver/webtop:fedora-kde-37cda392-ls286` (built 2026-07-21) and selkies `main` @ `12f5033`.*

Question this answers: the webtop layer keeps us behind on selkies — how much is it
actually implementing, and is it worth carrying?

Short version: **≈1,800 lines of bash/nginx glue and zero application code.** All
application code is upstream selkies. What LS contributes is distro work — packaging,
supervision, ingress, GPU plumbing, hardening, KDE — plus a **vendor fork of selkies
(`lsio`), which is the reason we lag.**

---

## 1. The layer cake

Sizes from `docker history` on the LS image (4.58 GB total attributed):

| Layer | Size | Contents |
|---|---|---|
| `baseimage-fedora:44` | 209 MB | Fedora rootfs |
| lsio base bits | 14 MB | s6-overlay, docker-mods, `with-contenv`, `/lsiopy` venv |
| `baseimage-selkies:fedora44` packages | **2.06 GB** | Xwayland/Xvfb, mesa, VAAPI, labwc, openbox, nginx, pulseaudio, docker+DinD, `pip install selkies` |
| `baseimage-selkies` overlay | 15 MB | built dashboards (12.6 MB), `root/` scripts (336 kB), `wtype`, `selkies-desktop` |
| `webtop:fedora-kde` | **2.28 GB** | KDE Plasma packages + 49 kB of `root/` |
| **this repo** (`--target full`) | ~11 GB | flatpaks 6.9 GB, dev toolchain 1.5 GB, ~460 lines of Dockerfile |

Upstream selkies ships **no desktop container** — its own `Dockerfile` only builds a
pypi wheel from `src/`. There is no "just run upstream's image" option; the container
*is* the LS contribution.

## 2. How much code is LS's own

| Source | Lines | Notes |
|---|---|---|
| `docker-baseimage-selkies/root/` | 1,313 | 196 of them are moby's stock `dockerd-entrypoint.sh`, copied verbatim |
| `docker-webtop/root/` (fedora-kde) | 266 | `startwm_wayland.sh` (115), `systemctl` shim (68), `wrapped-chromium` (22) |
| Both Dockerfiles | 405 | overwhelmingly `dnf install` lists |

For scale, upstream selkies is 23,345 lines of core Python (`src/selkies/*.py`) plus
36,536 vendored (aiortc, python-xlib, ICE) and ~19k lines of frontend JS. The LS
frontend is upstream's `selkies-web-core` + `selkies-dashboard*`, built unmodified
from the pinned tarball.

**What the glue does**, ranked by substance:

| File | Lines | Job |
|---|---|---|
| `init-selkies-config/run` | 300 | The real product layer: `HARDEN_DESKTOP`/`HARDEN_OPENBOX` (chmod 0000 on sudo/terminals/xdg-open, sed dangerous keybinds out of rc.xml, lock it root-owned), openbox↔labwc path switching, proot-apps seeding, gamepad `mknod` + `LD_PRELOAD` joystick interposer, `DRI_NODE`/`DRINODE` autodetect |
| `init-video/run` | 123 | `/dev/dri` group fixups; hand-writes NVIDIA Vulkan/EGL/OpenCL ICDs and copies `nvidia-drm_gbm.so` into the linker path when nvidia-container-toolkit didn't. **Load-bearing for us.** |
| `svc-selkies/run` | 120 | ~100 lines are `DEV_MODE` nodemon scaffolding. The actual launch is 4 lines: `exec s6-setuidgid abc selkies --addr=localhost --mode=websockets` |
| `default.conf` + `init-nginx/run` | 197 | TLS termination + self-signed cert, htpasswd from `PASSWORD`, `SUBFOLDER`, WS proxy → `:8082`, fancyindex file browser, PWA manifest, dashboard theme selection via `DASHBOARD` |
| `svc-xorg`, `svc-de`, `svc-watchdog`, `svc-de/finish` | 190 | Xvfb with the right extensions (X11 mode only), DE supervision, app-restart watchdog, pstree-based teardown |
| `webtop/root/defaults/startwm_wayland.sh` | 115 | The KDE session: kwinrc/kscreenlockerrc seeding, a kwin window rule so `wl-copy`/`wl-paste` work, `kbuildsycoca6`, then `dbus-run-session` → `kwin_wayland --no-lockscreen --xwayland` + `plasmashell`. **This is the file our lock-screen seds patch.** |

Config surface is upstream's: 94 distinct `SELKIES_*` names on the pinned commit vs 93
on `main`. LS sets ~47 env vars total, most of which are their own (`HARDEN_*`,
`CUSTOM_*`, `PIXELFLUX_WAYLAND`, `NO_GAMEPAD`, `SUBFOLDER`).

## 3. Where the lag comes from

Not slow bumping — LS bumps the pin every 1–3 weeks. The problem is **they never track
`main`.** The pin always points at selkies' `lsio` branch, a vendor fork:

```
merge-base 0d134b6 (2026-05-17)
  ├── main → +42 commits (ehfd: WebRTC/parity/perf)  → 12f5033, 2026-07-22
  └── lsio → +4  commits (thelamer: pixelflux v2, auto_gpu) → a4aadef, 2026-07-16  ← our image
```

All four `lsio` commits are pixelflux/pcmflux v2 support and GPU autoselect. So **LS is
*ahead* of upstream on exactly the capture path we run, and ~2 months behind on
everything else.** Historically the flow is lsio→main (PR #252 merged their work *into*
main on 2026-06-11), not main→lsio — so a pin bump alone never picks up upstream fixes.
Verified on the ls276 → ls286 bump.

Size of the gap (`git diff lsio main`):

| Area | Delta |
|---|---|
| core `src/selkies/*.py` | 12,661 → 23,345 lines (+15,694 / −5,011, 14 files) |
| vendored `webrtc/`, `Xlib/`, `ice/` | +25,337 lines (aiortc/python-xlib/ICE now vendored) |
| `addons/` frontend | +13,343 / −4,165 (106 files) |

Modules our container simply does not have: `stream_server.py` (1,421 lines),
`gpu_stats.py`, `audio_config.py`, `ice/`, `Xlib/`. Notable missing work: the aiohttp
backend migration (#236), the Rust/PyO3 core (`ed3249b`), Wayland host-capture rework
(`a6f79e3`), clipboard/IME fixes (`3a75e7e`) — and both commits we hand-patch in
the `base` stage: `47d2c13` (leaked monitor tasks) and `689a201` (`to_thread` for the
blocking `nvidia-smi`). Confirmed present in the 42, absent from our pin.

### Symptom of the drift, in the shipped image

`baseimage-selkies/Dockerfile` builds
`DASHBOARDS="selkies-dashboard selkies-dashboard-zinc selkies-dashboard-wish"`, but
zinc was **deleted upstream on 2026-03-27** — five days *before* LS added it to that
list (`08ba919`, 2026-04-01). The `cd /src/addons/selkies-dashboard-zinc` fails inside
the `for` loop, the loop continues, the `RUN` exits 0, and the image ships two
dashboards. Verified in the running container: `/usr/share/selkies/` contains only
`selkies-dashboard` and `selkies-dashboard-wish`. Harmless, but it shows the build
tolerates pin drift silently.

## 4. Takeaway

Carrying the LS layer costs us the `lsio` pin — a fork whose only additions are
pixelflux, in exchange for two months of upstream fixes. It buys the 2 GB package set,
the s6 supervision tree, nginx ingress + TLS, and the NVIDIA ICD/GBM fixups in
`init-video`.

Going direct-to-upstream is feasible (≈1,800 lines of glue to re-implement, and we
already override the interesting parts), **but** `main` does not yet have the pixelflux v2 path LS ships, so the whole `PIXELFLUX_WAYLAND` capture mode
and `SELKIES_ENCODER=x264enc`/NVENC behaviour would need re-testing from scratch. Not
worth it today.

Cheaper path — what this repo does: keep the LS layer, keep patching selkies in place
(the grep-guarded `RUN SELKIES_PY=...` block in the `base` stage of the `Dockerfile`),
and watch for reconvergence.

## 5. Re-running this analysis

```bash
# Has LS's fork caught up with upstream?  behind_by 0 => yes, drop our patches.
curl -s https://api.github.com/repos/selkies-project/selkies/compare/lsio...main \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['status'],'behind_by',d['behind_by'])"

# What does the LS base pin right now?
curl -s https://raw.githubusercontent.com/linuxserver/docker-baseimage-selkies/fedora44/Dockerfile \
  | grep -o 'selkies/archive/[0-9a-f]\{40\}'

# Full picture: clone all three and diff
git clone https://github.com/linuxserver/docker-baseimage-selkies.git   # branch: fedora44
git clone https://github.com/linuxserver/docker-webtop.git              # branch: fedora-kde
git clone https://github.com/selkies-project/selkies.git
cd selkies
git rev-list --left-right --count origin/main...origin/lsio   # left = main-only, right = lsio-only
git diff --stat origin/lsio origin/main -- src/selkies/*.py

# Physical layer split
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' \
  lscr.io/linuxserver/webtop:fedora-kde-<tag>
```
