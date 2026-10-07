#!/usr/bin/env bash
# Starts a rhel9-dev container as you (your host UID/GID), set up for
# everyday work, including omp_distro's ./build.sh and the OMP agent.
#
#   ./run.sh                   login shell in your repo base directory
#   ./run.sh --root            login shell as root instead
#   ./run.sh CMD...            run CMD in a login shell, then exit
#                              e.g. ./run.sh 'cd omp_distro && ./build.sh'
#   ./run.sh --omp [REPO [ARGS...]]
#                              run the OMP coding agent in REPO under your
#                              repo base directory (default: the base
#                              directory itself), passing it ARGS
#
# Your repo base directory is $WORKSPACE if set, else ~/GIT_REPOS if it
# exists, else the directory you were asked for once and that was saved in
# ~/.config/rhel9-dev/workspace. It's mounted at the same path as on the host
# (with /workspace as a symlink to it), and so is your ~/.omp: OMP sees the
# same paths, config, sessions and memory in the container as on the host.
#
# Environment overrides:
#   WORKSPACE=DIR              your repo base directory
#   IMAGE_NAME=rhel9-dev       image to run
#   ENGINE=docker|podman       see engine.sh
#
# What it sets up, compared with a bare `docker run -it rhel9-dev bash`:
#   - your host UID/GID inside the container (see entrypoint.sh), so files
#     you touch under /workspace stay yours on the host. Rootless podman
#     also needs --userns=keep-id for that, which this adds.
#   - seccomp=unconfined, so unshare(2) works. omp_distro's build.sh runs its
#     offline smoke tests in a private network namespace (`unshare -rn`), and
#     the engines' default seccomp profiles refuse unshare to any process
#     without CAP_SYS_ADMIN, root included. Lifting seccomp is narrower than
#     --cap-add SYS_ADMIN or --privileged: no capabilities are added.
#     --omp keeps the default profile: OMP doesn't need unshare, so the agent
#     doesn't get it. It still has all of /workspace and the full network.
#   - a login shell, so /etc/profile.d sets PATH, GOTOOLCHAIN and friends
#     the same way `su -` would.
#   - per-user named volumes for the Go module and build caches, so repeat
#     builds don't re-download every module. Drop yours with:
#         $ENGINE volume rm rhel9-dev-$USER-gopath rhel9-dev-$USER-gocache
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
WORKSPACE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/rhel9-dev/workspace"

# Sets ENGINE, ENGINE_ROOTLESS, ENGINE_IS_PODMAN
source "$(dirname "$0")/engine.sh"

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \?//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

# Sets WORKSPACE. Asks only when there's no $WORKSPACE, no ~/GIT_REPOS and no
# saved answer that still exists, and remembers the answer.
resolve_workspace() {
    if [[ -n "${WORKSPACE:-}" ]]; then
        [[ -d "$WORKSPACE" ]] || die "WORKSPACE '$WORKSPACE' does not exist"
        return
    fi
    if [[ -d "$HOME/GIT_REPOS" ]]; then
        WORKSPACE="$HOME/GIT_REPOS"
        return
    fi
    if [[ -s "$WORKSPACE_FILE" ]]; then
        WORKSPACE="$(<"$WORKSPACE_FILE")"
        [[ -d "$WORKSPACE" ]] && return
        echo "Saved repo base directory '$WORKSPACE' no longer exists." >&2
    fi
    [[ -t 0 ]] || die "no ~/GIT_REPOS; set WORKSPACE=<your git repo base directory>"

    local answer
    while true; do
        read -rep "Git repo base directory: " answer
        answer="${answer/#\~/$HOME}"
        [[ -n "$answer" && -d "$answer" ]] && break
        echo "'$answer' is not a directory." >&2
    done
    WORKSPACE="$(cd "$answer" && pwd)"
    mkdir -p "$(dirname "$WORKSPACE_FILE")"
    printf '%s\n' "$WORKSPACE" > "$WORKSPACE_FILE"
    echo "Saved to $WORKSPACE_FILE; edit or delete it to change." >&2
}

