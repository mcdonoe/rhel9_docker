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
#   ./run.sh --check           check this machine's setup for you: that the
#                              image comes from the shared image store (if
#                              there is one) and that a container starts
#                              quickly as you, with working sudo
#
# Your repo base directory is $WORKSPACE if set, else the directory holding
# this repo's checkout (if run from one), else ~/GIT_REPOS if it exists,
# else the directory you were asked for once and that was saved in
# ~/.config/rhel9-dev/workspace. It's mounted at the same path as on the host
# (with /workspace as a symlink to it), and so is your ~/.omp: OMP sees the
# same paths, config, sessions and memory in the container as on the host.
#
# Environment overrides:
#   WORKSPACE=DIR              your repo base directory
#   IMAGE_NAME=rhel9-dev       image to run
#   ENGINE=docker|podman       see engine.sh
#   npm_config_registry=URL    npm/pnpm registry to use instead of the
#                              image's offline vendored one. On a connected
#                              machine, for builds that need the public
#                              registry (omp_distro's build.sh does):
#                                npm_config_registry=https://registry.npmjs.org/ ./run.sh ...
#                              (pnpm_config_registry is passed through too)
#   RHEL9DEV_GPU=none          don't give the container the host's GPUs
#   RHEL9DEV_CUDA=host|DIR     use the host's CUDA toolkit (/usr/local/cuda,
#                              or DIR) instead of the image's, if it's newer
#                              than the image's; otherwise says so and uses
#                              the image's
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
#   - /opt/rcce_coe from the host, read-only at the same path (skipped if
#     the host has none).
#   - the host's NVIDIA GPUs, if it has any: their devices, and the
#     driver's own libraries (libcuda, NVML, ...) and nvidia-smi read-only
#     under /opt/host-nvidia, put on LD_LIBRARY_PATH and PATH by
#     /etc/profile.d/20-cuda.sh. So CUDA programs run on the GPU, if the
#     host's driver supports the image's CUDA 12 (R525+; it warns if not).
#     Needs nothing else on the host (no NVIDIA container toolkit).
#   - with RHEL9DEV_CUDA=host (or =DIR), the host's CUDA toolkit instead of
#     the image's, if it's newer: read-only at /opt/host-cuda, put on PATH
#     and LD_LIBRARY_PATH ahead of the image's by /etc/profile.d/20-cuda.sh.
#   - a login shell, so /etc/profile.d sets PATH, GOTOOLCHAIN and friends
#     the same way `su -` would.
#   - the host's network (--network host), so a dev server you start in the
#     container is at localhost:<port> in the host's browser.
#   - per-user named volumes for the Go, pnpm and Maven caches, so repeat
#     builds don't re-download or re-copy every package. Drop yours with:
#         $ENGINE volume rm rhel9-dev-$USER-{gopath,gocache,pnpm-store,m2}
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
# Host directories mounted read-only at the same path in the container.
HOST_RO_DIRS=(/opt/rcce_coe)
WORKSPACE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/rhel9-dev/workspace"

HERE="$(dirname "$(readlink -f "$0")")"

# Sets ENGINE, ENGINE_ROOTLESS, ENGINE_IS_PODMAN
source "$HERE/engine.sh"

usage() {
    sed -n '2,34p' "$0" | sed 's/^# \?//'
}

die() {
    echo "error: $*" >&2
    exit 1
}

