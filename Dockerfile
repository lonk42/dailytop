# syntax=docker/dockerfile:1-labs
#
# dailytop -- a browser-accessible Linux desktop on LinuxServer's webtop, in five
# variants from one file. `--target base|desktop|full|k8s|coder`.
#
#   base ──> desktop ──> full          Why each stage does what it does:
#        │           └──> k8s          docs/image-design.md
#        └──> coder                    Build args: docs/building.md
#
# The `labs` syntax channel is required: `RUN --security=insecure` (the flatpak steps)
# is labs-only and the stable frontend rejects it.
#
# Every sed here is grep-guarded. A guard failure means the base changed -- revalidate
# the patch or delete it; do not loosen the guard. See docs/image-design.md#conventions.

# Pinned, not rolling: the rolling tag relocates the session scripts these seds patch.
# docs/image-design.md#the-base-pin
ARG WEBTOP_BASE_IMAGE=lscr.io/linuxserver/webtop:fedora-kde-37cda392-ls286


# =============================================================================
#  base -- upstream fixes, core packages, optional VS Code
# =============================================================================
FROM ${WEBTOP_BASE_IMAGE} AS base

# Packages from Fedora's own repos. Space-separated; empty skips the step.
ARG BASE_PACKAGES="vim git tmux htop rsync net-tools firefox chromium sqlite sshfs \
telnet spectacle unzip npm awscli2 dos2unix dejavu-fonts-all ripgrep figlet \
kolourpaint ImageMagick strace gh jq yq bind-utils iputils wget helm kubectl \
azure-cli opentofu kustomize rclone restic s3cmd yakuake"
# Own switches because these need vendor repos, not Fedora's.
ARG INSTALL_VSCODE=true
ARG INSTALL_GCLOUD=true

RUN if [ "${INSTALL_VSCODE}" = "true" ]; then \
		rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
		printf '%s\n' \
			'[code]' \
			'name=Visual Studio Code' \
			'baseurl=https://packages.microsoft.com/yumrepos/vscode' \
			'enabled=1' \
			'autorefresh=1' \
			'type=rpm-md' \
			'gpgcheck=1' \
			'gpgkey=https://packages.microsoft.com/keys/microsoft.asc' \
			> /etc/yum.repos.d/vscode.repo && \
		dnf install -y dnf-plugins-core && \
		dnf makecache && \
		dnf install -y code; \
	fi && \
	if [ "${INSTALL_GCLOUD}" = "true" ]; then \
		printf '%s\n' \
			'[google-cloud-cli]' \
			'name=Google Cloud CLI' \
			"baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-\$basearch" \
			'enabled=1' \
			'gpgcheck=1' \
			'repo_gpgcheck=0' \
			'gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg' \
			> /etc/yum.repos.d/google-cloud-cli.repo && \
		dnf install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin; \
	fi && \
	if [ -n "${BASE_PACKAGES}" ]; then dnf install -y ${BASE_PACKAGES}; fi && \
	dnf clean all

# Terraform, k9s, oc and argocd: not packaged in Fedora, so pinned downloads. curl/on-demand
# unzip so this survives `--build-arg BASE_PACKAGES=""`. docs/image-design.md#terraform-and-k9s-use-curl-not-wget
ARG TERRAFORM_VERSION=1.14.8
ARG K9S_VERSION=0.51.0
ARG OC_VERSION=4.22.6
ARG ARGOCD_VERSION=3.4.6
ARG TARGETARCH
RUN ARCH="${TARGETARCH:-amd64}" && \
	case "${ARCH}" in amd64) OC_ARCH=x86_64 ;; *) OC_ARCH="${ARCH}" ;; esac && \
	if ! command -v unzip >/dev/null; then dnf install -y unzip && dnf clean all; fi && \
	curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" \
		-o /tmp/terraform.zip && \
	unzip -q /tmp/terraform.zip -d /usr/local/bin && \
	rm -f /tmp/terraform.zip /usr/local/bin/LICENSE.txt && \
	curl -fsSL "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz" \
		-o /tmp/k9s.tar.gz && \
	tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s && \
	rm -f /tmp/k9s.tar.gz && \
	curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/${OC_ARCH}/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" \
		-o /tmp/oc.tar.gz && \
	tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc && \
	rm -f /tmp/oc.tar.gz && \
	curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-${ARCH}" \
		-o /usr/local/bin/argocd && \
	chmod 0755 /usr/local/bin/argocd && \
	terraform version >/dev/null && \
	test -x /usr/local/bin/k9s && \
	oc version --client >/dev/null && \
	argocd version --client >/dev/null

# abc/root ship with an empty shell field, which makes xterm warn and fall back.
RUN usermod -s /bin/bash root && usermod -s /bin/bash abc

# Trust CA certificates mounted at $CA_CERT_DIR. Runs 00- because everything that talks
# to the network is downstream of it. Always exits 0 -- a failing cont-init script takes
# the container down with it. Rationale and behaviour: certs/README.md
RUN mkdir -p /custom-cont-init.d
RUN cat > /custom-cont-init.d/00-ca-certs.sh <<'EOF'
#!/bin/bash
# Read a container env var, falling back to the s6 envdir -- the authoritative copy.
cenv() {
  local v="${!1}"
  if [ -z "${v}" ] && [ -r "/run/s6/container_environment/$1" ]; then
    v=$(cat "/run/s6/container_environment/$1")
  fi
  printf '%s' "${v:-$2}"
}

CERT_DIR="$(cenv CA_CERT_DIR /certs)"
PRIVATE_REGISTRY="$(cenv PRIVATE_REGISTRY '')"
ANCHORS=/etc/pki/ca-trust/source/anchors
PREFIX=dailytop-

shopt -s nullglob