AS_ROOT=0
RUN_OMP=0
case "${1:-}" in
    -h|--help)  usage; exit 0 ;;
    --root)     AS_ROOT=1; shift ;;
    --omp)      RUN_OMP=1; shift ;;
esac

resolve_workspace
# The physical path, which is what OMP records on the host too.
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
case "$WORKSPACE" in
    /|/bin|/bin/*|/boot*|/dev*|/etc*|/lib*|/opt|/opt/*|/proc*|/root*|/run*|/sbin*|/sys*|/usr*|/var/lib*|/workspace*)
        die "can't mount WORKSPACE '$WORKSPACE' at the same path in the container: it would shadow image files" ;;
esac

# Only ask for a TTY when there is one, so `./run.sh CMD` works from scripts
# and CI as well as from a terminal.
TTY_ARGS=(-i)
[[ -t 0 && -t 1 ]] && TTY_ARGS+=(-t)

WORKDIR="$WORKSPACE"
if [[ "$RUN_OMP" -eq 1 && $# -gt 0 ]]; then
    REPO="${1%/}"; shift
    [[ -d "$WORKSPACE/$REPO" ]] || die "'$REPO' is not a directory under $WORKSPACE"
    WORKDIR="$WORKSPACE/$REPO"
fi

# ":z" relabels the bind mount for SELinux (podman on an enforcing host);
# docker ignores it elsewhere. The container always starts as root so the
# entrypoint can create your user; it then drops to it.
ARGS=(
    run --rm "${TTY_ARGS[@]}"
    --hostname rhel9-dev
    --user 0
    -v "$WORKSPACE:$WORKSPACE:z"
    -e "HOST_WORKSPACE=$WORKSPACE"
    -w "$WORKDIR"
)
[[ "$RUN_OMP" -eq 1 ]] || ARGS+=(--security-opt seccomp=unconfined)

# Rootless docker maps container root to you and every other container UID to
# a subordinate UID, so only root inside writes /workspace files as you.
if [[ "$ENGINE_ROOTLESS" -eq 1 && "$ENGINE_IS_PODMAN" -eq 0 && "$AS_ROOT" -eq 0 ]]; then
    echo "note: rootless docker: running as container root, which is you on the host" >&2
    AS_ROOT=1
fi

if [[ "$AS_ROOT" -eq 0 && "$(id -u)" -ne 0 ]]; then
    # A name useradd accepts: lowercase, and u<UID> if the host name has
    # characters it doesn't (e.g. DOMAIN\user).
    CUSER="$(id -un | tr '[:upper:]' '[:lower:]')"
    [[ "$CUSER" =~ ^[a-z_][a-z0-9_.-]*$ ]] || CUSER="u$(id -u)"
    # Create ~/.omp first, or the engine would create it root-owned.
    mkdir -p "$HOME/.omp"
    ARGS+=(
        -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -e "HOST_USER=$CUSER"
        -e "HOST_HOME=$HOME"
        -v "rhel9-dev-$CUSER-gopath:$HOME/go"
        -v "rhel9-dev-$CUSER-gocache:$HOME/.cache/go-build"
        -v "$HOME/.omp:$HOME/.omp:z"
    )
    # keep-id maps your host UID to the same UID inside the container; without
    # it rootless podman would map it to a subordinate UID.
    [[ "$ENGINE_ROOTLESS" -eq 1 ]] && ARGS+=(--userns=keep-id)
fi

if [[ "$RUN_OMP" -eq 1 ]]; then
    exec "$ENGINE" "${ARGS[@]}" "$IMAGE_NAME" bash -lc '
        command -v omp >/dev/null || { echo "error: OMP is not installed in this image; see README: OMP" >&2; exit 1; }
        exec omp "$@"' omp "$@"
elif [[ $# -eq 0 ]]; then
    exec "$ENGINE" "${ARGS[@]}" "$IMAGE_NAME" bash -l
else
    exec "$ENGINE" "${ARGS[@]}" "$IMAGE_NAME" bash -lc "$*"
fi