# Sets WORKSPACE. Asks only when there's no $WORKSPACE, this isn't a git
# checkout, there's no ~/GIT_REPOS and no saved answer that still exists,
# and remembers the answer.
resolve_workspace() {
    if [[ -n "${WORKSPACE:-}" ]]; then
        [[ -d "$WORKSPACE" ]] || die "WORKSPACE '$WORKSPACE' does not exist"
        return
    fi
    # Run from the repo checkout (not an installed copy): the directory
    # holding it is the repo base, e.g. GIT_REPOS for GIT_REPOS/rhel9_docker.
    if [[ -e "$HERE/.git" ]]; then
        WORKSPACE="$(dirname "$HERE")"
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

# --check: is the image the shared store's copy, and does a container start
# quickly as you? Exits non-zero if something needs fixing.
check() {
    local problems=0 rw ro t0 secs out
    echo "engine: $ENGINE ($([[ "$ENGINE_ROOTLESS" -eq 1 ]] && echo rootless || echo rootful))"
    if [[ "$ENGINE_IS_PODMAN" -eq 1 ]]; then
        local list
        list="$("$ENGINE" images --filter "reference=$IMAGE_NAME" --format '{{.ID}} {{.ReadOnly}}')"
        ro="$(awk '$2=="true"{print $1}' <<<"$list" | sort -u)"
        rw="$(awk '$2!="true"{print $1}' <<<"$list" | sort -u)"
        if [[ -z "$ro" && -z "$rw" ]]; then
            echo "PROBLEM: no $IMAGE_NAME image found"
            return 1
        elif [[ -n "$ro" && -n "$rw" ]]; then
            echo "PROBLEM: you have your own copy of $IMAGE_NAME ($rw), which hides the"
            echo "  shared one. Remove yours with: $ENGINE rmi $rw"
            problems=1
        elif [[ -n "$ro" ]]; then
            echo "ok: $IMAGE_NAME comes from the shared image store"
        else
            echo "note: $IMAGE_NAME is your own copy; there's no shared one visible to you."
            echo "  If this machine has a shared store, a ~/.config/containers/storage.conf"
            echo "  of yours may be replacing the system one (see INSTALL.md)."
        fi
        # Without fuse-overlayfs, rootless podman can't show the store's
        # root-owned files as root, so it tries to make you a private,
        # re-owned copy of the whole image: slow on RHEL9+, and on RHEL8 it
        # fails ("storage-chown-by-maps ... operation not permitted").
        if [[ -n "$ro" && "$ENGINE_ROOTLESS" -eq 1 ]] \
                && ! grep -q fuse-overlayfs <<<"$("$ENGINE" info --format '{{json .Store.GraphOptions}}')"; then
            echo "PROBLEM: podman isn't using fuse-overlayfs, so it can't use the shared"
            echo "  image as is (RHEL8: containers fail to start; newer: a private copy)."
            echo "  An admin re-runs the current install-shared.sh, which sets mount_program"
            echo "  in /etc/containers/storage.conf (see INSTALL.md)."
            problems=1
        fi
    else
        "$ENGINE" image inspect "$IMAGE_NAME" >/dev/null 2>&1 \
            || { echo "PROBLEM: no $IMAGE_NAME image found"; return 1; }
        echo "ok: $IMAGE_NAME found"
    fi

    local args=(run --rm --user 0 --security-opt label=disable)
    if [[ "$(id -u)" -ne 0 && ! ( "$ENGINE_ROOTLESS" -eq 1 && "$ENGINE_IS_PODMAN" -eq 0 ) ]]; then
        args+=(-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" -e "HOST_USER=u$(id -u)")
        [[ "$ENGINE_ROOTLESS" -eq 1 ]] && args+=(--userns=keep-id)
    fi
    echo "starting a test container..."
    t0=$SECONDS
    if ! out="$("$ENGINE" "${args[@]}" "$IMAGE_NAME" bash -lc 'echo "uid=$(id -u)"; sudo -n true 2>/dev/null && echo sudo=ok; echo "sudostat=$(stat -c "%a %u" /usr/bin/sudo)"; f=$(mktemp /tmp/check.XXXXXX 2>/dev/null) && g=$(mktemp /tmp/check.XXXXXX 2>/dev/null) && rm -f "$f" "$g" && echo tmp=ok; echo "tmpstat=$(stat -c "%a %u" /tmp)"; g++ --version | head -1' 2>&1)"; then
        echo "PROBLEM: the container failed:"; echo "$out" | sed 's/^/  /'
        return 1
    fi
    secs=$((SECONDS - t0))
    if grep -qx "uid=$(id -u)" <<<"$out"; then
        echo "ok: you are uid $(id -u) inside, as on the host"
    else
        echo "PROBLEM: wrong user inside the container:"; echo "$out" | sed 's/^/  /'; problems=1
    fi
    if [[ "$(id -u)" -ne 0 ]]; then
        grep -qx sudo=ok <<<"$out" && echo "ok: sudo works inside" \
            || { echo "PROBLEM: sudo doesn't work inside ($(sed -n 's/^sudostat=//p' <<<"$out" | awk '{print "/usr/bin/sudo is mode "$1", owner uid "$2}'))."
                 # The store is loaded with force_mask=shared: every file is
                 # 0755 on disk, its real owner and mode in an override_stat
                 # xattr that fuse-overlayfs applies. sudo without its setuid
                 # bit (755, or 111) means those xattrs are as podman 4.x
                 # wrote them, unrepaired (so /tmp is unwritable too); 4111
                 # owned by nobody means the store predates force_mask; 4111
                 # owned by root means sudo itself is fine, but an older
                 # entrypoint left /etc/sudoers.d owned by nobody (RHEL 8).
                 case "$(sed -n 's/^sudostat=//p' <<<"$out")" in
                     [0-7][0-7][0-7]" "*)
                         echo "  The shared store's owner/mode xattrs were never repaired (podman 4.x"
                         echo "  loads them without setuid bits), so /tmp isn't writable either."
                         echo "  An admin re-runs the current install-shared.sh (INSTALL.md)." ;;
                     *" 0")
                         echo "  sudo itself is intact. With a shared store on RHEL 8, the image predates"
                         echo "  its entrypoint's fix for RHEL 8's fuse-overlayfs (sudo then says"
                         echo "  /etc/sudoers.d is owned by uid 65534): install a package built from"
                         echo "  the current repo." ;;
                     *)
                         echo "  If the image is in a shared store, it was probably loaded without"
                         echo "  force_mask: an admin re-runs the current install-shared.sh (INSTALL.md)." ;;
                 esac
                 problems=1; }
    fi
    if grep -qx tmp=ok <<<"$out"; then
        echo "ok: /tmp is writable inside"
    else
        echo "PROBLEM: /tmp isn't writable inside ($(sed -n 's/^tmpstat=//p' <<<"$out" | awk '{print "mode "$1", owner uid "$2}'); it should be"
        echo "  1777, owner 0). Builds and tests that use temporary files fail. If sudo is"
        echo "  also broken, fix that first (above). Otherwise, with a shared store on RHEL 8,"
        echo "  the image predates its entrypoint's fix for RHEL 8's fuse-overlayfs: install"
        echo "  a package built from the current repo."
        problems=1
    fi
    if (( secs > 30 )); then
        echo "PROBLEM: the container took ${secs}s to start. Podman was probably making"
        echo "  you a private copy of the image (see the fuse-overlayfs note in INSTALL.md)."
        problems=1
    else
        echo "ok: started and stopped in ${secs}s"
    fi
    return "$problems"
}