# Revoke whatever a previous start installed.
stale=("${ANCHORS}/${PREFIX}"*)
if [ ${#stale[@]} -gt 0 ]; then
  rm -f "${stale[@]}"
fi

certs=("${CERT_DIR}"/*.crt "${CERT_DIR}"/*.pem)

if [ ${#certs[@]} -eq 0 ]; then
  if [ -d "${CERT_DIR}" ]; then
    echo "[custom-init] no CA certificates in ${CERT_DIR}"
  fi
  # Re-extract only if the removal above actually took something out.
  if [ ${#stale[@]} -gt 0 ]; then
    update-ca-trust extract || true
    echo "[custom-init] removed ${#stale[@]} previously trusted CA certificate(s)"
  fi
  exit 0
fi

for c in "${certs[@]}"; do
  install -m 0644 "${c}" "${ANCHORS}/${PREFIX}$(basename "${c}")" || \
    echo "[custom-init] WARNING: could not install ${c}" >&2
done

if update-ca-trust extract; then
  echo "[custom-init] trusted ${#certs[@]} CA certificate(s) from ${CERT_DIR}"
else
  echo "[custom-init] WARNING: update-ca-trust failed; mounted CAs are NOT trusted" >&2
  exit 0
fi

# The inner DinD daemon reads /etc/docker/certs.d/<host>/, not the system trust store.
if [ -n "${PRIVATE_REGISTRY}" ] && [ -d /etc/docker ]; then
  d="/etc/docker/certs.d/${PRIVATE_REGISTRY}"
  rm -rf "${d}"
  mkdir -p "${d}"
  i=0
  for c in "${certs[@]}"; do
    cp "${c}" "${d}/${PREFIX}$((i++)).crt"
  done
  echo "[custom-init] wired ${#certs[@]} CA certificate(s) into ${d}"
fi

exit 0
EOF
RUN chmod 0755 /custom-cont-init.d/00-ca-certs.sh && \
	bash -n /custom-cont-init.d/00-ca-certs.sh

# Declared for discoverability in `docker inspect`; the script defaults to it anyway.
ENV CA_CERT_DIR=/certs

# Strip DISPLAY from kwin: it never needs it, and a stale value could deadlock GL init.
# Insurance against a regression, not a live bug. docs/image-design.md#kwin-display-strip
RUN grep -q 'kwin_wayland --no-lockscreen --xwayland &' /defaults/startwm_wayland.sh && \
	sed -i 's/kwin_wayland --no-lockscreen --xwayland/env -u DISPLAY kwin_wayland --no-lockscreen --xwayland/' /defaults/startwm_wayland.sh && \
	grep -q 'env -u DISPLAY kwin_wayland --no-lockscreen --xwayland' /defaults/startwm_wayland.sh

# TEMPORARY: patch selkies for leaked monitor tasks + a blocking nvidia-smi on the
# asyncio loop. Together they are what makes a long-lived desktop degrade. DELETE this
# block when the guards start failing -- that is the removal signal.
# Detail + the exact delete-check: docs/troubleshooting.md#upstream-patches-carried-here-and-when-to-delete-them
RUN SELKIES_PY="$(ls /lsiopy/lib/python3.*/site-packages/selkies/selkies.py)" && \
	grep -q '_gpu_monitor_task_ws" in locals()' "$SELKIES_PY" && \
	grep -q 'GPUtil\.getGPUs()' "$SELKIES_PY" && \
	sed -i -E \
		-e 's/if "(_[a-z_]+_task_ws)" in locals\(\):/if getattr(self, "\1", None):/' \
		-e 's/_task_to_cancel = locals\(\)\["(_[a-z_]+_task_ws)"\]/_task_to_cancel = getattr(self, "\1", None)/' \
		-e 's/GPUtil\.getGPUs\(\)/await asyncio.to_thread(GPUtil.getGPUs)/g' \
		"$SELKIES_PY" && \
	! grep -q '_task_ws" in locals()' "$SELKIES_PY" && \
	! grep -q 'GPUtil\.getGPUs()' "$SELKIES_PY" && \
	[ "$(grep -c 'to_thread(GPUtil.getGPUs)' "$SELKIES_PY")" = "3" ] && \
	/lsiopy/bin/python3 -m py_compile "$SELKIES_PY"


# =============================================================================
#  desktop -- lock screen, flatpak machinery, flatpak apps
# =============================================================================
# Shared parent of `full` and `k8s`: what a human-facing desktop wants and a headless
# workspace agent does not.
FROM base AS desktop

# Empty by default; `flatpak` is installed unconditionally alongside it below.
ARG DESKTOP_PACKAGES=""
# Own switch because it needs a third-party repo.
ARG INSTALL_CLAUDE_DESKTOP=true
# Application IDs, space-separated. Empty still leaves flatpak usable at runtime.
ARG FLATPAKS="com.spotify.Client"
# Restore KDE's screen locker and lock once at session start.
ARG ENABLE_LOCK_SCREEN=true
# Startup hook matching the extension to the host driver; needs the NVIDIA runtime.
ARG ENABLE_NVIDIA_FLATPAK_GL=true

RUN if [ "${INSTALL_CLAUDE_DESKTOP}" = "true" ]; then \
		dnf install -y dnf-plugins-core && \
		curl -fsSL https://pkg.claude-desktop-debian.dev/rpm/claude-desktop.repo \
			-o /etc/yum.repos.d/claude-desktop.repo && \
		dnf makecache && \
		dnf install -y claude-desktop; \
	fi && \
	dnf install -y flatpak ${DESKTOP_PACKAGES} && \
	flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo && \
	dnf clean all

# Baked as container-wide env because the session is not a login shell, so profile.d
# never runs and flatpak apps never reach the KDE menu. Order matches profile.d's own.
# docs/image-design.md#flatpak-apps-in-the-kde-menu
ENV XDG_DATA_DIRS=/config/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share

# The NVIDIA runtime's overmount on /proc/driver/nvidia/params breaks bwrap, so every
# `flatpak run` fails. Unmounting restores it; no-op without the runtime.
# docs/image-design.md#nvidia-proc-overmount-breaks-flatpak
RUN mkdir -p /custom-cont-init.d
RUN cat > /custom-cont-init.d/02-nvidia-proc-unmount.sh <<'EOF'
#!/bin/bash
if grep -q ' /proc/driver/nvidia/params ' /proc/self/mountinfo 2>/dev/null; then
  if umount /proc/driver/nvidia/params 2>/dev/null; then
    echo "[custom-init] unmounted nvidia params overmount (flatpak/bwrap proc fix)"
  else
    echo "[custom-init] WARNING: failed to unmount nvidia params overmount; flatpaks may fail" >&2
  fi
fi
EOF

# The extension ref encodes the host driver version exactly, so it is resolved at
# startup rather than baked -- one image runs on any host. Must follow 02-, whose
# unmount its apply_extra step needs. docs/image-design.md#nvidia-flatpak-gl-extension
RUN cat > /custom-cont-init.d/03-nvidia-flatpak-gl.sh <<'EOF'
#!/bin/bash
command -v nvidia-smi >/dev/null 2>&1 || exit 0
DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]')
if [ -z "${DRIVER}" ]; then
  echo "[custom-init] nvidia-smi present but no driver version; skipping flatpak GL ext" >&2
  exit 0
fi
REF="org.freedesktop.Platform.GL.nvidia-${DRIVER//./-}"
if flatpak info "${REF}" >/dev/null 2>&1; then
  echo "[custom-init] nvidia flatpak GL ext ${REF} already present"
  exit 0
fi
echo "[custom-init] installing nvidia flatpak GL ext ${REF} (host driver ${DRIVER})"
if flatpak install -y --noninteractive flathub "${REF}"; then
  echo "[custom-init] installed ${REF}"
else
  echo "[custom-init] WARNING: could not install ${REF}; flatpak GPU apps will have broken acceleration" >&2
fi
EOF

# nvidia-container-toolkit does not inject the EGL-on-X11 platform libraries, and they are
# driver-locked so they cannot be baked in. Written only when a mount supplies them.
# docs/image-design.md#firefox-egl-on-x11-then-vaapi
RUN cat > /custom-cont-init.d/08-nvidia-egl-x11.sh <<'EOF'
#!/bin/bash
command -v nvidia-smi >/dev/null 2>&1 || exit 0
n=0
for p in xcb xlib; do
  cfg="/usr/share/egl/egl_external_platform.d/20_nvidia_${p}.json"
  lib=$(find /usr/lib /usr/lib64 -name "libnvidia-egl-${p}.so.1" 2>/dev/null | head -1)
  if [ -z "${lib}" ]; then
    rm -f "${cfg}" 2>/dev/null
    continue
  fi
  want=$(printf '{\n    "file_format_version" : "1.0.0",\n    "ICD" : {\n        "library_path" : "libnvidia-egl-%s.so.1"\n    }\n}' "${p}")
  # A deployment may also bind-mount the config read-only; that is correct, not an error.
  if [ "$(cat "${cfg}" 2>/dev/null)" = "${want}" ]; then
    n=$((n+1))
  elif printf '%s\n' "${want}" > "${cfg}" 2>/dev/null; then
    n=$((n+1))
  else
    echo "[custom-init] WARNING: cannot write ${cfg}; EGL-on-X11 will not load" >&2
  fi
done
if [ "${n}" -eq 0 ]; then
  echo "[custom-init] no EGL-on-X11 platform libraries; Firefox will use GLX and decode video on the CPU" >&2
  exit 0
fi
ldconfig
echo "[custom-init] wrote ${n} nvidia EGL-on-X11 platform config(s)"
EOF

# VAAPI needs EGL, so these prefs are worth nothing without 08- above having found the
# libraries. FIREFOX_DISABLE_AV1 forces VP9 for cards with no AV1 decode block.
# docs/image-design.md#firefox-egl-on-x11-then-vaapi
RUN cat > /custom-cont-init.d/09-firefox-vaapi.sh <<'EOF'
#!/bin/bash
PREFS=/usr/lib64/firefox/browser/defaults/preferences/vaapi.js
command -v nvidia-smi >/dev/null 2>&1 || { rm -f "${PREFS}"; exit 0; }
[ -d /usr/lib64/firefox ] || exit 0
mkdir -p "$(dirname "${PREFS}")"
{
  echo 'pref("media.ffmpeg.vaapi.enabled", true);'
  echo 'pref("media.hardware-video-decoding.force-enabled", true);'
  echo 'pref("media.rdd-ffmpeg.enabled", true);'
  [ "${FIREFOX_DISABLE_AV1:-false}" = "true" ] && echo 'pref("media.av1.enabled", false);'
} > "${PREFS}"
echo "[custom-init] wrote Firefox VAAPI prefs (AV1 disabled: ${FIREFOX_DISABLE_AV1:-false})"
# The decoder runs in the RDD process, whose sandbox blocks /dev/dri outright.
[ -n "${MOZ_DISABLE_RDD_SANDBOX}" ] || \
  echo "[custom-init] WARNING: MOZ_DISABLE_RDD_SANDBOX unset; the RDD process cannot open /dev/dri and decode stays on the CPU" >&2
EOF

# Locking at session start has no ordinary path here -- no plasma-session, no logind --
# so this helper drives the ScreenSaver DBus service from inside the session bus. It is
# backgrounded from startwm's own bash -c block below, which is the only place
# DBUS_SESSION_BUS_ADDRESS is set. Needs an account password to be openable.
# docs/image-design.md#the-kde-lock-screen
RUN cat > /lock-on-startup.sh <<'EOF'
#!/bin/bash
[ "${LOCK_ON_STARTUP:-true}" = "true" ] || { echo "[lock-on-startup] disabled via LOCK_ON_STARTUP"; exit 0; }
# Wait for kwin's screen-locker service to register on the session bus, then lock.
for _ in $(seq 1 60); do
  if dbus-send --session --print-reply --dest=org.freedesktop.DBus \
       /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner \
       string:org.freedesktop.ScreenSaver >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
sleep 1
dbus-send --session --type=method_call --dest=org.freedesktop.ScreenSaver \
  /ScreenSaver org.freedesktop.ScreenSaver.Lock
EOF

# Activate or discard the scripts above, per the ARGs. Dropping --no-lockscreen is what
# makes kwin register the ScreenSaver service at all.
RUN chmod 0755 /custom-cont-init.d/02-nvidia-proc-unmount.sh \
		/custom-cont-init.d/08-nvidia-egl-x11.sh /custom-cont-init.d/09-firefox-vaapi.sh && \
	bash -n /custom-cont-init.d/02-nvidia-proc-unmount.sh && \
	bash -n /custom-cont-init.d/08-nvidia-egl-x11.sh && \
	bash -n /custom-cont-init.d/09-firefox-vaapi.sh && \
	if [ "${ENABLE_NVIDIA_FLATPAK_GL}" = "true" ]; then \
		chmod 0755 /custom-cont-init.d/03-nvidia-flatpak-gl.sh && \
		bash -n /custom-cont-init.d/03-nvidia-flatpak-gl.sh; \
	else \
		rm -f /custom-cont-init.d/03-nvidia-flatpak-gl.sh; \
	fi && \
	if [ "${ENABLE_LOCK_SCREEN}" = "true" ]; then \
		chmod 0755 /lock-on-startup.sh && \
		bash -n /lock-on-startup.sh && \
		grep -q 'env -u DISPLAY kwin_wayland --no-lockscreen --xwayland' /defaults/startwm_wayland.sh && \
		sed -i 's/kwin_wayland --no-lockscreen --xwayland/kwin_wayland --xwayland/' /defaults/startwm_wayland.sh && \
		sed -i 's|\( *\)WAYLAND_DISPLAY=wayland-0 plasmashell|\1bash /lock-on-startup.sh \&\n\1WAYLAND_DISPLAY=wayland-0 plasmashell|' /defaults/startwm_wayland.sh && \
		grep -q 'bash /lock-on-startup.sh &' /defaults/startwm_wayland.sh; \
	else \
		rm -f /lock-on-startup.sh; \
	fi

# Needs the security.insecure entitlement: flatpak's deploy step uses bwrap. The NVIDIA
# GL extension is not installed here -- see 03- above.
RUN --security=insecure \
	if [ -n "${FLATPAKS}" ]; then \
		for app in ${FLATPAKS}; do \
			flatpak install -y --noninteractive flathub "${app}" || exit 1; \
		done && \
		find /var/lib/flatpak/repo/tmp -mindepth 1 -delete; \
	fi

# /config is a runtime volume; drop root-owned build droppings a fresh volume inherits.
RUN find /config -mindepth 1 -maxdepth 1 ! -user abc -exec rm -rf {} +


# =============================================================================
#  full -- dev toolchain, Docker-in-Docker, sshd
# =============================================================================
FROM desktop AS full

ARG FULL_PACKAGES="sshpass irssi mutt"
ARG FULL_FLATPAKS=""
ARG INSTALL_DIND=true
ARG INSTALL_SSHD=true
ARG SSHD_PORT=2222
# Runtime: a registry host[:port] served by a private CA, wired into the inner DinD's
# certs.d by 00-ca-certs.sh. See certs/README.md.
ENV PRIVATE_REGISTRY=""
# Sets abc/root passwords at start from $USER_PASSWORD. Required with the lock screen.
# Named to avoid BuildKit's SecretsUsedInArgOrEnv lint -- no password is ever a build arg.
ARG INSTALL_ACCOUNT_HOOK=true

RUN if [ -n "${FULL_PACKAGES}" ]; then dnf install -y ${FULL_PACKAGES}; fi && dnf clean all

# `runc` is EXPLICIT and must stay so while the base needs it: without an OCI runtime
# dockerd restart-loops every ~4s, and each start stacks another tmpfs on /tmp that
# nothing unmounts. INSTALL_DIND=false REMOVES the service, which is mandatory for any
# image without the toolchain. docs/image-design.md#docker-in-docker-and-explicit-runc
RUN if [ "${INSTALL_DIND}" = "true" ]; then \
		dnf install -y docker-buildx runc && dnf clean all && \
		command -v runc >/dev/null && \
		ln -sf /usr/bin/tini-static /usr/local/bin/docker-init && \
		mkdir -p /etc/docker && \
		echo '{"features": {"containerd-snapshotter": false}}' > /etc/docker/daemon.json; \
	else \
		rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker && \
		test ! -e /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker; \
	fi

# Unprivileged sshd (as abc), hence key-only auth. Parks rather than exits on bad
# config -- an s6 longrun that exits restart-loops forever.
# docs/image-design.md#sshd
RUN cat > /defaults/svc-sshd-run <<'EOF'
#!/command/with-contenv bash
CONF="${SSHD_CONFIG:-/defaults/sshd_config}"

park() {
  echo "[svc-sshd] $1" >&2
  echo "[svc-sshd] parking; exiting here would s6 restart-loop this service" >&2
  exec sleep infinity
}

[ -f "$CONF" ] || park "sshd config $CONF not found -- not starting sshd"

install -d -o abc -g abc -m 0700 /config/.ssh /config/.ssh/host_keys
for t in ed25519 rsa; do
  key="/config/.ssh/host_keys/ssh_host_${t}_key"
  [ -f "$key" ] || s6-setuidgid abc ssh-keygen -q -t "$t" -N '' -f "$key" \
    || park "could not generate $t host key"
done

echo "[svc-sshd] starting sshd with $CONF"
exec s6-setuidgid abc /usr/sbin/sshd -D -e -f "$CONF"
EOF

RUN if [ "${INSTALL_SSHD}" = "true" ]; then \
		dnf install -y openssh-server && dnf clean all && \
		printf '%s\n' \
			"Port ${SSHD_PORT}" \
			'HostKey /config/.ssh/host_keys/ssh_host_ed25519_key' \
			'HostKey /config/.ssh/host_keys/ssh_host_rsa_key' \
			'PidFile /run/sshd_local.pid' \
			'UsePAM no' \
			'PasswordAuthentication no' \
			'PermitRootLogin no' \
			'AuthorizedKeysFile /config/.ssh/authorized_keys' \
			'Subsystem sftp internal-sftp' \
			> /defaults/sshd_config && \
		mkdir -p /etc/s6-overlay/s6-rc.d/svc-sshd/dependencies.d && \
		echo longrun > /etc/s6-overlay/s6-rc.d/svc-sshd/type && \
		touch /etc/s6-overlay/s6-rc.d/svc-sshd/dependencies.d/init-services && \
		cp /defaults/svc-sshd-run /etc/s6-overlay/s6-rc.d/svc-sshd/run && \
		chmod +x /etc/s6-overlay/s6-rc.d/svc-sshd/run && \
		bash -n /etc/s6-overlay/s6-rc.d/svc-sshd/run && \
		touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-sshd; \
	fi && \
	rm -f /defaults/svc-sshd-run

# Passwords are applied at container start, never baked into a layer. The heredoc
# delimiter is QUOTED so ${USER_PASSWORD} stays literal and expands at runtime.
RUN cat > /custom-cont-init.d/01-set-passwords.sh <<'EOF'
#!/bin/bash
# Runs 01- so the accounts are usable for the rest of init.
if [ -n "${USER_PASSWORD}" ]; then
  echo "abc:${USER_PASSWORD}"  | chpasswd
  echo "root:${USER_PASSWORD}" | chpasswd
  echo "[custom-init] set abc/root passwords from USER_PASSWORD"
else
  echo "[custom-init] USER_PASSWORD unset; leaving account passwords unchanged"
fi
EOF

RUN if [ "${INSTALL_ACCOUNT_HOOK}" = "true" ]; then \
		chmod 0755 /custom-cont-init.d/01-set-passwords.sh && \
		bash -n /custom-cont-init.d/01-set-passwords.sh; \
	else \
		rm -f /custom-cont-init.d/01-set-passwords.sh; \
	fi

RUN --security=insecure \
	if [ -n "${FULL_FLATPAKS}" ]; then \
		for app in ${FULL_FLATPAKS}; do \
			flatpak install -y --noninteractive flathub "${app}" || exit 1; \
		done && \
		find /var/lib/flatpak/repo/tmp -mindepth 1 -delete; \
	fi

# /config is a runtime volume; drop root-owned build droppings a fresh volume inherits.
RUN find /config -mindepth 1 -maxdepth 1 ! -user abc -exec rm -rf {} +


# =============================================================================
#  k8s -- NVIDIA node-layout fixes for a Kubernetes deployment
# =============================================================================
# Omits the full image's toolchain, DinD and sshd. The Firefox VAAPI wiring is in
# `desktop`; this stage adds what a cluster needs on top -- the injected driver lands in
# the node's libdir, not Fedora's. Deployed by the chart in charts/dailytop/.
FROM desktop AS k8s

# libva-utils = vainfo; the rest are cluster debugging conveniences.
ARG K8S_PACKAGES="libva-utils iproute plocate"

RUN if [ -n "${K8S_PACKAGES}" ]; then dnf install -y ${K8S_PACKAGES}; fi && dnf clean all

# No docker toolchain here, so the service must go or dockerd restart-loops.
RUN rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker && \
	test ! -e /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker

# The runtime injects the GBM backend into the node's libdir; Fedora's libgbm only
# searches /usr/lib64/gbm, so without a link there kwin falls back to software rendering.
# docs/image-design.md#nvidia-libraries-land-in-the-wrong-libdir
RUN cat > /custom-cont-init.d/06-nvidia-gbm-link.sh <<'EOF'
#!/bin/bash
ALLOC=$(find /usr/lib /usr/lib64 -name 'libnvidia-allocator.so.1' 2>/dev/null | head -1)
if [ -z "${ALLOC}" ]; then
  echo "[custom-init] libnvidia-allocator not found; GPU GBM unavailable"
  exit 0
fi
mkdir -p /usr/lib64/gbm
ln -sf "${ALLOC}" /usr/lib64/gbm/nvidia-drm_gbm.so
echo "[custom-init] linked nvidia GBM backend -> ${ALLOC}"
EOF

# NVIDIA's vendor libraries resolve their core libraries relative to their own libdir
# rather than through ldconfig, so an injection into a foreign libdir yields EGL/GL that
# initialises and renders black.
# docs/image-design.md#nvidia-libraries-land-in-the-wrong-libdir
RUN cat > /custom-cont-init.d/07-nvidia-glcore-links.sh <<'EOF'
#!/bin/bash
n=0
for base in eglcore glcore glsi tls glvkspirv rtcore gpucomp; do
  f=$(find /usr/lib -name "libnvidia-${base}.so.*" 2>/dev/null | head -1)
  [ -n "${f}" ] || continue
  ln -sf "${f}" /usr/lib64/"$(basename "${f}")" && n=$((n+1))
done
[ "${n}" -eq 0 ] && exit 0
ldconfig
echo "[custom-init] linked ${n} nvidia GL core libs into /usr/lib64 + ran ldconfig"
EOF

RUN chmod 0755 /custom-cont-init.d/06-nvidia-gbm-link.sh /custom-cont-init.d/07-nvidia-glcore-links.sh && \
	bash -n /custom-cont-init.d/06-nvidia-gbm-link.sh && \
	bash -n /custom-cont-init.d/07-nvidia-glcore-links.sh

# Baked because this stage is NVIDIA-only. MOZ_DISABLE_RDD_SANDBOX weakens the sandbox
# around Firefox's media decoder -- required for VAAPI there, and a real trade-off.
# FIREFOX_DISABLE_AV1 forces YouTube to VP9, which pre-Ampere cards decode in hardware.
# Override it to false on Ampere+. docs/image-design.md#av1
ENV LIBVA_DRIVER_NAME=nvidia \
	NVD_BACKEND=direct \
	MOZ_DISABLE_RDD_SANDBOX=1 \
	FIREFOX_DISABLE_AV1=true


# =============================================================================
#  coder -- the desktop as a Coder (coder.com) workspace, GPU-less
# =============================================================================
# `FROM base`: CLI toolkit and VS Code, no lock screen, flatpaks or NVIDIA hooks.
# Software rendering and software H.264 encode throughout. See examples/coder-template/.
#
# The agent runs as an s6 service, NOT the entrypoint -- s6 is PID 1 and owns the whole
# session tree, so your template must set no command/args on the container.
# docs/image-design.md#the-agent-is-a-service-not-the-entrypoint
FROM base AS coder

ARG CODER_PACKAGES=""

RUN if [ -n "${CODER_PACKAGES}" ]; then dnf install -y ${CODER_PACKAGES} && dnf clean all; fi

# Matters more here than elsewhere: the agent stages its binary under /tmp, so a
# stacking /tmp makes the agent itself vanish mid-session.
RUN rm -f /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker && \
	test ! -e /etc/s6-overlay/s6-rc.d/user/contents.d/svc-docker

# dependencies.d/init-services -> start only after PUID/PGID and /config ownership.
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-coder-agent/dependencies.d && \
	echo longrun > /etc/s6-overlay/s6-rc.d/svc-coder-agent/type && \
	touch /etc/s6-overlay/s6-rc.d/svc-coder-agent/dependencies.d/init-services

# The init script arrives BASE64-ENCODED because s6-envdir truncates every env value at
# the first newline -- a plain multi-line script arrives as just its shebang, and the
# agent silently never starts. Decoding to a FILE (not a pipe) keeps s6 supervising the
# agent directly. HOME=/config because that is this image's home, not /home/coder.
# DISPLAY=:0 tracks current bases and will move again.
# docs/image-design.md#the-init-script-must-be-base64
RUN cat > /etc/s6-overlay/s6-rc.d/svc-coder-agent/run <<'EOF'
#!/command/with-contenv bash
INIT=/run/coder-agent-init.sh

park() {
  echo "[svc-coder-agent] $1" >&2
  echo "[svc-coder-agent] parking; exiting here would s6 restart-loop this service" >&2
  exec sleep infinity
}

[ -n "${CODER_AGENT_TOKEN}" ] || park "CODER_AGENT_TOKEN unset -- not starting agent"
[ -n "${CODER_AGENT_INIT_SCRIPT_B64}" ] || park "CODER_AGENT_INIT_SCRIPT_B64 unset -- not starting agent"

printf '%s' "${CODER_AGENT_INIT_SCRIPT_B64}" | base64 -d > "$INIT" \
  || park "could not base64-decode CODER_AGENT_INIT_SCRIPT_B64"
[ -s "$INIT" ] || park "decoded init script is empty"
chmod 0755 "$INIT"

echo "[svc-coder-agent] starting Coder agent as abc (HOME=/config)"
exec s6-setuidgid abc env \
  HOME=/config \
  USER=abc \
  SHELL=/bin/bash \
  XDG_RUNTIME_DIR=/config/.XDG \
  DISPLAY=:0 \
  WAYLAND_DISPLAY=wayland-0 \
  "$INIT"
EOF
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-coder-agent/run && \
	bash -n /etc/s6-overlay/s6-rc.d/svc-coder-agent/run && \
	touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-coder-agent

# The base bakes SELKIES_ENCODER=x264enc,jpeg, whose first entry is the HARDWARE path --
# wrong for a GPU-less image, so the safe value is the default here rather than something
# the deployment must remember. SELKIES_USE_CPU must be "true|locked": a bare "locked"
# parses to the exact opposite. docs/troubleshooting.md#the-encoder-model-read-this-first
ENV SELKIES_ENCODER=x264enc-striped,jpeg
ENV SELKIES_USE_CPU=true|locked

# A privileged container gets the host's /dev, so /dev/dri leaks in on a GPU node and
# selkies auto-selects it with no driver behind it -- a flat #181818 desktop while
# everything reports success. The two env families below have OPPOSITE polarity: one
# must be deleted, the other must be present and "false".
# docs/troubleshooting.md#blank-flat-colour-desktop-the-compositors-gpu-probe
RUN mkdir -p /custom-cont-init.d
RUN cat > /custom-cont-init.d/04-no-gpu.sh <<'EOF'
#!/bin/bash
CENV=/run/s6/container_environment

# Set-ness guards downstream: these must be DELETED, not emptied.
for v in DRI_NODE DRINODE SELKIES_RENDER_DRI; do
  if [ -e "${CENV}/${v}" ]; then
    echo "[custom-init] GPU-less variant: unsetting ${v}=$(cat "${CENV}/${v}")"
    rm -f "${CENV}/${v}"
  fi
done

# Opposite polarity: read as `SELKIES_AUTO_GPU or AUTO_GPU or "true"`, so deleting these
# would re-enable the probe that blanks the stream.
for v in SELKIES_AUTO_GPU AUTO_GPU; do
  printf 'false' > "${CENV}/${v}"
done
echo "[custom-init] GPU-less variant: SELKIES_AUTO_GPU=false (compositor starts in Pixman)"
EOF
RUN chmod 0755 /custom-cont-init.d/04-no-gpu.sh && \
	bash -n /custom-cont-init.d/04-no-gpu.sh

# Baked as well as forced in the hook above, so the safe value is the default.
# LIBGL_ALWAYS_SOFTWARE keeps applications off the driverless node too -- defence in
# depth, and on its own it does NOTHING for the blank stream.
ENV SELKIES_AUTO_GPU=false
ENV AUTO_GPU=false
ENV LIBGL_ALWAYS_SOFTWARE=1

# Chromium and Electron cannot sandbox where chrome-sandbox is not setuid and the seccomp
# filter blocks the userns fallback. The base's wrapped-chromium already covers the menu
# launcher; these two cover the CLI and VS Code, reusing its runtime seccomp test so a
# privileged container keeps its sandbox. docs/unprivileged.md#chromium-and-vs-code
RUN cat > /tmp/chromium-nosandbox.conf <<'EOF'

# Mirrors wrapped-chromium: under a seccomp filter no sandbox is available here.
grep -q 'Seccomp:.0' /proc/1/status || CHROMIUM_FLAGS+=" --no-sandbox --test-type"
EOF
RUN grep -q 'CHROMIUM_FLAGS' /etc/chromium/chromium.conf && \
	cat /tmp/chromium-nosandbox.conf >> /etc/chromium/chromium.conf && \
	rm -f /tmp/chromium-nosandbox.conf && \
	bash -n /etc/chromium/chromium.conf && \
	grep -q 'no-sandbox --test-type' /etc/chromium/chromium.conf

# Shadows /usr/bin/code, which is earlier in PATH, and is what the desktop entries below
# are repointed at -- so the terminal and the menu take the same path.
RUN cat > /usr/local/bin/code <<'EOF'
#!/bin/bash
BIN=/usr/share/code/bin/code
if grep -q 'Seccomp:.0' /proc/1/status; then
  exec "$BIN" "$@"
fi
exec "$BIN" --no-sandbox "$@"
EOF
RUN chmod 0755 /usr/local/bin/code && \
	bash -n /usr/local/bin/code && \
	for f in /usr/share/applications/code.desktop /usr/share/applications/code-url-handler.desktop; do \
		grep -q '^Exec=/usr/share/code/code' "$f" && \
		sed -i 's|^Exec=/usr/share/code/code|Exec=/usr/local/bin/code|' "$f" && \
		! grep -q '^Exec=/usr/share/code/code' "$f" || exit 1; \
	done

# svc-selkies waits forever on pulseaudio's pidfile, at a path hardcoded to match the
# base's baked PULSE_RUNTIME_PATH=/defaults. Honour the variable, and bound the wait --
# an unreachable pidfile costs the desktop, not just audio. docs/unprivileged.md#pulseaudio
RUN grep -q 'until \[ -f /defaults/pid \]; do' /etc/s6-overlay/s6-rc.d/svc-selkies/run && \
	sed -i 's|until \[ -f /defaults/pid \]; do|for i in $(seq 1 120); do [ -f "${PULSE_RUNTIME_PATH:-/defaults}/pid" ] \&\& break; [ "$i" = 120 ] \&\& echo "[svc-selkies] no pulseaudio pidfile after 60s; continuing without audio setup" >\&2|' \
		/etc/s6-overlay/s6-rc.d/svc-selkies/run && \
	grep -q 'PULSE_RUNTIME_PATH:-/defaults' /etc/s6-overlay/s6-rc.d/svc-selkies/run && \
	grep -q 'no pulseaudio pidfile after 60s' /etc/s6-overlay/s6-rc.d/svc-selkies/run && \
	bash -n /etc/s6-overlay/s6-rc.d/svc-selkies/run

# startwm creates Xwayland's socket directory with sudo, which a non-root container cannot
# use -- so Xwayland gets no socket, and the session's MOZ_ENABLE_WAYLAND=0 sends Firefox
# to an X display that never came up. /tmp is 1777. docs/troubleshooting.md#firefox-cannot-open-display-0
RUN grep -q '^sudo mkdir -p /tmp/.X11-unix$' /defaults/startwm_wayland.sh && \
	grep -q '^sudo chmod 1777 /tmp/.X11-unix$' /defaults/startwm_wayland.sh && \
	sed -i \
		-e 's|^sudo mkdir -p /tmp/.X11-unix$|mkdir -p /tmp/.X11-unix|' \
		-e 's|^sudo chmod 1777 /tmp/.X11-unix$|chmod 1777 /tmp/.X11-unix 2>/dev/null \|\| true|' \
		/defaults/startwm_wayland.sh && \
	! grep -q 'sudo.*X11-unix' /defaults/startwm_wayland.sh && \
	bash -n /defaults/startwm_wayland.sh

# The base discards pulseaudio's output, so a pulseaudio that will not start is invisible
# -- and svc-selkies blocks on its pidfile. --log-level=0 keeps this to errors only.
# docs/unprivileged.md#pulseaudio
RUN grep -q -- '--exit-idle-time=-1 > /dev/null 2>&1' /etc/s6-overlay/s6-rc.d/svc-pulseaudio/run && \
	sed -i 's|--exit-idle-time=-1 > /dev/null 2>&1|--exit-idle-time=-1|' \
		/etc/s6-overlay/s6-rc.d/svc-pulseaudio/run && \
	! grep -q '/dev/null' /etc/s6-overlay/s6-rc.d/svc-pulseaudio/run && \
	bash -n /etc/s6-overlay/s6-rc.d/svc-pulseaudio/run

# Coder authenticates every request at its proxy, so the base's HTTP basic auth is a
# second login for nothing, and the sed that enables it uncomments blindly. PASSWORD and
# CUSTOM_USER are inert here. docs/image-design.md#no-http-basic-auth
RUN NGINX_INIT=/etc/s6-overlay/s6-rc.d/init-nginx/run && \
	grep -q 'if \[ ! -z \${PASSWORD+x} \]; then' "$NGINX_INIT" && \
	grep -q 'CUSER="\${CUSTOM_USER:-abc}"' "$NGINX_INIT" && \
	sed -i \
		-e '/if \[ ! -z \${PASSWORD+x} \]; then/,/^fi$/d' \
		-e '/CUSER="\${CUSTOM_USER:-abc}"/d' \
		"$NGINX_INIT" && \
	! grep -q 'PASSWORD\|CUSTOM_USER\|htpasswd' "$NGINX_INIT" && \
	bash -n "$NGINX_INIT" && \
	[ "$(grep -c auth_basic /defaults/default.conf)" = "4" ] && \
	sed -i '/auth_basic/d' /defaults/default.conf && \
	! grep -q auth_basic /defaults/default.conf

# The base self-signs into /config/ssl, inside the user's mount, where a volume carried
# over from another uid leaves nginx unable to read the key -- and nginx failing takes the
# desktop with it. Regenerated in /run each start. docs/image-design.md#tls-material-lives-in-run
RUN NGINX_INIT=/etc/s6-overlay/s6-rc.d/init-nginx/run && \
	grep -q 'if \[ ! -f "/config/ssl/cert.pem" \]; then' "$NGINX_INIT" && \
	[ "$(grep -c /config/ssl "$NGINX_INIT")" = "6" ] && \
	[ "$(grep -c /config/ssl /defaults/default.conf)" = "2" ] && \
	sed -i 's|/config/ssl|/run/ssl|g' "$NGINX_INIT" /defaults/default.conf && \
	! grep -q /config/ssl "$NGINX_INIT" /defaults/default.conf && \
	bash -n "$NGINX_INIT"

# Fedora's stock nginx.conf keeps a default server on :80 that nothing here routes to --
# the desktop is conf.d/default.conf on 3000/3001. A non-root uid cannot bind it where
# ip_unprivileged_port_start is 1024. `nginx -t` leaves a root-owned pid file and empty
# logs behind, which must not reach a layer. docs/image-design.md#the-stock-80-server-block
RUN [ "$(grep -c '^    server {$' /etc/nginx/nginx.conf)" = "1" ] && \
	grep -q 'listen       80;' /etc/nginx/nginx.conf && \
	sed -i '/^    server {$/,/^    }$/d' /etc/nginx/nginx.conf && \
	! grep -q 'listen       80' /etc/nginx/nginx.conf && \
	grep -q 'include /etc/nginx/conf.d/\*.conf;' /etc/nginx/nginx.conf && \
	nginx -t && \
	rm -f /run/nginx.pid /var/log/nginx/access.log /var/log/nginx/error.log && \
	[ ! -e /run/nginx.pid ] && [ -z "$(ls -A /var/log/nginx)" ]

# Runs the whole session as a non-root uid with no capabilities, for clusters enforcing a
# restricted pod security policy. Off by default: it makes PUID/PGID inert and relaxes group
# permissions on paths the init scripts write. docs/unprivileged.md
ARG UNPRIVILEGED=false

# Paths the s6 init scripts write to at runtime. Made group-writable and group-root, so
# ANY uid works provided the pod runs with gid 0, the usual convention. Extending
# this list is how you fix a new "Permission denied" from an init script.
ARG UNPRIVILEGED_PATHS="/etc/nginx /usr/share/selkies /etc/glvnd/egl_vendor.d \
/etc/vulkan/icd.d /etc/pki/ca-trust/source/anchors /etc/pki/ca-trust/extracted \
/var/lib/nginx /var/log/nginx /defaults /app /etc/passwd /etc/group"

# A non-root master cannot setuid, so `user` is a warning per start, and the pid file
# moves out of /run -- the one path here whose permissions the deployment owns, not the
# image. docs/unprivileged.md#nginx-as-a-non-root-master
RUN if [ "${UNPRIVILEGED}" = "true" ]; then \
		grep -q '^user nginx;$' /etc/nginx/nginx.conf && \
		grep -q '^pid /run/nginx.pid;$' /etc/nginx/nginx.conf && \
		sed -i \
			-e '/^user nginx;$/d' \
			-e 's|^pid /run/nginx.pid;$|pid /var/lib/nginx/nginx.pid;|' \
			/etc/nginx/nginx.conf && \
		! grep -q '^user nginx;' /etc/nginx/nginx.conf && \
		grep -q '^pid /var/lib/nginx/nginx.pid;$' /etc/nginx/nginx.conf; \
	fi

# s6-applyuidgid calls setgroups() unconditionally, which needs CAP_SETGID. A non-root
# container never has it EFFECTIVE -- k8s puts capabilities.add in the bounding set only
# and never sets ambient caps -- so every `s6-setuidgid abc` call site exits 111 and s6
# restart-loops that service forever. docs/unprivileged.md#no-capabilities-are-needed
RUN cat > /usr/local/bin/s6-setuidgid-unpriv <<'EOF'
#!/bin/bash
# Already the target user, so dropping privileges is a no-op: drop the username and exec.
if [ "$(id -u)" != "0" ]; then
  shift
  exec "$@"
fi
exec /package/admin/s6/command/s6-setuidgid "$@"
EOF

# An arbitrary uid has no passwd entry, and getpwuid() failures are obscure when they
# surface (plasmashell, dbus, ssh). Needs /etc/passwd group-writable, hence the path list.
RUN cat > /custom-cont-init.d/05-unpriv-passwd.sh <<'EOF'
#!/bin/bash
uid=$(id -u)
if getent passwd "${uid}" >/dev/null 2>&1; then
  exit 0
fi
if printf 'abc-unpriv:x:%s:%s:container user:/config:/bin/bash\n' "${uid}" "$(id -g)" >> /etc/passwd 2>/dev/null; then
  echo "[custom-init] added /etc/passwd entry for uid ${uid}"
else
  echo "[custom-init] WARNING: uid ${uid} has no passwd entry and /etc/passwd is not writable" >&2
fi
exit 0
EOF

# lsiown and /docker-mods ship 0744, so a non-root container cannot execute them and
# init-adduser exits 126 -- which halts every service that depends on it.
RUN if [ "${UNPRIVILEGED}" = "true" ]; then \
		chmod 0755 /usr/local/bin/s6-setuidgid-unpriv && \
		bash -n /usr/local/bin/s6-setuidgid-unpriv && \
		[ "$(readlink /command/s6-setuidgid)" = "../package/admin/s6/command/s6-setuidgid" ] && \
		ln -sf /usr/local/bin/s6-setuidgid-unpriv /command/s6-setuidgid && \
		chmod 0755 /usr/sbin/lsiown /docker-mods && \
		find /etc/s6-overlay/s6-rc.d -name run -type f ! -perm -o+x -exec chmod 0755 {} + && \
		! find /etc/s6-overlay/s6-rc.d -name run -type f ! -perm -o+x | grep -q . && \
		chmod 0755 /custom-cont-init.d/05-unpriv-passwd.sh && \
		bash -n /custom-cont-init.d/05-unpriv-passwd.sh && \
		chgrp -R 0 ${UNPRIVILEGED_PATHS} && \
		chmod -R g=u ${UNPRIVILEGED_PATHS} && \
		[ "$(stat -c '%A %G' /usr/sbin/lsiown)" = "-rwxr-xr-x root" ] && \
		[ "$(stat -c '%A %G' /etc/passwd)" = "-rw-rw-r-- root" ]; \
	else \
		rm -f /usr/local/bin/s6-setuidgid-unpriv /custom-cont-init.d/05-unpriv-passwd.sh; \
	fi

# /config is a runtime volume; drop root-owned build droppings a fresh volume inherits.
RUN find /config -mindepth 1 -maxdepth 1 ! -user abc -exec rm -rf {} +

# Inert when running as root: preinit only consults it on the branch where it cannot
# chown /run itself, which is fatal otherwise. A k8s emptyDir on /run is mode 2777.
ENV S6_YES_I_WANT_A_WORLD_WRITABLE_RUN_BECAUSE_KUBERNETES=1
