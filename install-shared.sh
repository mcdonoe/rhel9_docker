#!/usr/bin/env bash
# Installs a rhel9-dev package on this machine for every user: loads the
# image into a root-owned, read-only podman image store that every user's
# podman reads from (an "additional image store"), and installs the scripts
# that run it. Needs no network, so it works on airgapped hosts.
#
#   sudo ./install-shared.sh [options]     from inside the unpacked package
#   sudo /opt/rhel9-dev/install-shared.sh --prune [--store DIR]
#                     after an update, once nobody is in a container: delete
#                     the image the update replaced, which is still in the
#                     store with no name. Refuses while it sees a container
#                     using the store. Needs no package.
#
#   --store DIR       the shared image store   (default /var/lib/shared-images)
#   --prefix DIR      where the scripts go     (default /opt/rhel9-dev)
#   --bindir DIR      where the `rhel9-dev` command goes (default /usr/local/bin)
#   --no-fuse-overlayfs
#                     don't set mount_program in storage.conf (see below)
#   --skip-checksums  don't check SHA256SUMS first
#
# Safe to re-run: that's also how you update to a newer package. Each step
# says what it changed. What it does:
#   1. checks the package against SHA256SUMS
#   2. loads the image into the store and makes the store world-readable
#      (rootless podman reads it as each user's own UID, and the container's
#      entrypoint needs to read /etc/shadow from it to create your user)
#   3. labels the store for SELinux like podman's own storage
#   4. adds the store to /etc/containers/storage.conf's
#      additionalimagestores, and on kernels newer than RHEL8's sets
#      mount_program = fuse-overlayfs, which lets rootless podman use the
#      store's root-owned files without making each user a private copy of
#      the image. Backs storage.conf up first.
#   5. installs the scripts to PREFIX and links BINDIR/rhel9-dev to run.sh
#   6. lists users whose own ~/.config/containers/storage.conf would hide
#      the shared store from them
#
# Afterwards each user checks their setup with `rhel9-dev --check`.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
STORE=/var/lib/shared-images
PREFIX=/opt/rhel9-dev
BINDIR=/usr/local/bin
STORAGE_CONF=/etc/containers/storage.conf
USE_FUSE=auto
PRUNE=0
CHECKSUMS=1

usage() { sed -n '2,38p' "$0" | sed 's/^# \?//'; }
die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --store)             STORE="${2:?--store needs a directory}"; shift 2 ;;
        --prefix)            PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --bindir)            BINDIR="${2:?--bindir needs a directory}"; shift 2 ;;
        --no-fuse-overlayfs) USE_FUSE=0; shift ;;
        --prune)             PRUNE=1; shift ;;
        --skip-checksums)    CHECKSUMS=0; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   die "unknown option: $1 (see --help)" ;;
    esac
done
[[ "$STORE" == /?* && "$PREFIX" == /?* && "$BINDIR" == /?* ]] \
    || die "--store, --prefix and --bindir must be absolute paths"
STORE="${STORE%/}"

[[ "$(id -u)" -eq 0 ]] || die "run this as root (sudo $0)"
command -v podman >/dev/null || die "podman is not installed (dnf install podman)"

# Podman for the store itself, ignoring storage.conf's options: the store is
# also listed there as an additional store, and opening one store both ways
# at once can deadlock on its lock files.
store_podman() {
    podman --root "$STORE" --runroot /run/rhel9-dev-shared-store \
        --storage-driver overlay --storage-opt "" "$@"
}

if [[ "$PRUNE" -eq 1 ]]; then
    [[ -d "$STORE/overlay-images" ]] || die "$STORE is not an image store"
    OLD="$(store_podman images --filter dangling=true --format '{{.ID}}  created {{.CreatedSince}}')"
    [[ -n "$OLD" ]] || { echo "Nothing to prune in $STORE."; exit 0; }
    # Rootless containers live in each user's own storage, so the shared store
    # can't tell that they use its layers. Look for mounts of it instead.
    if grep -qF "$STORE/" <<<"$(pgrep -af fuse-overlayfs || true)" \
            || grep -qF "$STORE/overlay" /proc/[0-9]*/mountinfo 2>/dev/null; then
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

# Native overlay in a user namespace needs kernel 5.13+; RHEL8's 4.18 falls
# back to fuse-overlayfs on its own, so only newer kernels need telling.
if [[ "$USE_FUSE" == auto ]]; then
    IFS=. read -r kmaj kmin _ <<<"$(uname -r)"
    if (( kmaj > 5 || (kmaj == 5 && kmin >= 13) )); then USE_FUSE=1; else USE_FUSE=0; fi
fi
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
step "Loading $IMAGE_NAME into $STORE (takes a few minutes)"
mkdir -p "$STORE"
chmod 755 "$STORE"
store_podman load -i "$IMAGE_TAR"
chmod -R a+rX "$STORE"
echo "Made $STORE world-readable."

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
    s, e = ensure_section("storage.options.overlay")
    i = find_key("mount_program", s, e)
    want = 'mount_program = "/usr/bin/fuse-overlayfs"'
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
