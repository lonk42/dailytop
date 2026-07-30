/*
 * Coder template for `dailytop:coder`. An EXAMPLE -- set `local.image`,
 * `local.namespace` and the storage class to match your cluster.
 *
 * No GPU: software rendering and software H.264 encode, so it schedules anywhere. That
 * is a real CPU cost -- see the resources block.
 *
 * FOUR THINGS ARE LOAD-BEARING and easy to "tidy" into breakage:
 *
 *   1. No `command`/`args` on the container -- s6-overlay must stay PID 1.
 *   2. The init script env var is BASE64, because s6-envdir truncates values at the
 *      first newline and the agent then silently never starts.
 *   3. The home volume mounts at /config, not /home/coder.
 *   4. `subdomain = true` requires a wildcard access URL and TLS cert. Path-based
 *      proxying would make SUBFOLDER a per-workspace computed value.
 *
 * Details for 1-3: docs/image-design.md#coder
 *
 * Note what is NOT here: no privileged, seccomp or procMount. Adding flatpak apps to
 * this variant reintroduces the need for all three, and with them the /dev/dri leak
 * that 04-no-gpu.sh exists to catch.
 */

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "coder" {}

# coderd runs in-cluster, so the provisioner uses its service account.
provider "kubernetes" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  # CHANGE THESE.
  namespace = "coder-workspaces"
  image     = "registry.example.com/dailytop:coder"

  # Secret holding extra root CAs (keys ending .crt / .pem), mounted at /certs.
  # REQUIRED behind an internal CA: the agent curls the access URL to fetch its own
  # binary, and without the CA that fails x509 -- pod up, desktop up, workspace never
  # healthy. Leave empty for a publicly trusted cert. See certs/README.md.
  ca_cert_secret = ""

  name = lower("dailytop-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}")
  labels = {
    "app.kubernetes.io/name"     = "dailytop"
    "app.kubernetes.io/instance" = local.name
    "coder.owner"                = data.coder_workspace_owner.me.name
    "coder.workspace_id"         = data.coder_workspace.me.id
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home volume size"
  description  = "Size of the persistent /config volume (KDE config, caches, app data)."
  type         = "number"
  default      = 32
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 10
    max = 500
  }
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU cores"
  description  = "Software H.264 encode of a desktop stream is CPU-bound; 4 is a sensible floor."
  type         = "number"
  default      = 8
  icon         = "/emojis/1f5a5.png"
  mutable      = true
  validation {
    min = 4
    max = 16
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GiB)"
  description  = "Plasma plus VS Code and a browser."
  type         = "number"
  default      = 8
  icon         = "/emojis/1f9e0.png"
  mutable      = true
  validation {
    min = 4
    max = 64
  }
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  # No `dir` -- it is deprecated, and the agent already starts in $HOME, which
  # svc-coder-agent sets to /config. Pointing it at a non-$HOME path also breaks
  # Coder Desktop file sync.

  # Deliberately minimal: the desktop session is started by s6 well before the agent,
  # and anything heavier belongs in the image, not in a script that reruns on every
  # workspace start.
  startup_script = <<-EOT
    set -eu
    echo "workspace up; desktop is served by selkies on :3000"
  EOT

  # The desktop does not depend on this script, so do not gate the workspace on it.
  startup_script_behavior = "non-blocking"

  metadata {
    display_name = "CPU"
    key          = "cpu"
    script       = "top -bn1 | awk '/Cpu\\(s\\)/ {printf \"%.0f%%\", $2+$4}'"
    interval     = 10
    timeout      = 5
  }

  metadata {
    display_name = "Memory"
    key          = "mem"
    script       = "free -h | awk '/^Mem/ {print $3 \"/\" $2}'"
    interval     = 10
    timeout      = 5
  }

  # Reads 1-2 on a healthy pod and must stay FLAT. A climbing count means something
  # re-enabled Docker-in-Docker, which stacks tmpfs over the agent's own binary.
  # docs/troubleshooting.md#svc-docker-restart-loop-stacks-tmpfs-on-tmp
  metadata {
    display_name = "/tmp mounts"
    key          = "tmp_mounts"
    script       = "grep -c ' /tmp ' /proc/self/mountinfo"
    interval     = 60
    timeout      = 5
  }
}

resource "coder_app" "desktop" {
  agent_id     = coder_agent.main.id
  slug         = "desktop"
  display_name = "KDE Desktop"
  icon         = "/icon/desktop.svg"
  url          = "http://localhost:3000"

  # Required -- see note 4 in the header.
  subdomain = true
  share     = "owner"

  healthcheck {
    url = "http://localhost:3000/"
    # The Plasma session takes a while on a cold start, and it is slower here than on
    # the GPU variants; 30 x 10s keeps the app from flapping to unhealthy meanwhile.
    interval  = 10
    threshold = 30
  }
}