AS_ROOT=0
RUN_OMP=0
case "${1:-}" in
    -h|--help)  usage; exit 0 ;;
    --check)    check; exit ;;
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

# label=disable: on an SELinux host, run this one container unconfined by
# SELinux rather than relabel your files for it. The usual ":z" would
# relabel everything under WORKSPACE and ~/.omp on every start: slow on a
# big tree, it changes your host files' labels, and it fails outright on any
# file you don't own (e.g. root-owned build output). The user namespace and
# seccomp still apply. Hosts without SELinux ignore it.
#
# The container always starts as root so the entrypoint can create your
# user; it then drops to it.
#
# --network host: dev servers in the container (Vite, Storybook, Spring
# Boot...) are reachable from the host's browser at localhost:<port> with
# no port mapping, exactly as if they ran natively, and two servers on one
# port clash just as they would natively. Docker refuses --hostname with it,
# so only podman gets one (the prompt then shows rhel9-dev; with docker it
# shows the host's name).
ARGS=(
    run --rm "${TTY_ARGS[@]}"
    --network host
    --user 0
    --security-opt label=disable
    -v "$WORKSPACE:$WORKSPACE"
    -e "HOST_WORKSPACE=$WORKSPACE"
    -w "$WORKDIR"
)
[[ "$ENGINE_IS_PODMAN" -eq 1 ]] && ARGS+=(--hostname rhel9-dev)
# A registry chosen on the host replaces the vendored one (entrypoint.sh).
for v in npm_config_registry pnpm_config_registry; do
    [[ -n "${!v:-}" ]] && ARGS+=(-e "$v=${!v}")
done
[[ "$RUN_OMP" -eq 1 ]] || ARGS+=(--security-opt seccomp=unconfined)

# Host directories shared into every container, read-only, at the same path.
# A missing one is skipped with a note, so the script still runs on hosts
# without it.
for d in "${HOST_RO_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
        ARGS+=(-v "$d:$d:ro")
    else
        echo "note: $d not found on this host; not mounting it" >&2
    fi
