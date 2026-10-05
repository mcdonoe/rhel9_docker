#!/usr/bin/env bash
# Starts a rhel9-dev container set up for everyday work, including
# omp_distro's ./build.sh.
#
#   ./run.sh                   login shell as mcdonoe in /workspace
#   ./run.sh --root            login shell as root instead
#   ./run.sh CMD...            run CMD in a login shell as mcdonoe, then exit
#                              e.g. ./run.sh 'cd omp_distro && ./build.sh'
#
# Environment overrides:
#   WORKSPACE=~/GIT_REPOS      host directory mounted at /workspace
#   IMAGE_NAME=rhel9-dev       image to run
#   ENGINE=docker|podman       see engine.sh
#
# What it sets up, compared with a bare `docker run -it rhel9-dev bash`:
#   - seccomp=unconfined, so unshare(2) works. omp_distro's build.sh runs its
#     offline smoke tests in a private network namespace (`unshare -rn`), and
#     the engines' default seccomp profiles refuse unshare to any process
#     without CAP_SYS_ADMIN, root included. Lifting seccomp is narrower than
#     --cap-add SYS_ADMIN or --privileged: no capabilities are added.
#   - a login shell, so /etc/profile.d sets PATH, GOTOOLCHAIN and friends
#     the same way `su - mcdonoe` would.
#   - named volumes for the Go module and build caches, so repeat builds
#     don't re-download every module. Drop them with:
#         $ENGINE volume rm rhel9-dev-gopath rhel9-dev-gocache
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
WORKSPACE="${WORKSPACE:-$HOME/GIT_REPOS}"

# Sets ENGINE
source "$(dirname "$0")/engine.sh"

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \?//'
}

RUN_USER=mcdonoe
case "${1:-}" in
    -h|--help)  usage; exit 0 ;;
    --root)     RUN_USER=root; shift ;;
esac

if [[ ! -d "$WORKSPACE" ]]; then
    echo "error: WORKSPACE '$WORKSPACE' does not exist" >&2
    exit 1
fi

# Only ask for a TTY when there is one, so `./run.sh CMD` works from scripts
# and CI as well as from a terminal.
TTY_ARGS=(-i)
[[ -t 0 && -t 1 ]] && TTY_ARGS+=(-t)

# ":z" relabels the bind mount for SELinux (podman on an enforcing host);
# docker ignores it elsewhere. The cache volumes are only meaningful for
# mcdonoe; root gets its own ~/go inside the container.
ARGS=(
    run --rm "${TTY_ARGS[@]}"
    --hostname rhel9-dev
    --security-opt seccomp=unconfined
    --user "$RUN_USER"
    -v "$WORKSPACE:/workspace:z"
    -v rhel9-dev-gopath:/home/mcdonoe/go
    -v rhel9-dev-gocache:/home/mcdonoe/.cache/go-build
    -w /workspace
)

if [[ $# -eq 0 ]]; then
    exec "$ENGINE" "${ARGS[@]}" "$IMAGE_NAME" bash -l
else
    exec "$ENGINE" "${ARGS[@]}" "$IMAGE_NAME" bash -lc "$*"
fi
