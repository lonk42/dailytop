{{/* Chart name, overridable. */}}
{{- define "dailytop.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Release-qualified name, overridable. */}}
{{- define "dailytop.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "dailytop.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dailytop.labels" -}}
helm.sh/chart: {{ include "dailytop.chart" . }}
{{ include "dailytop.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "dailytop.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dailytop.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "dailytop.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dailytop.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. `image.tag` wins; otherwise the variant and the chart's appVersion
compose the immutable tag the release workflow publishes: k8s + ls286-1.0.0.
*/}}
{{- define "dailytop.image" -}}
{{- $tag := .Values.image.tag }}
{{- if not $tag }}
{{- if not .Values.image.variant }}
{{- fail "set image.tag, or image.variant so the chart can derive one from appVersion" }}
{{- end }}
{{- $tag = printf "%s-%s" .Values.image.variant .Chart.AppVersion }}
{{- end }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{/*
Name of the ConfigMap holding initScripts.
*/}}
{{- define "dailytop.initScriptsName" -}}
{{- printf "%s-init" (include "dailytop.fullname" .) }}
{{- end }}

{{/*
Container environment: the chart's own defaults for the enabled features, with
`.Values.env` layered on top, then the raw `extraEnv` entries.
*/}}
{{- define "dailytop.env" -}}
{{- $defaults := dict -}}
{{- if .Values.gpu.enabled -}}
{{- $_ := set $defaults "NVIDIA_VISIBLE_DEVICES" "all" -}}
{{- $_ := set $defaults "NVIDIA_DRIVER_CAPABILITIES" .Values.gpu.driverCapabilities -}}
{{- $_ := set $defaults "DRINODE" .Values.gpu.driNode -}}
{{- $_ := set $defaults "DRI_NODE" .Values.gpu.driNode -}}
{{/* `x264enc` is the hardware path, and offering it first is the whole point of a GPU. */}}
{{- $_ := set $defaults "SELKIES_ENCODER" "x264enc,x264enc-striped,jpeg" -}}
{{- else -}}
{{- $_ := set $defaults "SELKIES_ENCODER" "x264enc-striped,jpeg" -}}
{{- end -}}
{{- if .Values.unprivileged.enabled -}}
{{- $_ := set $defaults "LSIO_NON_ROOT_USER" "true" -}}
{{- $_ := set $defaults "PULSE_RUNTIME_PATH" "/run/pulse" -}}
{{- $_ := set $defaults "NO_GAMEPAD" "1" -}}
{{- end -}}
{{- $env := merge (deepCopy (default dict .Values.env)) $defaults }}
{{- range $k, $v := $env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- if .Values.auth.existingSecret }}
- name: USER_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.auth.existingSecret }}
      key: {{ .Values.auth.secretKey }}
{{- end }}
{{- with .Values.extraEnv }}
{{- toYaml . }}
{{- end }}
{{- end }}

{{/*
Pod securityContext: the preset the enabled features imply, with podSecurityContext
merged over it.
*/}}
{{- define "dailytop.podSecurityContext" -}}
{{- $ctx := dict }}
{{- if .Values.unprivileged.enabled }}
{{- $_ := set $ctx "runAsNonRoot" true }}
{{- if .Values.unprivileged.runAsUser }}
{{- $_ := set $ctx "runAsUser" .Values.unprivileged.runAsUser }}
{{- end }}
{{- $_ := set $ctx "runAsGroup" 0 }}
{{- $_ := set $ctx "fsGroup" 0 }}
{{- $_ := set $ctx "fsGroupChangePolicy" "OnRootMismatch" }}
{{- $_ := set $ctx "seccompProfile" (dict "type" "RuntimeDefault") }}
{{- end }}
{{- if .Values.flatpak.enabled }}
{{- $_ := set $ctx "seccompProfile" (dict "type" "Unconfined") }}
{{- end }}
{{- $ctx = merge (deepCopy (default dict .Values.podSecurityContext)) $ctx }}
{{- toYaml $ctx }}
{{- end }}

{{/*
Container securityContext, same rules.
*/}}
{{- define "dailytop.containerSecurityContext" -}}
{{- $ctx := dict }}
{{- if .Values.unprivileged.enabled }}
{{- $_ := set $ctx "allowPrivilegeEscalation" false }}
{{- $_ := set $ctx "capabilities" (dict "drop" (list "ALL")) }}
{{- $_ := set $ctx "readOnlyRootFilesystem" false }}
{{- end }}
{{- if .Values.flatpak.enabled }}
{{- $_ := set $ctx "procMount" "Unmasked" }}
{{- end }}
{{- $ctx = merge (deepCopy (default dict .Values.containerSecurityContext)) $ctx }}
{{- toYaml $ctx }}
{{- end }}
