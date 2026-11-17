#!/usr/bin/env bash
# Installs a rhel9-dev or rhel9-runtime package on this machine, and the
# system services that run applications on rhel9-runtime. Needs no network,
# so it works on airgapped hosts. Run as root, from inside the unpacked
# package (or, for --app, --remove-app and --prune, from PREFIX).
#
# Development image (rhel9-dev), for every user:
#   sudo ./install-shared.sh [options]
#     loads the image into a root-owned, read-only podman image store that
#     every user's podman reads from (an "additional image store"), and
#     installs the scripts that run it. Users then run `rhel9-dev`.
#   sudo /opt/rhel9-dev/install-shared.sh --prune [--store DIR]
#     after an update, once nobody is in a container: delete the image the
#     update replaced, which is still in the store with no name. Refuses
#     while it sees a container using the store. Needs no package.
#
#   --store DIR       the shared image store   (default /var/lib/shared-images)
#   --prefix DIR      where the scripts go     (default /opt/rhel9-dev)
#   --bindir DIR      where the `rhel9-dev` command goes (default /usr/local/bin)
#   --no-fuse-overlayfs
#                     don't set mount_program in storage.conf (see below)
#   --skip-checksums  don't check SHA256SUMS first
#   --tmpdir DIR      where podman unpacks the image while loading it: about
#                     the image's full size (several GB for rhel9-dev).
#                     Default $TMPDIR, else /var/tmp. E.g. --tmpdir /DATA/tmp
#
# Runtime image (rhel9-runtime), for system services:
#   sudo ./install-shared.sh --runtime [--prefix DIR] [--skip-checksums] [--tmpdir DIR]
#     loads the image into root's podman storage (services run as root's
#     podman) and installs this script to PREFIX (default /opt/rhel9-runtime).
#   sudo /opt/rhel9-runtime/install-shared.sh --app NAME \
#           --classpath DIR[:DIR...] --main CLASS [options]
#     writes the system service NAME, which runs CLASS in rhel9-runtime with
#     every jar in the classpath folders. The folders stay on the host and
#     are mounted read-only at the same paths. Re-run to change it; deploy a
#     new build by replacing the jars and `systemctl restart NAME`.
#       --classpath LIST   folders (all their *.jar) and/or .jar files,
#                          colon-separated, in classpath order, e.g.
#                          /OUTPUT/web/output_libs:/OUTPUT/web/cots_libs
#       --main CLASS       the main class
#       --args "ARGS"      arguments to the main class
#       --java-opts "OPTS" JVM options, e.g. "-Xmx2g -Dfoo=bar"
#       --env NAME=VALUE   an environment variable (repeatable)
#       --mount DIR        another host folder, read-only at the same path,
#                          e.g. config or a UI folder (repeatable)
#       --mount-rw DIR     a writable host folder (repeatable); the service's
#                          user must be able to write it
#       --user UID[:GID]   who the application runs as in the container
#                          (default 65534:65534, nobody)
#       --workdir DIR      its working directory (default /tmp)
#       --start            start it now (or restart it, if running)
#       --image NAME       the image (default rhel9-runtime)
#       --unit-type auto|quadlet|systemd
#                          quadlet (podman 4.4+, the default where available)
#                          or a plain systemd unit calling podman run
#       --unit-dir DIR     write the unit there instead, and skip systemctl
#                          (to review or test it)
#   sudo /opt/rhel9-runtime/install-shared.sh --remove-app NAME
#     stops the service and deletes it. The jars are left alone.
#   sudo /opt/rhel9-runtime/install-shared.sh --runtime --prune
#     deletes runtime images that updates replaced and no service uses.
#
# Safe to re-run: that's also how you update to a newer package. Each step
# says what it changed. What the development install does:
#   1. checks the package against SHA256SUMS
#   2. loads the image into the store and makes the store world-readable
#      (rootless podman reads it as each user's own UID, and the container's
#      entrypoint needs to read /etc/shadow from it to create your user)
#   3. labels the store for SELinux like podman's own storage
#   4. adds the store to /etc/containers/storage.conf's
#      additionalimagestores, and sets
#      mount_program = fuse-overlayfs, which lets rootless podman use the
#      store's root-owned files, as root, without making each user a private
#      copy of the image (the store itself is loaded with force_mask=shared,
#      which records each file's owner and mode for fuse-overlayfs, and
#      then repaired, since podman 4.x records setuid bits wrongly). Backs
#      storage.conf up first.
#   5. installs the scripts to PREFIX and links BINDIR/rhel9-dev to run.sh
#   6. lists users whose own ~/.config/containers/storage.conf would hide
#      the shared store from them
#
# Afterwards each user checks their setup with `rhel9-dev --check`.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
STORE=/var/lib/shared-images
PREFIX=""
BINDIR=/usr/local/bin
STORAGE_CONF=/etc/containers/storage.conf
USE_FUSE=auto
PRUNE=0
CHECKSUMS=1
LOAD_TMPDIR=""
RUNTIME=0
# --app / --remove-app
APP=""
REMOVE_APP=""
APP_CLASSPATH=""
APP_MAIN=""
APP_ARGS=""
APP_JAVA_OPTS=""
APP_ENVS=()
APP_MOUNTS=()
APP_MOUNTS_RW=()
APP_USER=65534:65534
APP_WORKDIR=/tmp
APP_START=0
APP_IMAGE=rhel9-runtime
UNIT_TYPE=auto
UNIT_DIR=""
APP_MARKER="# rhel9-runtime app: written by install-shared.sh --app; re-run it to change this file."

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; }
die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# podman load unpacks the compressed image into a temporary file first, in
# $TMPDIR (default /var/tmp), which needs about the image's full size. Point
# it at --tmpdir, and say up front if there's clearly not enough room.
set_load_tmpdir() {
    local dir="${LOAD_TMPDIR:-${TMPDIR:-/var/tmp}}" free need
    mkdir -p "$dir" || die "can't create $dir for temporary files"
    [[ -w "$dir" ]] || die "$dir isn't writable"
    export TMPDIR="$dir"
    free=$(( $(df -Pk "$dir" | awk 'NR==2 {print $4}') / 1024 ))
    need=$(( $(stat -c %s "$1") * 4 / 1024 / 1024 ))   # a rough upper bound
    echo "Temporary files go in $dir ($free MB free; loading needs up to about $need MB)."
    if (( free < need )); then
        echo "warning: $dir may be too small. If the load fails with \"no space left on device\"," >&2
        echo "  re-run with --tmpdir DIR on a bigger filesystem, e.g. --tmpdir /DATA/tmp" >&2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --store)             STORE="${2:?--store needs a directory}"; shift 2 ;;
        --prefix)            PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --bindir)            BINDIR="${2:?--bindir needs a directory}"; shift 2 ;;
        --no-fuse-overlayfs) USE_FUSE=0; shift ;;
        --prune)             PRUNE=1; shift ;;
        --skip-checksums)    CHECKSUMS=0; shift ;;
        --tmpdir)            LOAD_TMPDIR="${2:?--tmpdir needs a folder}"; shift 2 ;;
        --runtime)           RUNTIME=1; shift ;;
        --app)               APP="${2:?--app needs a name}"; RUNTIME=1; shift 2 ;;
        --remove-app)        REMOVE_APP="${2:?--remove-app needs a name}"; RUNTIME=1; shift 2 ;;
        --classpath)         APP_CLASSPATH="${2:?--classpath needs folders}"; shift 2 ;;
        --main)              APP_MAIN="${2:?--main needs a class}"; shift 2 ;;
        --args)              APP_ARGS="${2?--args needs a value}"; shift 2 ;;
        --java-opts)         APP_JAVA_OPTS="${2?--java-opts needs a value}"; shift 2 ;;
        --env)               APP_ENVS+=("${2:?--env needs NAME=VALUE}"); shift 2 ;;
        --mount)             APP_MOUNTS+=("${2:?--mount needs a folder}"); shift 2 ;;
        --mount-rw)          APP_MOUNTS_RW+=("${2:?--mount-rw needs a folder}"); shift 2 ;;
        --user)              APP_USER="${2:?--user needs UID[:GID]}"; shift 2 ;;
        --workdir)           APP_WORKDIR="${2:?--workdir needs a folder}"; shift 2 ;;
        --start)             APP_START=1; shift ;;
        --image)             APP_IMAGE="${2:?--image needs a name}"; shift 2 ;;
        --unit-type)         UNIT_TYPE="${2:?--unit-type needs auto, quadlet or systemd}"; shift 2 ;;
        --unit-dir)          UNIT_DIR="${2:?--unit-dir needs a folder}"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   die "unknown option: $1 (see --help)" ;;
    esac