# Persists across workspace stop/start -- deliberately NOT gated on start_count.
resource "kubernetes_persistent_volume_claim" "config" {
  metadata {
    name      = "${local.name}-config"
    namespace = local.namespace
    labels    = local.labels
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    # storage_class_name = "your-storage-class"
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_pod" "main" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = local.name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    restart_policy = "Never"

    # No node_selector and no runtime_class_name: this variant wants no GPU, so it must
    # NOT request the nvidia runtime.

    container {
      name  = "dailytop"
      image = local.image

      # Avoids re-pulling a multi-GB image on every start. The trap: with a MUTABLE tag
      # a node that cached it keeps serving the OLD build under a workspace that reports
      # perfectly healthy. Prefer an immutable tag -- see README.md#releases.
      image_pull_policy = "IfNotPresent"

      # NO command/args -- see note 1 in the header. s6-overlay is the entrypoint.

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      # BASE64, and it must stay that way -- see note 2. Decoded by svc-coder-agent.
      env {
        name  = "CODER_AGENT_INIT_SCRIPT_B64"
        value = base64encode(coder_agent.main.init_script)
      }

      env {
        name  = "PUID"
        value = "1000"
      }
      env {
        name  = "PGID"
        value = "1000"
      }
      env {
        name  = "TZ"
        value = "UTC"
      }
      env {
        name  = "SUBFOLDER"
        value = "/"
      }
      env {
        name  = "KEYBOARD"
        value = "en-us-qwerty"
      }
      env {
        name  = "TITLE"
        value = "dailytop workspace"
      }
      env {
        name  = "PIXELFLUX_WAYLAND"
        value = "true"
      }

      # The image bakes these already; repeated because getting them wrong is silent
      # and expensive, and an explicit template is easier to audit. Plain `x264enc` is
      # the HARDWARE path, so it is simply wrong here. DRINODE/DRI_NODE stay unset.
      # docs/troubleshooting.md#the-encoder-model-read-this-first
      env {
        name  = "SELKIES_ENCODER"
        value = "x264enc-striped,jpeg"
      }
      # "true|locked", NOT "locked" -- a bare "locked" parses to CPU mode OFF and
      # unlocked, the exact opposite. The suffix stops the browser UI flipping it back.
      env {
        name  = "SELKIES_USE_CPU"
        value = "true|locked"
      }
      # The compositor's GPU probe is separate from the encoder's and defaults ON. Left
      # on, every frame is a flat clear colour while everything reports success.
      # docs/troubleshooting.md#blank-flat-colour-desktop-the-compositors-gpu-probe
      env {
        name  = "SELKIES_AUTO_GPU"
        value = "false"
      }
      env {
        name  = "AUTO_GPU"
        value = "false"
      }

      # Firefox's native-Wayland path freezes against this kwin. A kwin interaction,
      # not a GPU one, so it applies here too.
      env {
        name  = "MOZ_ENABLE_WAYLAND"
        value = "0"
      }

      resources {
        requests = {
          cpu    = "2"
          memory = "4Gi"
        }
        limits = {
          cpu    = tostring(data.coder_parameter.cpu.value)
          memory = "${data.coder_parameter.memory.value}Gi"
        }
      }

      volume_mount {
        name       = "config"
        mount_path = "/config"
      }

      # Chromium/Electron (VS Code) crashes on the 64 MB default. This is the k8s
      # equivalent of compose's shm_size: "2gb".
      volume_mount {
        name       = "dshm"
        mount_path = "/dev/shm"
      }

      dynamic "volume_mount" {
        for_each = local.ca_cert_secret == "" ? [] : [local.ca_cert_secret]
        content {
          name       = "ca-certs"
          mount_path = "/certs"
          read_only  = true
        }
      }
    }

    volume {
      name = "config"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.config.metadata[0].name
        read_only  = false
      }
    }

    volume {
      name = "dshm"
      empty_dir {
        medium     = "Memory"
        size_limit = "2Gi"
      }
    }

    dynamic "volume" {
      for_each = local.ca_cert_secret == "" ? [] : [local.ca_cert_secret]
      content {
        name = "ca-certs"
        secret {
          secret_name = volume.value
        }
      }
    }
  }
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_pod.main[0].id

  item {
    key   = "image"
    value = local.image
  }
  item {
    key   = "rendering"
    value = "software (llvmpipe + libx264)"
  }
  item {
    key   = "home"
    value = "/config (${data.coder_parameter.home_disk_size.value}Gi PVC)"
  }
}
