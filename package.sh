#!/usr/bin/env bash
# Packages the built rhel9-dev image, plus the scripts that run it, for a
# machine that won't build it itself (e.g. RHEL8 with podman).
#
#   ./package.sh [OUT_DIR]     default: dist/
#
# Writes OUT_DIR/rhel9-dev-<date>/ and a .tar of it (the image inside is
# already compressed, so the outer tar isn't). See INSTALL.md in the package
# for the other side.
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$HERE/dist}"

# Sets ENGINE
source "$HERE/engine.sh"

"$ENGINE" image inspect "$IMAGE_NAME" >/dev/null 2>&1 \
    || { echo "error: no image '$IMAGE_NAME'; run ./build.sh first" >&2; exit 1; }

NAME="rhel9-dev-$(date +%Y%m%d)"
PKG="$OUT_DIR/$NAME"
rm -rf "$PKG" "$PKG.tar"
mkdir -p "$PKG/dnsmasq"

# Prefer pigz: same .gz format, much faster on a multi-GB image.
GZIP_CMD=gzip
command -v pigz >/dev/null && GZIP_CMD=pigz

echo "==> Saving $IMAGE_NAME (this takes a few minutes)"
"$ENGINE" save "$IMAGE_NAME" | "$GZIP_CMD" > "$PKG/rhel9-dev-image.tar.gz"

# Only what running the image needs; building it is this repo's job.
cp "$HERE/run.sh" "$HERE/engine.sh" "$HERE/run-dhcp.sh" "$HERE/README.md" "$PKG/"
cp "$HERE/dnsmasq/dhcp.conf.example" "$PKG/dnsmasq/"
cp "$HERE/INSTALL-PACKAGE.md" "$PKG/INSTALL.md"

{
    echo "image:      $IMAGE_NAME $("$ENGINE" image inspect "$IMAGE_NAME" --format '{{.Id}}')"
    echo "packaged:   $(date -Iseconds)"
    echo "repo:       $(git -C "$HERE" rev-parse --short HEAD)$(git -C "$HERE" diff --quiet HEAD -- run.sh engine.sh run-dhcp.sh || echo ' (scripts modified)')"
} > "$PKG/PACKAGE-INFO"
# The OMP bundle in the image, to diff against the hosts' /opt/omp/BUILD-INFO.
"$ENGINE" run --rm "$IMAGE_NAME" cat /opt/omp/BUILD-INFO > "$PKG/OMP-BUILD-INFO" 2>/dev/null \
    || { rm -f "$PKG/OMP-BUILD-INFO"; echo "note: image has no OMP bundle" >&2; }

(cd "$PKG" && sha256sum rhel9-dev-image.tar.gz run.sh engine.sh run-dhcp.sh > SHA256SUMS)
tar -C "$OUT_DIR" -cf "$PKG.tar" "$NAME"

echo
cat "$PKG/PACKAGE-INFO"
echo
echo "Wrote $PKG.tar ($(du -h "$PKG.tar" | cut -f1)). Copy it over, then follow INSTALL.md inside."