done

# The host's CUDA toolkit instead of the image's, when asked (see the
# header) and only if it's newer: compare nvcc versions (V12.2.128 style),
# the image's from its rhel9-dev.cuda.nvcc label. An image without the label
# has no CUDA of its own, so any host toolkit is newer.
if [[ -n "${RHEL9DEV_CUDA:-}" ]]; then
    CUDA_DIR="$RHEL9DEV_CUDA"
    [[ "$CUDA_DIR" == host ]] && CUDA_DIR=/usr/local/cuda
    if [[ ! -x "$CUDA_DIR/bin/nvcc" ]]; then
        echo "note: $CUDA_DIR has no bin/nvcc, so it isn't a CUDA toolkit; using the image's CUDA" >&2
    else
        host_cuda="$("$CUDA_DIR/bin/nvcc" --version 2>/dev/null | sed -n 's/.*, V\([0-9][0-9.]*\)$/\1/p')"
        image_cuda="$("$ENGINE" image inspect "$IMAGE_NAME" \
            --format '{{index .Config.Labels "rhel9-dev.cuda.nvcc"}}' 2>/dev/null || true)"
        [[ "$image_cuda" == "<no value>" ]] && image_cuda=""
        if [[ -z "$host_cuda" ]]; then
            echo "note: can't tell $CUDA_DIR's CUDA version from its nvcc; using the image's CUDA" >&2
        elif [[ -n "$image_cuda" && "$(printf '%s\n%s\n' "$host_cuda" "$image_cuda" | sort -V | tail -1)" == "$image_cuda" ]]; then
            echo "note: the host's CUDA (nvcc $host_cuda) isn't newer than the image's ($image_cuda); using the image's" >&2
        else
            echo "note: using the host's CUDA (nvcc $host_cuda, from $CUDA_DIR) instead of the image's${image_cuda:+ ($image_cuda)}" >&2
            ARGS+=(-v "$(readlink -f "$CUDA_DIR"):/opt/host-cuda:ro" -e RHEL9DEV_CUDA_HOME=/opt/host-cuda)
        fi
    fi
fi

# The host's NVIDIA GPUs (see the header). The driver's user-space libraries
# must be the host's own (they talk to its kernel module), so mount each one
# found in the host's loader cache by its soname; the image has only the
# link-time stub. RHEL and Ubuntu builds of them both work in the container.
if [[ "${RHEL9DEV_GPU:-}" != none && -c /dev/nvidiactl ]]; then
    for dev in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset /dev/nvidia[0-9]*; do
        [[ -c "$dev" ]] && ARGS+=(--device "$dev")
    done
    LDCONFIG="$(command -v ldconfig || echo /sbin/ldconfig)"
    while read -r soname path; do
        real="$(readlink -f "$path")" && [[ -f "$real" ]] \
            && ARGS+=(-v "$real:/opt/host-nvidia/lib/$soname:ro")
    done < <("$LDCONFIG" -p 2>/dev/null | awk '/x86-64/ && $1 ~ /^lib(cuda|cudadebugger|nvidia-(ml|ptxjitcompiler|nvvm|gpucomp|cfg))\.so\./ {print $1, $NF}' | sort -u -k1,1)
    if NVSMI="$(command -v nvidia-smi)"; then
        ARGS+=(-v "$(readlink -f "$NVSMI"):/opt/host-nvidia/bin/nvidia-smi:ro")
        # The newest CUDA the driver supports, e.g. "11.4". CUDA 12.x
        # programs need 12.0 or later (driver R525+).
        driver_cuda="$("$NVSMI" 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9][0-9.]*\).*/\1/p' | head -1)"
        if [[ -n "$driver_cuda" && "${driver_cuda%%.*}" -lt 12 ]]; then
            echo "note: this host's NVIDIA driver supports CUDA up to $driver_cuda; the image's CUDA 12" >&2
            echo "  programs build here but won't run on the GPU (needs driver R525 or newer)" >&2
        fi
    fi
    ARGS+=(-e RHEL9DEV_NVIDIA=/opt/host-nvidia)
fi

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
        -v "rhel9-dev-$CUSER-pnpm-store:$HOME/.local/share/pnpm"
        -v "rhel9-dev-$CUSER-m2:$HOME/.m2"
        -v "$HOME/.omp:$HOME/.omp"
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
