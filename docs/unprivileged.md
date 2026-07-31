# Running unprivileged (restricted pod security policies)

`--target coder --build-arg UNPRIVILEGED=true` builds the desktop to run as a non-root
uid with **no capabilities at all**. This is what a restricted pod security policy
requires, and it is off by default because it makes `PUID`/`PGID` inert and relaxes group
permissions on paths the init scripts write.

CI publishes this as its own variant, so you do not have to build it yourself:
`dailytop:coder-unpriv` (moving) and `dailytop:coder-unpriv-ls286-<version>` (immutable —
use this one). See [releases](../README.md#releases).

FIPS is a separate and much harder problem — see [FIPS](#fips) at the bottom.

## What the deployment must supply

Three things, and all three are load-bearing:

```yaml
securityContext:                 # pod
  runAsNonRoot: true
  # Any uid works. Where the cluster assigns one itself, leave runAsUser unset; gid 0 is
  # the usual convention and is what makes the image's group-writable paths reachable.
  runAsGroup: 0
  fsGroup: 1000                  # or whatever the cluster allocates
  seccompProfile:
    type: RuntimeDefault
containers:
  - name: dailytop
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]            # nothing is added -- see below
    env:
      # Skips init-adduser's usermod/groupmod and init-device-perms' chmod/groupadd,
      # none of which can work unprivileged. Upstream LinuxServer variable.
      - name: LSIO_NON_ROOT_USER
        value: "true"
      # REQUIRED. See pulseaudio below -- without it the whole desktop hangs.
      - name: PULSE_RUNTIME_PATH
        value: "/run/pulse"
      # Gamepad mknod needs CAP_MKNOD; this skips the attempt.
      - name: NO_GAMEPAD
        value: "1"
    volumeMounts:
      # REQUIRED. s6-overlay's preinit refuses a root-owned /run it cannot chown, and
      # that is a fatal exit before any service starts.
      - name: run
        mountPath: /run
volumes:
  - name: run
    emptyDir: {}
```

`/run` is the one that bites first, and its failure is unambiguous:

```
preinit: fatal: /run belongs to uid 0 instead of 1000, has insecure and/or unworkable
permissions, and we're lacking the privileges to fix it.
```

An `emptyDir` on `/run` arrives mode 2777, which s6 accepts because the image bakes
`S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES=1` — upstream's own escape hatch
for exactly this. Chowning `/run` at build time would also work but only for one fixed
uid, so it is deliberately not done.

## No capabilities are needed

This is worth stating plainly, because it is the opposite of the obvious guess.

`s6-applyuidgid` calls `setgroups()` unconditionally, which needs `CAP_SETGID`. Every
`svc-*` in the base drops privileges with `exec s6-setuidgid abc …`, so the natural fix
looks like granting `SETUID`/`SETGID` through a policy exception.

**That does not work.** Kubernetes and CRI-O put `capabilities.add` into the *bounding*
set only and never set *ambient* capabilities, and runc clears the permitted and
effective sets when it drops to a non-root uid. Measured in a pod with
`add: ["SETUID","SETGID"]`:

```
CapPrm: 0000000000000000
CapEff: 0000000000000000
CapBnd: 00000000000000c0     # cap_setgid,cap_setuid -- bounding set only
$ s6-setuidgid abc id
s6-applyuidgid: fatal: unable to set supplementary group list: Operation not permitted
```

So the capability grant buys nothing, and `UNPRIVILEGED=true` instead replaces
`/command/s6-setuidgid` with a shim that execs straight through when it is already
running as the target user. The upside is significant: with the shim, **nothing needs a
capability**, so the pod satisfies the strictest stock profile with no policy exception.

Note that `PodSecurity: restricted` rejects `capabilities.add` of `SETUID`/`SETGID`
outright, so an attempt to grant them fails admission on a PSA-restricted namespace
anyway.

## What the image changes

`UNPRIVILEGED=true` does four things, all reversible by leaving it `false`:

| Change | Why |
|---|---|
| `chmod 0755 /usr/sbin/lsiown /docker-mods` | Ship 0744, so non-root cannot execute them; `init-adduser` exits 126 and halts every dependent service |
| `chmod 0755` on any `s6-rc.d/*/run` that is not world-executable | Same failure one layer down — `init-mods-package-install` ships 0744 and halts the chain. Done with a `find` so a new offender upstream is covered; the `up` files stay 0644 because s6-rc interprets rather than execs them |
| `chgrp -R 0` + `chmod -R g=u` on `UNPRIVILEGED_PATHS` | The init scripts write into `/etc/nginx`, `/usr/share/selkies` and friends at runtime |
| `s6-setuidgid` shim | See above |
| `05-unpriv-passwd.sh` hook | An arbitrary uid has no `passwd` entry, and `getpwuid()` failures surface obscurely in plasmashell, dbus and ssh |
| `svc-selkies` honours `PULSE_RUNTIME_PATH` | Applied unconditionally and grep-guarded; see [pulseaudio](#pulseaudio) |
| Chromium conf + a `code` wrapper | Applied unconditionally, and runtime-adaptive so a privileged container keeps its sandbox; see [Chromium and VS Code](#chromium-and-vs-code) |
| nginx self-signs into `/run/ssl`, not `/config/ssl` | Applied unconditionally. A key left in the workspace volume by another uid is unreadable to this one, and nginx exits rather than start without it; see [image-design.md](image-design.md#tls-material-lives-in-run) |
| `user nginx;` dropped and the pid file moved to `/var/lib/nginx` | Neither works or matters without a root master; see [nginx as a non-root master](#nginx-as-a-non-root-master) |
| Fedora's stock `server { listen 80; }` removed from `nginx.conf` | Applied unconditionally. Nothing routes to it, and binding it needs `CAP_NET_BIND_SERVICE` on any runtime that leaves `net.ipv4.ip_unprivileged_port_start` at 1024 — CRI-O does; see [image-design.md](image-design.md#the-stock-80-server-block) |

`UNPRIVILEGED_PATHS` is a build arg. **Extending it is the fix for any new "Permission
denied" from an init script** — that is the intended maintenance path, not patching the
scripts.

Note that `abc` is uid **911** in the base and `LSIO_NON_ROOT_USER` skips the `usermod`
that would move it to `PUID`. Nothing should depend on the running uid matching `abc`;
the gid-0 group permissions are what grant access.

### The trade-off

`chmod g=u` on `/etc/passwd` makes it writable by anything running as gid 0, which is
what lets the passwd hook work for an unknown uid. This is the conventional pattern for
arbitrary-uid images and it is a real relaxation: in exchange for running with no capabilities at
all, the container gives up the read-only-ness of a handful of `/etc` paths. For a
single-user desktop behind authentication that is a good trade, but it is a trade.

## pulseaudio

This one is worth its own section because the symptom points nowhere near the cause: the
pod runs, nginx serves HTTP 200 on `:3000`, and **no desktop ever appears**.

The base bakes `PULSE_RUNTIME_PATH=/defaults`. pulseaudio calls
`pa_make_secure_dir()` on it, which does `mkdir` then `chown` — and the `chown` needs
`CAP_CHOWN`, so unprivileged it dies with:

```
E: [pulseaudio] core-util.c: Failed to create secure directory (/defaults): Operation not permitted
```

Group-writable permissions do **not** help: `pa_make_secure_dir` requires the directory to
be *owned* by the running uid, which no build-time `chown` can arrange for an arbitrary
uid. The fix is to point it at a directory the container creates itself — anything under
the `/run` emptyDir is then owned by whoever created it. Hence
`PULSE_RUNTIME_PATH=/run/pulse`.

That alone hangs the desktop a second way, because `svc-selkies` busy-waits on
pulseaudio's pidfile at a **hardcoded** `/defaults/pid`:

```bash
until [ -f /defaults/pid ]; do sleep .5; done
```

With pulseaudio's runtime dir moved, that loop never exits, `svc-selkies` never reaches
its `exec`, no Wayland socket is created, and `svc-de` waits forever — all while every
service reports `up`. The image therefore carries a grep-guarded sed making the loop read
`${PULSE_RUNTIME_PATH:-/defaults}/pid`, which is a strict generalisation: unset, the
behaviour is byte-identical to upstream.

Diagnosing this from the outside is unpleasant, so the tell is: `svc-selkies` shows as
`up` but its process is still `bash ./run svc-selkies` with no children, and
`svc-pulseaudio` is `down (exitcode 1)` and restarting.

## Known limitations

Three things do not work unprivileged, and all three are visible as noise in the boot log
rather than as failures:

- **`sudo` is inert.** It is setuid, and `allowPrivilegeEscalation: false` sets
  `NoNewPrivs`, so it cannot elevate at all. `init-selkies-config`'s `sed -i /etc/sudoers`
  also fails (`sed: couldn't open temporary file /etc/sedXXXXXX`), which leaves `NOPASSWD`
  in place — harmless precisely because `sudo` cannot work either way.
  `/etc/sudoers` is deliberately **not** in `UNPRIVILEGED_PATHS`; a group-writable
  sudoers is a worse idea than a cosmetic error.
- **Gamepad emulation is unavailable.** `init-selkies-config` does
  `mkdir -pm1777 /dev/input` and `mknod .../js0`, which need `CAP_MKNOD`. Set
  `NO_GAMEPAD=1` in the deployment to skip the attempt and quieten the log.
- **`lsiown`'s chown warnings are unavoidable and expected.** Every
  `**** Permissions could not be set … we will not provide support for it ****` line is
  upstream telling you it could not chown a path it does not need to own. The build-time
  group permissions are what make the paths usable.

## nginx as a non-root master

Two things in Fedora's `nginx.conf` assume a root master, and `UNPRIVILEGED=true` adjusts
both:

- **`user nginx;` is dropped.** Setting the worker user needs `CAP_SETUID`, which this
  container never has, so nginx logs `the "user" directive makes sense only if the master
  process runs with super-user privileges, ignored` on every start. It is genuinely
  ignored — the workers run as the container's uid either way — so the directive is pure
  log noise and goes.
- **The pid file moves to `/var/lib/nginx/nginx.pid`.** `/run` is the one path in this
  image whose permissions the *deployment* owns rather than the image: it has to be an
  `emptyDir`, and how it arrives (mode, ownership, whether it masks the image's own
  `/run`) is not something the image can assert. `/var/lib/nginx` is nginx's own state
  directory, is in `UNPRIVILEGED_PATHS`, and can never be replaced by a mount.

A related trap for anyone editing the Dockerfile: **`nginx -t` is not read-only.** A
config test creates `/run/nginx.pid` and empty `access.log`/`error.log`, all root-owned,
and in a `RUN` step those land in the image layer. A root-owned `/run/nginx.pid` baked
into an image is invisible wherever `/run` is masked by an `emptyDir` and fatal wherever
it is not — nginx cannot open an existing root-owned file for writing, exits, and s6
restarts it forever. Anything that runs `nginx -t` at build time must delete what it
leaves behind.

## Chromium and VS Code

Neither can sandbox here, and it is worth being precise about why, because two separate
mechanisms are closed at once:

- `chrome-sandbox` ships **not setuid** (`-rwxr-xr-x`), and `allowPrivilegeEscalation:
  false` sets `NoNewPrivs`, so the SUID sandbox could not work even if it were.
- The namespace sandbox is unavailable too: `unshare -Ur` returns `Operation not
  permitted` despite `unprivileged_userns_clone=1`, because the `RuntimeDefault` seccomp
  profile blocks `unshare`. That is seccomp, not the capability drop.

Bare Chromium therefore aborts outright:

```
FATAL: The SUID sandbox helper binary was found, but is not configured correctly.
Rather than run without sandboxing I'm aborting now.
```

The base already handles its own menu launcher — `wrapped-chromium` tests
`/proc/1/status` for `Seccomp: 0` and adds `--no-sandbox --test-type` when a filter is
active. The image extends the same runtime test to the two paths it misses:
`/etc/chromium/chromium.conf` (so a bare `chromium-browser` behaves like the launcher) and
a `/usr/local/bin/code` wrapper that the `code` desktop entries are repointed at.

Because the test is made at runtime, **a privileged container keeps its sandbox** — the
flag is not baked in. Note `Seccomp: 2` is what a stock `docker run` reports, so the
unsandboxed path is the normal one outside a `--privileged` container.

Firefox is unaffected: its sandbox uses neither setuid nor `unshare` in a way the default
profile blocks.

Dropping the sandbox is a real reduction in defence-in-depth for browser content. It buys
a desktop that runs with no capabilities at all, which is the trade this whole document
describes.

## Emulating this on plain Kubernetes

Where the cluster has no policy engine of its own, Pod Security Admission reproduces the
constraints closely enough to develop against. Label the namespace:

```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/enforce-version: latest
```

`restricted` enforces `runAsNonRoot`, `allowPrivilegeEscalation: false`,
`drop: ["ALL"]` and `seccompProfile: RuntimeDefault` — the same set that matters here.

PSA also says nothing about `net.ipv4.ip_unprivileged_port_start`, which the *runtime*
sets: Docker and most containerd/kubelet setups default it to 0, so an unprivileged
process binds low ports anyway and any dependence on that goes unnoticed. CRI-O leaves it
at 1024. To catch that class locally, pass `--sysctl net.ipv4.ip_unprivileged_port_start=1024`
to `docker run`; on Kubernetes, set the same sysctl in the pod's
`securityContext.sysctls` — it is in the safe set, so no allowlisting is needed.

The one thing PSA does **not** emulate is SELinux. A cluster that assigns an MCS label
per namespace and confines the container with `container_t` will behave differently; a Debian or k3s host running
AppArmor will not reproduce any denial that comes from it. Volume relabelling and
`/dev/shm` access are the likeliest places for that to show up, so treat a clean k3s run
as necessary but not sufficient.

## FIPS

Not addressed, and not addressable on this base. The image is Fedora, whose OpenSSL
build carries no CMVP certificate, so on a FIPS-enabled node it will enter
FIPS-*restricted* mode without being FIPS-*validated* — the restrictions without the
compliance. Chromium, Electron and Firefox bundle their own crypto and sit outside system
FIPS entirely.

Real FIPS compliance means re-basing on UBI and linking the platform's validated modules,
which means leaving LinuxServer's webtop base and the whole selkies layer behind. That is
a different project, not a build arg.
