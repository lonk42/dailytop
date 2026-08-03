# Extra CA certificates

Certificates are mounted at runtime.

Drop the root CAs you need the container to trust into this directory as `*.crt` or
`*.pem` (PEM encoded), then mount the directory at **`/certs`**. On every container
start, `/custom-cont-init.d/00-ca-certs.sh` installs them into
`/etc/pki/ca-trust/source/anchors/` and runs `update-ca-trust extract`, so `curl`,
`openssl`, Python and friends inside the container pick them up.

```yaml
# docker compose
volumes:
  - ./certs:/certs:ro
```

Certificates are **gitignored** — this directory ships with only a README, and empty is
a supported state (the hook logs `no CA certificates in /certs` and carries on).

Change the location with the **`CA_CERT_DIR`** environment variable (default `/certs`).

## Why mounting rather than baking

An internal CA is environment-specific. Baking one in:

- makes the image unshareable — a public image would publish the CA of whoever built
  it, which is an unnecessary disclosure of internal infrastructure;
- turns every certificate rotation into an image rebuild and redeploy;
- means the same image cannot be promoted between environments that trust different CAs.

Mounting keeps one image usable everywhere, and the certificates stay in deployment
config where they can be rotated, sealed, or managed as a Kubernetes Secret.

## Behaviour

- **Subdirectories are searched.** The whole tree under the mount is scanned, so a
  projected `ConfigMap` or `Secret` that lands its keys in nested paths still works.
  Anchor names carry the relative path, so `a/ca.crt` and `b/ca.crt` are both installed
  rather than one overwriting the other. Names beginning with a dot are skipped, which
  is what stops a Kubernetes volume's `..data` symlink trusting everything twice.
- **Trust is rebuilt from the mount on every start, not accumulated.** Anchors installed
  by a previous start are removed first, so deleting a certificate from the mount and
  restarting revokes it. This matters because `/etc` is image state and survives
  `docker restart`.
- **The hook always exits 0.** A failing `cont-init` script takes the whole container
  down, and a missing CA should degrade to "TLS to the internal host fails" with a log
  line rather than "no desktop". Check `docker logs` for `[custom-init]`.
- **`update-ca-trust extract` is mandatory** and the hook always runs it. Copying a
  certificate into the anchors directory by hand does not update the bundle that
  `curl` and `openssl` read.
- **Ordering is guaranteed.** `/custom-cont-init.d` runs after `init-adduser`/
  `init-config` and before any `svc-*`, and this hook is numbered `00-`, so everything
  that touches the network is downstream of it.

## When you need this

- **A Coder deployment behind an internal CA.** The `coder` target needs this: the
  agent's first act is curling the Coder access URL to fetch its own binary, and
  without the CA that fails `x509` and the workspace never reports healthy.
- **A private registry with an internal CA.** For the `full` target, also set the
  **`PRIVATE_REGISTRY`** environment variable to the registry `host[:port]`. The hook
  then copies the certificates into `/etc/docker/certs.d/<host>/` as well, because the
  *inner* Docker-in-Docker daemon reads that directory rather than the system trust
  store.
- **A TLS-intercepting corporate proxy.**

## Firefox and other NSS consumers

Firefox does not use the system trust store; it has its own NSS database. Certificates
mounted here are trusted by `curl`, `openssl` and the rest of the system, but Firefox
still shows a warning interstitial for a host signed by your internal CA. Fixing that
needs `security.enterprise_roots.enabled` set via a Firefox policy, which this image
does not configure.