done
if [[ "$RUNTIME" -eq 1 ]]; then
    IMAGE_NAME="${IMAGE_NAME:-rhel9-runtime}"
    PREFIX="${PREFIX:-/opt/rhel9-runtime}"
else
    IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
    PREFIX="${PREFIX:-/opt/rhel9-dev}"
fi
[[ "$STORE" == /?* && "$PREFIX" == /?* && "$BINDIR" == /?* ]] \
    || die "--store, --prefix and --bindir must be absolute paths"
STORE="${STORE%/}"

# ===========================================================================
# Runtime: application services
# ===========================================================================

# A host path that can go into a podman volume and a unit file as is.
check_path() {
    local what="$1" p="$2"
    [[ "$p" == /?* ]] || die "$what '$p' must be an absolute path"
    [[ "$p" =~ ^[A-Za-z0-9_./@+=-]+$ ]] \
        || die "$what '$p' may only contain letters, digits and _ . / @ + = -"
}

# In unit files, % starts a systemd specifier; %% is a literal %.
unit_escape() { printf '%s' "${1//%/%%}"; }

podman_version_ge() {   # MAJOR MINOR
    local v
    v="$(podman version --format '{{.Client.Version}}' 2>/dev/null || podman --version | awk '{print $NF}')"
    IFS=. read -r vmaj vmin _ <<<"$v"
    (( vmaj > $1 || (vmaj == $1 && vmin >= $2) ))
}

