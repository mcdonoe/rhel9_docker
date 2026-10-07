#!/usr/bin/env bash
# Image entrypoint: runs the command as the host user who started the
# container, so files they touch through a bind mount stay theirs.
#
# run.sh passes HOST_UID, HOST_GID, HOST_USER and HOST_HOME. With those set
# (and the container started as root), this creates a matching user with
# home HOST_HOME (the same path as on the host, so paths OMP records in the
# bind-mounted ~/.omp mean the same thing on both sides) and passwordless
# sudo, then drops to it. Without them the command runs as root, as in the
# stock redhat/ubi9 image; that keeps `docker run -it rhel9-dev bash`,
# run.sh --root and run-dhcp.sh unchanged.
#
# Only the numbers matter for file access through a bind mount. The name is a
# convenience: if HOST_USER is already taken by a different UID, the user is
# called u$HOST_UID instead.
#
# HOST_WORKSPACE, if set, is where run.sh mounted the repo base directory (its
# host path); /workspace becomes a symlink to it.
set -euo pipefail

if [[ -n "${HOST_WORKSPACE:-}" && "$(id -u)" -eq 0 && ! -L /workspace ]] \
        && rmdir /workspace 2>/dev/null; then
    ln -s "$HOST_WORKSPACE" /workspace
fi

if [[ -z "${HOST_UID:-}" || "$(id -u)" -ne 0 ]]; then
    exec "$@"
fi
HOST_GID="${HOST_GID:-$HOST_UID}"
HOST_USER="${HOST_USER:-u$HOST_UID}"
HOST_HOME="${HOST_HOME:-/home/$HOST_USER}"
if ! [[ "$HOST_UID" =~ ^[0-9]+$ && "$HOST_GID" =~ ^[0-9]+$ ]]; then
    echo "entrypoint: HOST_UID and HOST_GID must be numeric" >&2
    exit 1
fi
if ! [[ "$HOST_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]]; then
    echo "entrypoint: HOST_USER '$HOST_USER' is not a valid user name" >&2
    exit 1
fi
if [[ "$HOST_HOME" != /?* || "$HOST_HOME" == *..* ]]; then
    echo "entrypoint: HOST_HOME '$HOST_HOME' must be an absolute path other than /" >&2
    exit 1
fi
[[ "$HOST_UID" -ne 0 ]] || exec "$@"
home="$HOST_HOME"

# Reuse a group that already has this GID (e.g. 100 "users"), else make one.
if ! getent group "$HOST_GID" >/dev/null; then
    group="$HOST_USER"
    getent group "$group" >/dev/null && group="g$HOST_GID"
    groupadd -g "$HOST_GID" "$group"
fi

# podman --userns=keep-id has already added a passwd entry for the host user;
# reuse it, pointed at our home. Otherwise create one.
if name="$(getent passwd "$HOST_UID" | cut -d: -f1)" && [[ -n "$name" ]]; then
    usermod -d "$home" "$name" >/dev/null 2>&1 || true
else
    name="$HOST_USER"
    getent passwd "$name" >/dev/null && name="u$HOST_UID"
    useradd -M -u "$HOST_UID" -g "$HOST_GID" -d "$home" -s /bin/bash "$name"
fi
echo "$name ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-host-user
chmod 440 /etc/sudoers.d/90-host-user

# The engine creates the home directory and the mount points of run.sh's
# volumes as root, and a new volume starts out root-owned. Hand back exactly
# those: never search the home directory, because host directories are
# bind-mounted under it and their ownership is the host's business.
mkdir -p "$home"
cp -rn /etc/skel/. "$home/"
for d in "$home" "$home/go" "$home/.cache" "$home/.cache/go-build"; do
    if [[ -d "$d" && "$(stat -c %u "$d")" -eq 0 ]]; then
        chown "$HOST_UID:$HOST_GID" "$d"
    fi
done

exec setpriv --reuid="$HOST_UID" --regid="$HOST_GID" --init-groups \
    env HOME="$home" USER="$name" LOGNAME="$name" "$@"
