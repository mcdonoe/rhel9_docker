#!/usr/bin/env bash
# Downloads the eastern seaboard map tiles for the image (connected machine
# only). Cuts a PMTiles archive out of Protomaps' daily OpenStreetMap
# planet build, fetching only the tiles inside the bounding box, into
# maps/, where the next ./build.sh picks it up.
#
#   ./fetch-maps.sh [--maxzoom N] [--bbox W,S,E,N] [--build YYYYMMDD] [--dry-run]
#
#   --maxzoom N     highest zoom level to include (default 11, ~360 MB). Each level
#                   roughly doubles the size (z12 ~800 MB, z14 ~3.4 GB);
#                   MapLibre over-zooms past it, blurrier with each level.
#   --bbox W,S,E,N  area (default -84.5,24.3,-66.5,47.6: Maine to the
#                   Florida Keys, inland to about the Appalachians)
#   --build DATE    which Protomaps daily build (default: yesterday's).
#                   Protomaps keeps only recent builds; see
#                   https://maps.protomaps.com/builds/
#   --dry-run       print the size it would download, and stop
#
# Runs `pmtiles extract` inside the rhel9-dev image (IMAGE_NAME), which has
# the pmtiles CLI, so build the image once first if you haven't.
#
# OpenStreetMap data is ODbL-licensed: the app must show
# "© OpenStreetMap contributors" on the map.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
OUT_DIR="$HERE/maps"
NAME=eastern-seaboard
MAXZOOM=11
BBOX=-84.5,24.3,-66.5,47.6
BUILD="$(date -u -d yesterday +%Y%m%d)"
DRY_RUN=0

source "$HERE/engine.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --maxzoom) MAXZOOM="${2:?}"; shift 2 ;;
        --bbox)    BBOX="${2:?}"; shift 2 ;;
        --build)   BUILD="${2:?}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)         echo "error: unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$MAXZOOM" =~ ^[0-9]+$ && "$MAXZOOM" -le 15 ]] || { echo "error: --maxzoom must be 0-15" >&2; exit 2; }
[[ "$BBOX" =~ ^-?[0-9.]+,-?[0-9.]+,-?[0-9.]+,-?[0-9.]+$ ]] || { echo "error: --bbox must be W,S,E,N" >&2; exit 2; }
[[ "$BUILD" =~ ^[0-9]{8}$ ]] || { echo "error: --build must be YYYYMMDD" >&2; exit 2; }

"$ENGINE" image inspect "$IMAGE_NAME" >/dev/null 2>&1 \
    || { echo "error: no image '$IMAGE_NAME'; run ./build.sh first" >&2; exit 1; }

SRC="https://build.protomaps.com/$BUILD.pmtiles"
mkdir -p "$OUT_DIR"
EXTRA=()
[[ "$DRY_RUN" -eq 1 ]] && EXTRA+=(--dry-run)

echo "==> $SRC -> maps/$NAME.pmtiles (bbox $BBOX, zoom 0-$MAXZOOM)"
"$ENGINE" run --rm --network host --security-opt label=disable --entrypoint pmtiles \
    -v "$OUT_DIR:/out" "$IMAGE_NAME" \
    extract "$SRC" "/out/$NAME.pmtiles.part" --bbox="$BBOX" --maxzoom="$MAXZOOM" "${EXTRA[@]}"
[[ "$DRY_RUN" -eq 1 ]] && exit 0

mv "$OUT_DIR/$NAME.pmtiles.part" "$OUT_DIR/$NAME.pmtiles"
cat > "$OUT_DIR/$NAME.json" <<EOF
{
  "name": "$NAME",
  "source": "$SRC",
  "bbox": [$BBOX],
  "minzoom": 0,
  "maxzoom": $MAXZOOM,
  "fetched": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "attribution": "© OpenStreetMap contributors (ODbL); Protomaps basemap"
}
EOF
echo "Wrote maps/$NAME.pmtiles ($(du -h "$OUT_DIR/$NAME.pmtiles" | cut -f1)). Rebuild the image to include it."