# Every unit this script wrote, as "NAME TYPE FILE".
list_apps() {
    local f
    for f in /etc/containers/systemd/*.container; do
        [[ -f "$f" ]] && grep -qF "$APP_MARKER" "$f" && echo "$(basename "$f" .container) quadlet $f"
    done
    for f in /etc/systemd/system/*.service; do
        [[ -f "$f" ]] && grep -qF "$APP_MARKER" "$f" && echo "$(basename "$f" .service) systemd $f"
    done
    return 0
}

write_app() {
    [[ "$APP" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "--app NAME may only contain letters, digits and _ . -"
    [[ -n "$APP_CLASSPATH" ]] || die "--app needs --classpath (the application's jar folders)"
    [[ -n "$APP_MAIN" ]] || die "--app needs --main (the main class)"
    [[ "$APP_MAIN" =~ ^[A-Za-z_$][A-Za-z0-9_$.]*$ ]] || die "--main '$APP_MAIN' doesn't look like a class name"
    [[ "$APP_USER" =~ ^[0-9]+(:[0-9]+)?$ ]] || die "--user must be UID or UID:GID (numbers)"
    check_path --workdir "$APP_WORKDIR"
    local v
    for v in "$APP_ARGS" "$APP_JAVA_OPTS" "${APP_ENVS[@]}"; do
        [[ "$v" != *[\"\\$'\n']* ]] || die "--args, --java-opts and --env values can't contain \" \\ or newlines"
    done
    for v in "${APP_ENVS[@]}"; do
        [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "--env '$v' must be NAME=VALUE"
    done

    # Folders to mount: each classpath entry's folder (a .jar entry mounts
    # just that file), then --mount and --mount-rw.
    local -a ro=() rw=() entries=()
    local e
    IFS=: read -ra entries <<<"$APP_CLASSPATH"
    [[ "${#entries[@]}" -gt 0 ]] || die "--classpath is empty"
    for e in "${entries[@]}"; do
        check_path "classpath entry" "$e"
        ro+=("$e")
        if [[ -d "$e" ]]; then
            compgen -G "$e/*.jar" >/dev/null || echo "warning: no .jar files in $e yet; the service won't start until there are" >&2
        elif [[ "$e" == *.jar && -f "$e" ]]; then
            :
        else
            echo "warning: $e doesn't exist yet; the service won't start until it does" >&2
        fi
    done
    for e in "${APP_MOUNTS[@]}"; do check_path --mount "$e"; ro+=("$e"); [[ -e "$e" ]] || echo "warning: $e doesn't exist yet" >&2; done
    for e in "${APP_MOUNTS_RW[@]}"; do check_path --mount-rw "$e"; rw+=("$e"); [[ -e "$e" ]] || echo "warning: $e doesn't exist yet" >&2; done

    if [[ "$UNIT_TYPE" == auto ]]; then
        if podman_version_ge 4 4 && [[ -x /usr/lib/systemd/system-generators/podman-system-generator ]]; then
            UNIT_TYPE=quadlet
        else
            UNIT_TYPE=systemd
        fi
    fi
    [[ "$UNIT_TYPE" == quadlet || "$UNIT_TYPE" == systemd ]] || die "--unit-type must be auto, quadlet or systemd"

    local dir="$UNIT_DIR" file uid gid podman_bin
    if [[ -z "$dir" ]]; then
        [[ "$UNIT_TYPE" == quadlet ]] && dir=/etc/containers/systemd || dir=/etc/systemd/system
    fi
    mkdir -p "$dir"
    uid="${APP_USER%%:*}"
    gid="${APP_USER#*:}"
    [[ "$APP_USER" == *:* ]] || gid="$uid"
    podman_bin="$(command -v podman)"

    local tmp
    tmp="$(mktemp)"
    if [[ "$UNIT_TYPE" == quadlet ]]; then
        file="$dir/$APP.container"
        {
            echo "$APP_MARKER"
            echo "[Unit]"
            echo "Description=$APP (rhel9-runtime: $APP_MAIN)"
            echo "Wants=network-online.target"
            echo "After=network-online.target"
            echo
            echo "[Container]"
            echo "Image=$APP_IMAGE"
            echo "ContainerName=$APP"
            echo "Network=host"
            echo "SecurityLabelDisable=true"
            echo "User=$uid"
            echo "Group=$gid"
            echo "WorkingDir=$APP_WORKDIR"
            for e in "${ro[@]}"; do echo "Volume=$e:$e:ro"; done
            for e in "${rw[@]}"; do echo "Volume=$e:$e"; done
            echo "Environment=\"APP_CLASSPATH=$(unit_escape "$APP_CLASSPATH")\""
            [[ -n "$APP_JAVA_OPTS" ]] && echo "Environment=\"JAVA_OPTS=$(unit_escape "$APP_JAVA_OPTS")\""
            for e in "${APP_ENVS[@]}"; do echo "Environment=\"$(unit_escape "$e")\""; done
            echo "Exec=$APP_MAIN $(unit_escape "$APP_ARGS")"
            echo
            echo "[Service]"
            echo "Restart=on-failure"
            echo "RestartSec=5"
            echo "# Java exits 143 on SIGTERM: a normal stop, not a failure."
            echo "SuccessExitStatus=143"
            echo
            echo "[Install]"
            echo "WantedBy=multi-user.target"
        } >"$tmp"
    else
        file="$dir/$APP.service"
        {
            echo "$APP_MARKER"
            echo "[Unit]"
            echo "Description=$APP (rhel9-runtime: $APP_MAIN)"
            echo "Wants=network-online.target"
            echo "After=network-online.target"
            echo
            echo "[Service]"
            echo "ExecStartPre=-$podman_bin rm -f --ignore $APP"
            echo "ExecStart=$podman_bin run --rm --name $APP --network host \\"
            echo "    --security-opt label=disable --user $uid:$gid -w $APP_WORKDIR \\"
            for e in "${ro[@]}"; do echo "    -v $e:$e:ro \\"; done
            for e in "${rw[@]}"; do echo "    -v $e:$e \\"; done
            echo "    \"--env=APP_CLASSPATH=$(unit_escape "$APP_CLASSPATH")\" \\"
            [[ -n "$APP_JAVA_OPTS" ]] && echo "    \"--env=JAVA_OPTS=$(unit_escape "$APP_JAVA_OPTS")\" \\"
            for e in "${APP_ENVS[@]}"; do echo "    \"--env=$(unit_escape "$e")\" \\"; done
            echo "    $APP_IMAGE $APP_MAIN $(unit_escape "$APP_ARGS")"
            echo "ExecStop=$podman_bin stop --ignore -t 10 $APP"
            echo "Restart=on-failure"
            echo "RestartSec=5"
            echo "# Java exits 143 on SIGTERM: a normal stop, not a failure."
            echo "SuccessExitStatus=143"
            echo
            echo "[Install]"
            echo "WantedBy=multi-user.target"
        } >"$tmp"
    fi

    if [[ -f "$file" ]] && ! grep -qF "$APP_MARKER" "$file"; then
        rm -f "$tmp"
        die "$file exists and wasn't written by this script; move it away first"
    fi
    if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
        echo "$file: unchanged."
    else
        [[ -f "$file" ]] && diff -u "$file" "$tmp" || true
        install -m 644 "$tmp" "$file"
        echo "Wrote $file ($UNIT_TYPE)."
    fi
    rm -f "$tmp"

    if [[ -n "$UNIT_DIR" ]]; then
        echo "--unit-dir given, so systemd wasn't told. Review it, or check a quadlet file with:"
        echo "    QUADLET_UNIT_DIRS=$UNIT_DIR /usr/libexec/podman/quadlet -dryrun"
        return 0
    fi

    # A unit of the other type for the same app would clash; remove ours.
    local other
    if [[ "$UNIT_TYPE" == quadlet ]]; then other=/etc/systemd/system/$APP.service; else other=/etc/containers/systemd/$APP.container; fi
    if [[ -f "$other" ]] && grep -qF "$APP_MARKER" "$other"; then
        systemctl disable "$APP.service" >/dev/null 2>&1 || true
        rm -f "$other"
        echo "Removed the old $other."
    fi

    podman image exists "$APP_IMAGE" \
        || echo "warning: root's podman has no image '$APP_IMAGE'; install the runtime package first (--runtime)" >&2
    systemctl daemon-reload
    systemctl cat "$APP.service" >/dev/null 2>&1 \
        || die "systemd has no $APP.service after reloading. For quadlet, see why with:
       /usr/libexec/podman/quadlet -dryrun"
    # Quadlet services start at boot through [Install]; plain units need enabling.
    [[ "$UNIT_TYPE" == systemd ]] && systemctl enable "$APP.service" >/dev/null 2>&1
    if [[ "$APP_START" -eq 1 ]]; then
        systemctl restart "$APP.service"
        sleep 2
        systemctl --no-pager status "$APP.service" | head -n 15 || true
    fi
    cat <<EOF

$APP.service is installed and starts at boot.
    systemctl start $APP          start it (restart after deploying new jars)
    systemctl status $APP         is it running?
    journalctl -u $APP -f         its log
EOF
}

remove_app() {
    [[ "$REMOVE_APP" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "bad app name '$REMOVE_APP'"
    local found=0 f
    for f in "/etc/containers/systemd/$REMOVE_APP.container" "/etc/systemd/system/$REMOVE_APP.service"; do
        [[ -f "$f" ]] || continue
        grep -qF "$APP_MARKER" "$f" || die "$f wasn't written by this script; not touching it"
        found=1
    done
    [[ "$found" -eq 1 ]] || die "no app '$REMOVE_APP' (see: $0 --runtime, which lists them)"
    systemctl stop "$REMOVE_APP.service" 2>/dev/null || true
    systemctl disable "$REMOVE_APP.service" >/dev/null 2>&1 || true
    rm -f "/etc/containers/systemd/$REMOVE_APP.container" "/etc/systemd/system/$REMOVE_APP.service"
    systemctl daemon-reload
    echo "Removed $REMOVE_APP.service. Its jars and folders are untouched."
}

if [[ -n "$APP" || -n "$REMOVE_APP" ]]; then
    [[ -z "$APP" || -z "$REMOVE_APP" ]] || die "use --app or --remove-app, not both"
    [[ -n "$UNIT_DIR" || "$(id -u)" -eq 0 ]] || die "run this as root (sudo $0)"
    command -v podman >/dev/null || die "podman is not installed (dnf install podman)"
    if [[ -n "$REMOVE_APP" ]]; then remove_app; else write_app; fi
    exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "run this as root (sudo $0)"
command -v podman >/dev/null || die "podman is not installed (dnf install podman)"

# ===========================================================================
# Runtime: the image
# ===========================================================================
if [[ "$RUNTIME" -eq 1 ]]; then
    runtime_old_images() {
        podman images --filter dangling=true --filter label=rhel9-dev.image=runtime \
            --format '{{.ID}}  created {{.CreatedSince}}'
    }
    if [[ "$PRUNE" -eq 1 ]]; then
        OLD="$(runtime_old_images)"
        [[ -n "$OLD" ]] || { echo "Nothing to prune."; exit 0; }
        echo "$OLD"
        # podman won't remove an image a container (a running service) uses.
        for id in $(awk '{print $1}' <<<"$OLD"); do
            podman rmi "$id" >/dev/null 2>&1 && echo "deleted $id" || echo "kept $id: a service still uses it (restart it, then prune again)"
        done
        exit 0
    fi
    [[ "$(uname -m)" == x86_64 ]] || die "the image is x86_64 only; this is $(uname -m)"
    IMAGE_TAR="$HERE/$IMAGE_NAME-image.tar.gz"
    [[ -f "$IMAGE_TAR" ]] || die "no $IMAGE_NAME-image.tar.gz next to this script; run it from the unpacked package"

    if [[ "$CHECKSUMS" -eq 1 ]]; then
        step "Checking the package against SHA256SUMS"
        (cd "$HERE" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch; copy the package again"
        echo "OK"
    fi

    step "Loading $IMAGE_NAME into root's podman storage"
    set_load_tmpdir "$IMAGE_TAR"
    podman load -i "$IMAGE_TAR"
    echo "Java in the image: $(podman run --rm "$IMAGE_NAME" --version 2>&1 | head -n1)"

    step "Installing to $PREFIX"
    mkdir -p "$PREFIX"
    install -m 755 "$HERE/install-shared.sh" "$PREFIX/install-shared.sh"
    for f in README.md INSTALL.md PACKAGE-INFO; do
        [[ -f "$HERE/$f" ]] && install -m 644 "$HERE/$f" "$PREFIX/$f"
    done
    echo "Installed."

    step "Application services"
    APPS="$(list_apps)"
    if [[ -z "$APPS" ]]; then
        echo "None yet. Add one with:"
        echo "    $PREFIX/install-shared.sh --app NAME --classpath DIR[:DIR...] --main CLASS"
    else
        echo "$APPS" | awk '{printf "  %s (%s, %s)\n", $1, $2, $3}'
        echo "They keep running the previous image until restarted:"
        echo "    systemctl restart $(awk '{printf "%s ", $1}' <<<"$APPS")"
        echo "Then delete the old image with: $PREFIX/install-shared.sh --runtime --prune"
    fi
    exit 0
fi

# ===========================================================================
# Development image: the shared store
# ===========================================================================
# Podman for the store itself, ignoring storage.conf's options: the store is
# also listed there as an additional store, and opening one store both ways
# at once can deadlock on its lock files.
#
# force_mask=shared stores every file as root-owned 0755 and keeps its real
# owner and mode in a user.containers.override_stat xattr, which
# fuse-overlayfs shows inside users' containers (after the repair below,
# which podman 4.x needs for setuid bits and layer roots). Without it,
# rootless users see the store's root-owned files as owned by nobody, so
# sudo and anything else that checks ownership breaks. It needs
# fuse-overlayfs, so --no-fuse-overlayfs leaves both out.
#
# Any --storage-opt replaces all of storage.conf's options (the additional
# stores included); "" alone means none, and can't be combined with others.
store_podman() {
    local opts=(--storage-opt "")
    if [[ "${USE_FUSE:-1}" != 0 ]]; then
        opts=(--storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs
              --storage-opt overlay.force_mask=shared)
    fi
    podman --root "$STORE" --runroot /run/rhel9-dev-shared-store \
        --storage-driver overlay "${opts[@]}" "$@"
}

# Is the store in use by a running container? Rootless containers live in
# each user's own storage, so the store can't tell; look for mounts of it.
store_in_use() {
    grep -qF "$STORE/" <<<"$(pgrep -af fuse-overlayfs || true)" \
        || grep -qF "$STORE/overlay" /proc/[0-9]*/mountinfo 2>/dev/null
}

