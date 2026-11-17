#!/usr/bin/env bash
# Packages the built rhel9-dev image, plus the scripts that run it, for a
# machine that won't build it itself (e.g. RHEL8 with podman).
#
#   ./package.sh [--runtime] [OUT_DIR]     default OUT_DIR: dist/
#
#   --runtime   package rhel9-runtime (./build.sh --runtime) instead, for
#               hosts that run a built application as a system service
#
# Writes OUT_DIR/<image>-<date>/ and a .tar of it (the image inside is
# already compressed, so the outer tar isn't). See INSTALL.md in the package
# for the other side.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME=0
OUT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime) RUNTIME=1; shift ;;
        -*)        echo "error: unknown option: $1" >&2; exit 2 ;;
        *)         OUT_DIR="$1"; shift ;;
    esac
done
OUT_DIR="${OUT_DIR:-$HERE/dist}"
if [[ "$RUNTIME" -eq 1 ]]; then
    IMAGE_NAME="${IMAGE_NAME:-rhel9-runtime}"
    BUILD_HINT="./build.sh --runtime"
else
    IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
    BUILD_HINT="./build.sh"
fi

# Sets ENGINE
source "$HERE/engine.sh"

"$ENGINE" image inspect "$IMAGE_NAME" >/dev/null 2>&1 \
    || { echo "error: no image '$IMAGE_NAME'; run $BUILD_HINT first" >&2; exit 1; }

NAME="$IMAGE_NAME-$(date +%Y%m%d)"
IMAGE_TAR="$IMAGE_NAME-image.tar.gz"
PKG="$OUT_DIR/$NAME"
rm -rf "$PKG" "$PKG.tar"
mkdir -p "$PKG"

# Prefer pigz: same .gz format, much faster on a multi-GB image.
GZIP_CMD=gzip
command -v pigz >/dev/null && GZIP_CMD=pigz

echo "==> Saving $IMAGE_NAME (this takes a few minutes)"
"$ENGINE" save "$IMAGE_NAME" | "$GZIP_CMD" > "$PKG/$IMAGE_TAR"

# The image's config digest, which is what podman calls its ID (and what
# install-shared.sh compares against). Docker may report another digest as
# its ID, so read it from the archive actually saved: docker and podman both
# write a manifest.json naming the config ("<hex>.json" or "blobs/sha256/<hex>").
CONFIG_ID="$("$GZIP_CMD" -dc "$PKG/$IMAGE_TAR" | tar -xOf - manifest.json 2>/dev/null \
    | grep -o '"Config":"[^"]*"' | grep -oE '[0-9a-f]{64}' | head -1 || true)"
[[ -n "$CONFIG_ID" ]] || echo "warning: couldn't read the image's config digest from $IMAGE_TAR" >&2

# Only what using the image needs; building it is this repo's job.
# run-dhcp.sh stays in the repo: deployed copies are for development, not
# DHCP. The runtime package needs only the installer, which also writes
# each application's service.
if [[ "$RUNTIME" -eq 1 ]]; then
    SCRIPTS=(install-shared.sh)
    cp "$HERE/INSTALL-RUNTIME.md" "$PKG/INSTALL.md"
else
    SCRIPTS=(run.sh engine.sh install-shared.sh)
    cp "$HERE/INSTALL-PACKAGE.md" "$PKG/INSTALL.md"
fi
for f in "${SCRIPTS[@]}"; do cp "$HERE/$f" "$PKG/"; done
cp "$HERE/README.md" "$PKG/"

{
    echo "image:      $IMAGE_NAME ${CONFIG_ID:+sha256:$CONFIG_ID}"
    echo "engine id:  $ENGINE $("$ENGINE" image inspect "$IMAGE_NAME" --format '{{.Id}}')"
    echo "packaged:   $(date -Iseconds)"
    echo "repo:       $(git -C "$HERE" rev-parse --short HEAD)$(git -C "$HERE" diff --quiet HEAD -- "${SCRIPTS[@]}" run-app.sh Dockerfile || echo ' (modified)')"
    if [[ "$RUNTIME" -eq 1 ]]; then
        echo "java:       $("$ENGINE" run --rm "$IMAGE_NAME" --version 2>&1 | head -n1)"
    fi
} > "$PKG/PACKAGE-INFO"
if [[ "$RUNTIME" -eq 0 ]]; then
    # The OMP bundle in the image, to diff against the hosts' /opt/omp/BUILD-INFO.
    "$ENGINE" run --rm "$IMAGE_NAME" cat /opt/omp/BUILD-INFO > "$PKG/OMP-BUILD-INFO" 2>/dev/null \
        || { rm -f "$PKG/OMP-BUILD-INFO"; echo "note: image has no OMP bundle" >&2; }
fi

(cd "$PKG" && sha256sum "$IMAGE_TAR" "${SCRIPTS[@]}" > SHA256SUMS)
tar -C "$OUT_DIR" -cf "$PKG.tar" "$NAME"

echo
cat "$PKG/PACKAGE-INFO"
echo
echo "Wrote $PKG.tar ($(du -h "$PKG.tar" | cut -f1)). Copy it over, then follow INSTALL.md inside."
