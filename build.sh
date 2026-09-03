#!/usr/bin/env bash
# Builds the rhel9-dev image with docker or podman. Credentials, if used, are
# passed to the build via --secret (a tmpfs mount, supported natively by both
# BuildKit and buildah) and never touch an image layer or this script's
# arguments/history.
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
SECRETS_DIR="$(dirname "$0")/.secrets"

# Sets ENGINE (docker or podman); override with ENGINE=podman ./build.sh
source "$(dirname "$0")/engine.sh"

USE_SUBSCRIPTION=0
if [[ "${1:-}" == "--subscription" ]]; then
    USE_SUBSCRIPTION=1
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
DOCKER_BUILDKIT=1 "$ENGINE" build "${SECRET_ARGS[@]}" -t "$IMAGE_NAME" "$(dirname "$0")"

echo
echo "Built image: $IMAGE_NAME (engine: $ENGINE)"
echo "Run it with:  $ENGINE run -it --rm -v \"\$HOME/GIT_REPOS:/workspace\" $IMAGE_NAME bash"