if [[ "$PRUNE" -eq 1 ]]; then
    [[ -d "$STORE/overlay-images" ]] || die "$STORE is not an image store"
    OLD="$(store_podman images --filter dangling=true --format '{{.ID}}  created {{.CreatedSince}}')"
    [[ -n "$OLD" ]] || { echo "Nothing to prune in $STORE."; exit 0; }
    if store_in_use; then
        die "a container is using $STORE right now; try again when nobody is in one"
    fi
    echo "$OLD"
    store_podman image prune -f >/dev/null
    echo "Deleted the images above from $STORE."
    exit 0
fi
[[ "$(uname -m)" == x86_64 ]] || die "the image is x86_64 only; this is $(uname -m)"
IMAGE_TAR="$HERE/rhel9-dev-image.tar.gz"
[[ -f "$IMAGE_TAR" ]] || die "no rhel9-dev-image.tar.gz next to this script; run it from the unpacked package"

PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || PY=/usr/libexec/platform-python      # RHEL8 without python3
[[ -x "$PY" ]] || die "no python3 (or RHEL8's /usr/libexec/platform-python) to edit storage.conf with"

# Rootless podman must use fuse-overlayfs with the shared store, on every
# kernel: it's what shows the store's root-owned files as root inside a
# user's container. Without it, podman tries to make each user a re-owned
# copy of the image, which on RHEL8 fails outright ("storage-chown-by-maps:
# lchown ...: operation not permitted") and elsewhere costs minutes and GBs.
[[ "$USE_FUSE" == auto ]] && USE_FUSE=1
if [[ "$USE_FUSE" -eq 1 && ! -x /usr/bin/fuse-overlayfs ]]; then
    die "/usr/bin/fuse-overlayfs is missing. Install the fuse-overlayfs package
       (from this host's RHEL repos or install media), then re-run. Or re-run
       with --no-fuse-overlayfs, but then each user's first start makes them a
       private multi-GB copy of the image (see INSTALL.md)."
fi

# ---------------------------------------------------------------------------
if [[ "$CHECKSUMS" -eq 1 ]]; then
    step "Checking the package against SHA256SUMS"
    (cd "$HERE" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch; copy the package again"
    echo "OK"
fi

# ---------------------------------------------------------------------------
# A store made by an older installer has no override_stat xattrs (users see
# its files as owned by nobody, so sudo fails). A layer already in the store
# is reused as it is, so loading again wouldn't fix it: empty the store first.
if [[ "$USE_FUSE" -eq 1 && -d "$STORE/overlay" ]] && ! "$PY" - "$STORE" <<'EOF_PY'
import glob, os, sys
files = glob.glob(os.path.join(sys.argv[1], "overlay", "*", "diff", "usr", "bin", "sudo"))
sys.exit(0 if all("user.containers.override_stat" in os.listxattr(f, follow_symlinks=False)
                  for f in files) else 1)
EOF_PY
then
    step "Emptying $STORE: it was made without force_mask (files show as nobody)"
    store_in_use && die "a container is using $STORE right now; try again when nobody is in one"
    store_podman system reset --force
    echo "Emptied; the image is loaded again below."
fi

# ---------------------------------------------------------------------------
step "Loading $IMAGE_NAME into $STORE (takes a few minutes)"
mkdir -p "$STORE"
chmod 755 "$STORE"
set_load_tmpdir "$IMAGE_TAR"
store_podman load -i "$IMAGE_TAR"
# Before the repair below, so that whatever happens there, users can read it.
chmod -R a+rX "$STORE"
echo "Made $STORE world-readable."

# force_mask's xattrs, as podman 4.x (RHEL 8) writes them, don't work: it
# drops the setuid, setgid and sticky bits (sudo 4111 is recorded as 0111,
# /tmp 1777 as 0777), and it puts no xattr on each layer's diff directory
# itself, which is the one fuse-overlayfs checks to decide whether to read the
# layer's xattrs at all. So users saw every file as 0755, /tmp unwritable and
# sudo broken. Rewrite them from the real owners and modes in the image's
# layer tars (matched to the store's layers by diff digest). Also repairs
# layers an earlier install loaded; changes nothing where they're right.
# A failure here doesn't stop the install: the store still works, only sudo
# and /tmp inside containers don't (rhel9-dev --check says so).
if [[ "$USE_FUSE" -eq 1 ]]; then
    step "Repairing the store's owner/mode xattrs (podman 4.x drops setuid bits)"
    "$PY" - "$STORE" "$IMAGE_TAR" <<'EOF_PY' || REPAIR_FAILED=1
import gzip, hashlib, json, os, stat, sys, tarfile

XATTR = "user.containers.override_stat"
store, archive = sys.argv[1], sys.argv[2]


class HashingReader:
    def __init__(self, f):
        self.f, self.h = f, hashlib.sha256()

    def read(self, n=-1):
        b = self.f.read(n)
        self.h.update(b)
        return b

    def drain(self):
        while self.read(1 << 20):
            pass
        return "sha256:" + self.h.hexdigest()


class Prefixed:
    """Gives back bytes already read from f, then the rest of f."""
    def __init__(self, prefix, f):
        self.p, self.f = prefix, f

    def read(self, n=-1):
        if not self.p:
            return self.f.read(n)
        if n is None or n < 0:
            b, self.p = self.p + self.f.read(), b""
            return b
        b, self.p = self.p[:n], self.p[n:]
        return b + self.f.read(n - len(b)) if len(b) < n else b


def read_layer(stream):
    """{path in layer: (uid, gid, mode)} and the digests it may be known by
    in the store (uncompressed, and as stored in the archive). Layers can be
    plain or gzip-compressed tars (docker-archive, OCI layout, docker 25+)."""
    raw = HashingReader(stream)
    head = raw.read(4)
    src = Prefixed(head, raw)
    if head[:2] == b"\x1f\x8b":
        src = gzip.GzipFile(fileobj=src, mode="rb")
    elif head == b"\x28\xb5\x2f\xfd":
        sys.stderr.write("warning: a zstd-compressed layer, which this can't read; skipped\n")
        raw.drain()
        return None, ()
    plain = HashingReader(src)
    entries = {}
    with tarfile.open(fileobj=plain, mode="r|") as t:
        for m in t:
            name = os.path.normpath(m.name).lstrip("/")
            name = "" if name == "." else name
            if os.path.basename(name).startswith(".wh.") or m.issym():
                continue
            if m.islnk():               # same inode as its target: same values
                target = os.path.normpath(m.linkname).lstrip("/")
                if target in entries:
                    entries[name] = entries[target]
                continue
            entries[name] = (m.uid, m.gid, m.mode & 0o7777)
    return entries, (plain.drain(), raw.drain())


def fix_layer(diff, entries):
    fixed = 0
    for dirpath, _, filenames in os.walk(diff):
        for path in [dirpath] + [os.path.join(dirpath, n) for n in filenames]:
            st = os.lstat(path)
            if not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
                continue                # symlinks etc. can't have user xattrs
            rel = os.path.relpath(path, diff)
            # Not in the tar (e.g. the layer root): root-owned, mode as on disk.
            uid, gid, mode = entries.get("" if rel == "." else rel,
                                         (0, 0, stat.S_IMODE(st.st_mode)))
            try:
                old = os.getxattr(path, XATTR, follow_symlinks=False).decode()
            except OSError:
                old = ""
            # Keep any fields after uid:gid:mode (newer podman adds more).
            new = ":".join([str(uid), str(gid), "0%o" % mode] + old.split(":")[3:])
            if new != old:
                os.setxattr(path, XATTR, new.encode(), follow_symlinks=False)
                fixed += 1
    return fixed


with open(os.path.join(store, "overlay-layers", "layers.json")) as f:
    layer_ids = {}
    for l in json.load(f):
        for key in ("diff-digest", "compressed-diff-digest"):
            if l.get(key):
                layer_ids[l[key]] = l["id"]
done, tried = set(), 0
fixed = 0
opener = gzip.open if archive.endswith(".gz") else open
with opener(archive, "rb") as raw, tarfile.open(fileobj=raw, mode="r|") as outer:
    for m in outer:
        # Every file could be a layer, whatever it's called (<id>/layer.tar,
        # <digest>.tar, blobs/sha256/<digest>); configs and manifests aren't
        # tars and are skipped.
        if not m.isfile():
            continue
        try:
            entries, digests = read_layer(outer.extractfile(m))
        except (tarfile.TarError, OSError, EOFError):
            continue
        if entries is None:
            continue
        tried += 1
        lid = next((layer_ids[d] for d in digests if d in layer_ids), None)
        if lid is None or lid in done:
            continue
        fixed += fix_layer(os.path.join(store, "overlay", lid, "diff"), entries)
        done.add(lid)
layers = len(done)
if layers == 0:
    sys.exit("found %d layer tars in %s, but none of them in %s" % (tried, archive, store))
print("Checked %d layers; fixed %d xattrs." % (layers, fixed))
EOF_PY
    if [[ "${REPAIR_FAILED:-0}" -eq 1 ]]; then
        echo "warning: couldn't repair the xattrs in $STORE (see above). The install" >&2
        echo "  goes on, but on RHEL 8 sudo and /tmp won't work inside containers." >&2
    fi
fi

WANT_ID="$(sed -n 's/^image: *[^ ]* \(sha256:\)\{0,1\}\([0-9a-f]*\).*/\2/p' "$HERE/PACKAGE-INFO" 2>/dev/null || true)"
GOT_ID="$(store_podman image inspect "$IMAGE_NAME" --format '{{.Id}}')"
if [[ -n "$WANT_ID" && "$GOT_ID" != "$WANT_ID"* ]]; then
    echo "warning: loaded image $GOT_ID, but PACKAGE-INFO says $WANT_ID" >&2
fi

# ---------------------------------------------------------------------------
step "SELinux labels"
if ! command -v selinuxenabled >/dev/null || ! selinuxenabled; then
    echo "SELinux is off; nothing to do."
elif ! command -v semanage >/dev/null; then
    echo "warning: no semanage (policycoreutils-python-utils), so $STORE keeps its" >&2
    echo "  default labels. rhel9-dev's run.sh doesn't need them, but other containers" >&2
    echo "  run from this store with SELinux confinement may be denied. Later, run:" >&2
    echo "  semanage fcontext -a -e /var/lib/containers/storage $STORE && restorecon -R $STORE" >&2
else
    if ! semanage fcontext -l -C | grep -q "^$STORE = /var/lib/containers/storage\$"; then
        semanage fcontext -a -e /var/lib/containers/storage "$STORE"
    fi
    restorecon -R "$STORE"
    echo "$STORE is labelled like /var/lib/containers/storage."
fi

# ---------------------------------------------------------------------------
step "Configuring $STORAGE_CONF"
if [[ ! -e "$STORAGE_CONF" ]]; then
    [[ -f /usr/share/containers/storage.conf ]] \
        || die "neither $STORAGE_CONF nor /usr/share/containers/storage.conf exists"
    mkdir -p "$(dirname "$STORAGE_CONF")"
    cp /usr/share/containers/storage.conf "$STORAGE_CONF"
    echo "Created it from /usr/share/containers/storage.conf."
fi
NEW_CONF="$(mktemp)"
trap 'rm -f "$NEW_CONF"' EXIT
"$PY" - "$STORAGE_CONF" "$STORE" "$USE_FUSE" >"$NEW_CONF" <<'EOF_PY'
# Line-based edit, so storage.conf's comments and layout survive. Handles a
# one-line or multi-line additionalimagestores array.
import re, sys
path, store, use_fuse = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
lines = open(path).read().split("\n")
header = re.compile(r"^\s*\[([^\]]+)\]\s*(#.*)?$")

def section_bounds(name):
    start = None
    for i, l in enumerate(lines):
        m = header.match(l)
        if m and start is None and m.group(1).strip() == name:
            start = i
        elif m and start is not None:
            return start, i
    return (start, len(lines)) if start is not None else (None, None)

def ensure_section(name):
    s, e = section_bounds(name)
    if s is None:
        if lines and lines[-1] != "":
            lines.append("")
        lines.extend(["[%s]" % name, ""])
        s, e = section_bounds(name)
    return s, e

def find_key(key, s, e):
    for i in range(s + 1, e):
        if re.match(r"^\s*%s\s*=" % key, lines[i]):
            return i
    return None

# additionalimagestores
s, e = ensure_section("storage.options")
i = find_key("additionalimagestores", s, e)
if i is None:
    lines[s + 1:s + 1] = ["additionalimagestores = [", '  "%s",' % store, "]"]
else:
    j = i
    text = lines[i].split("=", 1)[1]
    while text.count("[") > text.count("]") and j + 1 < len(lines):
        j += 1
        text += "\n" + lines[j]
    stores = [a or b for a, b in re.findall(r'"([^"]*)"|\'([^\']*)\'', re.sub(r"#.*", "", text))]
    if store.rstrip("/") not in [x.rstrip("/") for x in stores]:
        stores.append(store)
        lines[i:j + 1] = ["additionalimagestores = ["] + ['  "%s",' % x for x in stores] + ["]"]

# mount_program
if use_fuse:
    ensure_section("storage.options.overlay")
    # Only mount_program: users' fuse-overlayfs reads the store's
    # override_stat xattrs without force_mask set on their side, and podman
    # before 4.0 (RHEL 8.5 and older) rejects a force_mask it doesn't know.
    for key, want in (("mount_program", 'mount_program = "/usr/bin/fuse-overlayfs"'),):
        s, e = section_bounds("storage.options.overlay")
        i = find_key(key, s, e)
        if i is None:
            lines[s + 1:s + 1] = [want]
        elif lines[i].strip() != want:
            lines[i] = want

sys.stdout.write("\n".join(lines))
EOF_PY
if cmp -s "$STORAGE_CONF" "$NEW_CONF"; then
    echo "Already set up; unchanged."
else
    BACKUP="$STORAGE_CONF.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$STORAGE_CONF" "$BACKUP"
    diff -u "$BACKUP" "$NEW_CONF" || true
    cat "$NEW_CONF" >"$STORAGE_CONF"
    echo "Changed; the old file is $BACKUP."
fi
podman images >/dev/null 2>&1 \
    || die "podman can't read $STORAGE_CONF now; restore it from the backup above"

# ---------------------------------------------------------------------------
step "Installing scripts to $PREFIX"
mkdir -p "$PREFIX"
for f in run.sh engine.sh install-shared.sh; do
    install -m 755 "$HERE/$f" "$PREFIX/$f"
done
for f in README.md INSTALL.md PACKAGE-INFO OMP-BUILD-INFO; do
    [[ -f "$HERE/$f" ]] && install -m 644 "$HERE/$f" "$PREFIX/$f"
done
mkdir -p "$BINDIR"
ln -sfn "$PREFIX/run.sh" "$BINDIR/rhel9-dev"
echo "Installed. Users start it with: rhel9-dev"

# ---------------------------------------------------------------------------
step "Old images in $STORE"
OLD="$(store_podman images --filter dangling=true --format '{{.ID}}  created {{.CreatedSince}}')"
if [[ -z "$OLD" ]]; then
    echo "None."
else
    echo "$OLD"
    echo "Replaced by this install, and still used by any container started before"
    echo "it. Once nobody is in a rhel9-dev container, delete them with:"
    echo "    $PREFIX/install-shared.sh --prune$( [[ "$STORE" != /var/lib/shared-images ]] && echo " --store $STORE")"
fi

# ---------------------------------------------------------------------------
step "Users whose own storage.conf would hide the shared store"
found=0
while IFS=: read -r user _ uid _ _ home _; do
    [[ "$uid" -ge 1000 && "$uid" -lt 60000 ]] || continue
    conf="$home/.config/containers/storage.conf"
    [[ -f "$conf" ]] || continue
    if ! grep -qF "$STORE" "$conf"; then
        echo "  $user: $conf replaces the system file; add $STORE to its"
        echo "    additionalimagestores$( [[ "$USE_FUSE" -eq 1 ]] && echo ', and the same mount_program')"
        found=1
    fi
done < <(getent passwd)
[[ "$found" -eq 1 ]] || echo "None found (only local accounts that this host can list were checked)."

cat <<EOF

Done. Each user should now run, as themselves (not sudo):

    rhel9-dev --check

which says what to fix, if anything (e.g. a private copy of the image they
loaded before, hiding the shared one). Then they use \`rhel9-dev\` as usual
(see $PREFIX/README.md).
EOF
