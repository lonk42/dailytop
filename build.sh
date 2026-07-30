#!/usr/bin/env bash
#
# Build a dailytop image variant and load it into the local docker daemon.
#
#   ./build.sh <base|desktop|full|k8s|coder> [extra docker buildx args...]
#
# Env: IMAGE_NAME (dailytop), TAG (the target name), BUILDER (dailytop-builder),
#      PLATFORM (unset).
#
# See docs/building.md.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET="${1:-full}"
shift || true

IMAGE_NAME="${IMAGE_NAME:-dailytop}"
TAG="${TAG:-$TARGET}"
BUILDER="${BUILDER:-dailytop-builder}"
PLATFORM="${PLATFORM:-}"

case "$TARGET" in
	base|coder)        needs_insecure=0 ;;
	desktop|full|k8s)  needs_insecure=1 ;;
	*)
		echo "usage: $0 <base|desktop|full|k8s|coder> [extra buildx args...]" >&2
		exit 1
		;;
esac

# Only the flatpak targets need this; the default builder cannot grant the entitlement.
ensure_builder() {
	if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
		echo ">>> creating buildx builder '$BUILDER' (security.insecure entitlement)"
		docker buildx create \
			--name "$BUILDER" \
			--driver docker-container \
			--buildkitd-flags '--allow-insecure-entitlement security.insecure' >/dev/null
	fi
	docker buildx inspect --bootstrap "$BUILDER" >/dev/null
}

# --- assemble the buildx invocation ------------------------------------------------
args=(build --target "$TARGET" -f "$DIR/Dockerfile")

if [ "$needs_insecure" = 1 ]; then
	ensure_builder
	args+=(--builder "$BUILDER" --allow security.insecure)
fi

[ -n "$PLATFORM" ] && args+=(--platform "$PLATFORM")

ref="$IMAGE_NAME:$TAG"
args+=(--load -t "$ref")

echo ">>> building target '$TARGET' -> $ref (load)"
exec docker buildx "${args[@]}" "$@" "$DIR"
