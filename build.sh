#!/usr/bin/env bash
# Builds the rhel9-dev image with docker or podman.
#
#   ./build.sh [--subscription] [--omp-bundle PATH | --no-omp]
#
# Installs the OMP coding agent from the newest omp_distro bundle, if any
# (see the OMP section of the README). ROUTELM_URL=... overrides the model
# router baked into OMP's config.
#
# Credentials, if used, are
# passed to the build via --secret (a tmpfs mount, supported natively by both
# BuildKit and buildah) and never touch an image layer or this script's
# arguments/history.
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
SECRETS_DIR="$(dirname "$0")/.secrets"

# Sets ENGINE (docker or podman); override with ENGINE=podman ./build.sh
source "$(dirname "$0")/engine.sh"

# OMP bundle to install: --omp-bundle PATH (or OMP_BUNDLE=PATH), else the
# newest one omp_distro has built. --no-omp builds without OMP.
OMP_BUNDLE="${OMP_BUNDLE:-}"
OMP_DIST="${OMP_DIST:-$HOME/GIT_REPOS/omp_distro/dist}"
ROUTELM_URL="${ROUTELM_URL:-http://192.168.1.151:11400/v1}"
STAGE_DIR="$(dirname "$0")/omp-bundle"

USE_SUBSCRIPTION=0
USE_OMP=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --subscription) USE_SUBSCRIPTION=1; shift ;;
        --omp-bundle)   [[ $# -ge 2 ]] || { echo "error: --omp-bundle needs a path" >&2; exit 2; }
                        OMP_BUNDLE="$2"; shift 2 ;;
        --no-omp)       USE_OMP=0; shift ;;
        *)              echo "error: unknown option: $1" >&2; exit 2 ;;
    esac
done

# Stage the bundle where the Dockerfile's bind mount can see it. A hard link
# avoids copying ~1 GB when dist/ is on the same filesystem.
rm -f "$STAGE_DIR"/omp-portable-*.tar.gz
if [[ "$USE_OMP" -eq 1 ]]; then
    if [[ -z "$OMP_BUNDLE" ]]; then
        OMP_BUNDLE="$(ls -t "$OMP_DIST"/omp-portable-*-linux-x64.tar.gz 2>/dev/null | head -n1 || true)"
    fi
    if [[ -n "$OMP_BUNDLE" ]]; then
        [[ -f "$OMP_BUNDLE" ]] || { echo "error: OMP bundle '$OMP_BUNDLE' not found" >&2; exit 1; }
        echo "OMP bundle: $OMP_BUNDLE (RouteLM: $ROUTELM_URL)"
        ln -f "$OMP_BUNDLE" "$STAGE_DIR/" 2>/dev/null || cp "$OMP_BUNDLE" "$STAGE_DIR/"
    else
        echo "No OMP bundle in $OMP_DIST; building without OMP."
        echo "  (build one with: ./run.sh 'cd omp_distro && ./build.sh')"
    fi
fi

SECRET_ARGS=()

if [[ "$USE_SUBSCRIPTION" -eq 1 ]]; then
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"
    USER_FILE="$SECRETS_DIR/rh_username"
    PASS_FILE="$SECRETS_DIR/rh_password"

    if [[ ! -s "$USER_FILE" ]]; then
        read -rp "Red Hat username: " rh_user
        printf '%s' "$rh_user" > "$USER_FILE"
        chmod 600 "$USER_FILE"
    fi
    if [[ ! -s "$PASS_FILE" ]]; then
        read -rsp "Red Hat password: " rh_pass
        echo
        printf '%s' "$rh_pass" > "$PASS_FILE"
        chmod 600 "$PASS_FILE"
    fi

    SECRET_ARGS+=(--secret "id=rh_username,src=$USER_FILE" --secret "id=rh_password,src=$PASS_FILE")
fi

# DOCKER_BUILDKIT is a no-op under podman and required under older docker.
DOCKER_BUILDKIT=1 "$ENGINE" build "${SECRET_ARGS[@]}" \
    --build-arg "ROUTELM_URL=$ROUTELM_URL" -t "$IMAGE_NAME" "$(dirname "$0")"

echo
echo "Built image: $IMAGE_NAME (engine: $ENGINE)"
echo "Run it with:  ./run.sh   (see README: Run)"
if [[ "$USE_OMP" -eq 1 && -n "$OMP_BUNDLE" ]]; then
    echo "Run OMP with: ./run.sh --omp [REPO]"
fi
