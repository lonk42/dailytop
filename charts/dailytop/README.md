# dailytop Helm chart

Deploys a [dailytop](https://github.com/lonk42/dailytop) desktop — one Deployment, one
Service, a `/config` PVC, and an optional Ingress.

```bash
helm install desktop oci://ghcr.io/lonk42/charts/dailytop --version <version>
```

The defaults are software-rendered and schedule anywhere. Access is **HTTPS on port
3001** when you reach the pod directly: the selkies client refuses to start on a
non-secure origin (`FATAL: Not in a secure context. WebCodecs require HTTPS.`). Behind a
TLS-terminating Ingress, route to the `http` port — the browser's origin is what counts.

```bash
helm install desktop oci://ghcr.io/lonk42/charts/dailytop --version <version> \
  --set ingress.enabled=true \
  --set ingress.className=traefik \
  --set ingress.host=desktop.example.com \
  --set ingress.tls.enabled=true
```

## Image selection

`image.tag` is empty by default and composed from `image.variant` and the chart's
appVersion: variant `k8s` at appVersion `ls286-1.1.0` gives
`ghcr.io/lonk42/dailytop:k8s-ls286-1.1.0`. A chart published from tag `1.1.0` therefore
defaults to the images that same tag built. Set `image.tag` to pin something else.

| `image.variant` | For |
|---|---|
| `k8s` | a GPU node — VAAPI/NVDEC, the glvnd EGL-on-X11 configs, flatpaks |
| `coder` | no GPU, no flatpaks, software rendering |
| `coder-unpriv` | the same, running as a non-root uid — set `unprivileged.enabled` |

## GPU

```yaml
image:
  variant: k8s
gpu:
  enabled: true
flatpak:
  enabled: true
```

That sets `runtimeClassName: nvidia`, requests one `nvidia.com/gpu`, adds the NVIDIA env
(including the hardware encoder first in `SELKIES_ENCODER`), and mounts the two
driver-locked `libnvidia-egl-*` platform libraries from the node.

`gpu.eglPlatformLibs.hostPath` defaults to `/usr/lib/x86_64-linux-gnu`, the Debian and
Ubuntu layout. On a Fedora or RHEL node set it to `/usr/lib64`. The mount is `type: File`,
so a wrong path fails the pod rather than silently degrading it.

`flatpak.enabled` gives the container an unmasked `/proc` and an unconfined seccomp
profile, which bwrap needs. `procMount: Unmasked` requires the ProcMountType feature gate;
where it is off, use `containerSecurityContext.privileged: true` instead — a much broader
grant, and it leaks the host's `/dev/dri`.

Confirm the driver was injected rather than assuming it:

```bash
kubectl exec deploy/<release>-dailytop -- nvidia-smi
kubectl logs deploy/<release>-dailytop | grep -E 'Driver:|Mode:'
```

## Unprivileged

```yaml
image:
  variant: coder-unpriv
unprivileged:
  enabled: true
  runAsUser: 9999
```

Runs as a non-root uid with no capabilities under `restricted` PodSecurity, and switches
on the `/run` emptyDir that s6-overlay's preinit needs. Set `runAsUser: null` to let the
platform assign a uid. The image must have been built with `--build-arg
UNPRIVILEGED=true` — the plain image dies at preinit under this security context. See
[docs/unprivileged.md](../../docs/unprivileged.md).

## Probes

The probes check the session, not the port. nginx answers on 3000 whether or not the
desktop behind it is alive, so a port check reports a healthy pod through a session that
is crash-looping and streaming nothing — a rollout then completes and the endpoint takes
traffic with a black screen behind it.

`probes.sessionCommand` requires both processes a stream needs: selkies serves it, kwin
produces the frames — and then checks that they are still the pair that was bound
together.

```yaml
probes:
  sessionCommand:
    - /bin/sh
    - -c
    - |
      pgrep -x selkies >/dev/null || exit 1
      pgrep -x kwin_wayland >/dev/null || exit 1
      s=$(s6-svstat -o updownfor /run/service/svc-selkies 2>/dev/null) || exit 0
      d=$(s6-svstat -o updownfor /run/service/svc-de 2>/dev/null) || exit 0
      case "$s:$d" in *[!0-9:]*|*::*|:*|*:) exit 0 ;; esac
      [ "$s" -le "$((d + 60))" ]
```

Matched on process **name**. `pgrep -f 'bin/selkies'` matches the probe's own `sh -c`
command line and succeeds no matter what is running — verified, not theoretical.

Both processes being alive is not sufficient. selkies binds its screen capture to the
desktop session once, so a desktop that restarted on its own reconnects to the socket
but is never captured: the stream is dead while both processes report up and s6 reports
everything healthy. selkies is started first and never by much, so a selkies far older
than the desktop means they are no longer that pair — the age comparison is what catches
it. The image carries its own guard for this
([troubleshooting](../../docs/troubleshooting.md#the-desktop-restarted-and-the-stream-never-came-back));
the probe is what recovers a pod running an older image. Where `s6-svstat` cannot
answer, the check is skipped and the process tests stand alone.

Liveness runs the same check with slack thresholds (3.5 minutes). s6 restarts a dead
service by itself; this only fires once that has stopped working, and it turns a silent
hang into a visible restart.

Set `probes.method: tcp` for the old port check, globally or on one probe:

```yaml
probes:
  liveness:
    method: tcp
```

## Account passwords

`auth.existingSecret` puts `USER_PASSWORD` in the environment, but only the `full` image
acts on it — the hook that applies it is built in that stage. The `k8s` image inherits
the KDE lock screen from `desktop` without inheriting the hook, so a `k8s` desktop with
`LOCK_ON_STARTUP=true` and nothing else locks itself with no way in. Either keep
`LOCK_ON_STARTUP=false`, or supply the script yourself:

```yaml
initScripts:
  01-set-passwords.sh: |
    #!/bin/bash
    [ -n "${USER_PASSWORD}" ] || exit 0
    echo "abc:${USER_PASSWORD}"  | chpasswd
    echo "root:${USER_PASSWORD}" | chpasswd
```

## Init scripts

`initScripts` is a map of filename to script content, dropped into
`/custom-cont-init.d` and run before any service starts.

```yaml
initScripts:
  50-example.sh: |
    #!/bin/bash
    echo "[custom-init] hello"
```

Each file is mounted individually with `subPath`. Mounting the directory instead would
replace it and hide every hook baked into the image.

## Values

| Key | Default | Description |
|---|---|---|
| `image.repository` | `ghcr.io/lonk42/dailytop` | |
| `image.variant` | `k8s` | Prefixed to appVersion when `image.tag` is empty |
| `image.tag` | `""` | Overrides the composed tag |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | |
| `replicaCount` | `1` | A second replica cannot schedule against an RWO claim |
| `env` | see values.yaml | Wins over every default the feature flags add |
| `extraEnv` | `[]` | Raw entries, for `valueFrom` |
| `envFrom` | `[]` | |
| `auth.existingSecret` | `""` | Secret holding the in-desktop account password — applied by the `full` image only, see below |
| `auth.secretKey` | `USER_PASSWORD` | |
| `caCerts.enabled` | `false` | Trust extra root CAs from a Secret |
| `caCerts.existingSecret` | `""` | Required when enabled |
| `caCerts.mountPath` | `/certs` | |
| `initScripts` | `{}` | Filename → script content |
| `gpu.enabled` | `false` | |
| `gpu.runtimeClassName` | `nvidia` | |
| `gpu.resourceName` | `nvidia.com/gpu` | |
| `gpu.count` | `1` | |
| `gpu.driverCapabilities` | `all` | |
| `gpu.driNode` | `/dev/dri/renderD128` | |
| `gpu.eglPlatformLibs.enabled` | `true` | |
| `gpu.eglPlatformLibs.hostPath` | `/usr/lib/x86_64-linux-gnu` | Node path; `/usr/lib64` on Fedora/RHEL |
| `gpu.eglPlatformLibs.containerPath` | `/usr/lib64` | |
| `unprivileged.enabled` | `false` | Needs an image built with `UNPRIVILEGED=true` |
| `unprivileged.runAsUser` | `9999` | `null` lets the platform assign one |
| `unprivileged.username` | `""` | Name for that uid's `/etc/passwd` entry; empty keeps `abc-unpriv` |
| `flatpak.enabled` | `false` | Unmasked `/proc` and unconfined seccomp for bwrap |
| `podSecurityContext` | `{}` | Merged over the preset, and wins |
| `containerSecurityContext` | `{}` | Likewise |
| `service.type` | `ClusterIP` | |
| `service.ports.http` | `3000` | |
| `service.ports.https` | `3001` | |
| `service.annotations` | `{}` | |
| `ingress.enabled` | `false` | |
| `ingress.className` | `""` | |
| `ingress.annotations` | `{}` | Where a Traefik middleware or an issuer goes |
| `ingress.host` | `""` | Required when enabled |
| `ingress.path` / `ingress.pathType` | `/` / `Prefix` | |
| `ingress.port` | `http` | Service port to route to |
| `ingress.tls.enabled` | `false` | |
| `ingress.tls.secretName` | `""` | Defaults to `<fullname>-tls` |
| `persistence.config.enabled` | `true` | Disabled gives an emptyDir; the desktop resets on restart |
| `persistence.config.existingClaim` | `""` | |
| `persistence.config.storageClass` | `""` | |
| `persistence.config.accessMode` | `ReadWriteOnce` | |
| `persistence.config.size` | `50Gi` | |
| `persistence.config.retain` | `false` | Keeps the PVC on uninstall |
| `persistence.shm.enabled` | `true` | Chromium and Electron crash on the 64 MiB default |
| `persistence.shm.sizeLimit` | `2Gi` | |
| `extraVolumes` / `extraVolumeMounts` | `[]` | |
| `resources` | 500m/4Gi requested, 16Gi limit | No CPU limit — see values.yaml |
| `probes.method` | `session` | `session` execs `sessionCommand`; `tcp` connects to the http port |
| `probes.sessionCommand` | `pgrep` for selkies + kwin | See below |
| `probes.startup.*` | enabled, 5 min budget | Per-probe `method:` overrides the global |
| `probes.readiness.*` | enabled | |
| `probes.liveness.*` | enabled, slack thresholds | A restart destroys the session |
| `serviceAccount.create` / `.name` / `.annotations` | `true` / `""` / `{}` | |
| `podAnnotations` / `podLabels` | `{}` | |
| `nodeSelector` / `tolerations` / `affinity` | `{}` / `[]` / `{}` | |
| `priorityClassName` | `""` | |

## What the chart does not do

No Ingress-controller-specific objects: no Traefik `Middleware` for basic auth, no
`IngressRoute` for an HTTP→HTTPS redirect, no Secret holding a password. Reference them
through `ingress.annotations` and `auth.existingSecret` and keep them next to the rest of
your cluster configuration.
