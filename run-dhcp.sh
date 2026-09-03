#!/usr/bin/env bash
# Runs rhel9-dev as a DHCP server (dnsmasq) instead of an interactive shell.
#
#   ./run-dhcp.sh              serve in the foreground (Ctrl-C to stop)
#   ./run-dhcp.sh --detach     serve in the background and return your prompt
#   ./run-dhcp.sh --shell      open a shell inside the running server
#   ./run-dhcp.sh --leases     print the current lease table
#   ./run-dhcp.sh --stop       stop a running server
#
# Requires:
#   - dnsmasq/dhcp.conf present and edited for your network (copy it from
#     dnsmasq/dhcp.conf.example first — see that file's comments)
#   - --network host, since DHCP needs direct L2 broadcast access to the
#     physical interface named in dhcp.conf; Docker's default bridge
#     network NATs traffic and won't pass broadcast DHCP requests through
#   - NET_ADMIN/NET_RAW, since dnsmasq sends DHCP replies from privileged
#     raw sockets
#   - a ROOTFUL engine. Rootless podman grants --cap-add capabilities only
#     inside its user namespace, but the host network namespace is owned by
#     the initial one, so dnsmasq gets EPERM on its AF_PACKET socket and
#     cannot bind port 67 (< net.ipv4.ip_unprivileged_port_start). The guard
#     below catches this early instead of letting it fail cryptically.
#
# This puts a live DHCP responder on whatever interface dhcp.conf names.
# Only run this against a network segment you're sure has no other DHCP
# server (see dhcp.conf.example for why).
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
CONTAINER_NAME="${CONTAINER_NAME:-rhel9-dhcp}"
CONF="$(dirname "$0")/dnsmasq/dhcp.conf"

# Sets ENGINE and ENGINE_ROOTLESS
source "$(dirname "$0")/engine.sh"

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \?//'
}

ACTION=serve
FOREGROUND=1
case "${1:-}" in
    "")             ACTION=serve ;;
    -d|--detach)    ACTION=serve; FOREGROUND=0 ;;
    --shell)        ACTION=shell ;;
    --leases)       ACTION=leases ;;
    --stop)         ACTION=stop ;;
    -h|--help)      usage; exit 0 ;;
    *)
        echo "error: unknown argument '$1'" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac

# Every action here targets a container that only a rootful engine can run, so
# the guard applies to all of them — including --shell, which would otherwise
# look in your rootless store and report "not running" for a server started
# under sudo.
if [[ "$ENGINE_ROOTLESS" -eq 1 ]]; then
    cat >&2 <<MSG
error: $ENGINE is running rootless, which cannot serve DHCP.

A rootless container gets --cap-add capabilities only inside its own user
namespace. The host network namespace is owned by the initial namespace, so
dnsmasq is denied its AF_PACKET raw socket and cannot bind port 67.

Re-run this as root. Note that rootful podman keeps a SEPARATE image store
from your rootless one, so the image has to be built there too:

    sudo ./build.sh && sudo ./run-dhcp.sh

This is not needed with a rootful Docker daemon (the usual Docker setup),
where the plain ./run-dhcp.sh works as-is.
MSG
    exit 1
fi

is_running() {
    [[ "$("$ENGINE" container inspect --format '{{.State.Running}}' \
          "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

require_running() {
    if ! is_running; then
        echo "error: no DHCP container named '$CONTAINER_NAME' is running." >&2
        echo "Start one with:  ./run-dhcp.sh --detach" >&2
        exit 1
    fi
}

case "$ACTION" in
shell)
    require_running
    # --network host means this shell shares the host's network namespace, so
    # `ssh user@<leased-ip>` reaches clients exactly as it would from the host.
    exec "$ENGINE" exec -it "$CONTAINER_NAME" bash
    ;;

leases)
    require_running
    # Leases are ephemeral: the file lives only inside the container, so this
    # has to read it there. dnsmasq's format is
    #   <expiry-epoch> <mac> <ip> <hostname|*> <client-id>
    "$ENGINE" exec -i "$CONTAINER_NAME" bash -s <<'REMOTE'
f=/var/lib/dnsmasq/dnsmasq.leases
[[ -s $f ]] || { echo "No leases handed out yet."; exit 0; }
printf '%-19s  %-17s  %-15s  %s\n' 'LEASE EXPIRES' 'MAC' 'IP' 'HOSTNAME'
gawk '{ printf "%-19s  %-17s  %-15s  %s\n", \
        strftime("%Y-%m-%d %H:%M:%S", $1), $2, $3, ($4 == "*" ? "-" : $4) }' "$f"
REMOTE
    ;;

stop)
    require_running
    "$ENGINE" stop "$CONTAINER_NAME" >/dev/null
    echo "Stopped $CONTAINER_NAME."
    ;;

serve)
    if [[ ! -f "$CONF" ]]; then
        echo "Missing $CONF" >&2
        echo "Copy dnsmasq/dhcp.conf.example to dnsmasq/dhcp.conf and edit it for your network first." >&2
        exit 1
    fi

    if is_running; then
        echo "error: '$CONTAINER_NAME' is already serving DHCP." >&2
        echo "Attach with:  ./run-dhcp.sh --shell" >&2
        echo "Stop it with: ./run-dhcp.sh --stop" >&2
        exit 1
    fi

    # ":z" relabels the config to container_file_t so SELinux lets the
    # container read it; without it podman on an enforcing host fails with a
    # bare "cannot read /etc/dnsmasq.d/dhcp.conf: Permission denied". Docker
    # accepts the suffix and ignores it on hosts without SELinux.
    #
    # --rm on both paths so a stopped container never blocks the next start.
    run_args=(
        --name "$CONTAINER_NAME"
        --rm
        --network host
        --cap-add=NET_ADMIN --cap-add=NET_RAW
        -v "$CONF:/etc/dnsmasq.d/dhcp.conf:ro,z"
    )
    # --network host makes the container inherit the HOST's hostname, so a root
    # shell inside it renders as [root@<your workstation> /] — indistinguishable
    # from a root shell on the metal. Name it after the container instead.
    # Podman only: Docker rejects --hostname alongside --net=host with
    # "conflicting options: hostname and the network mode".
    if [[ "$ENGINE_IS_PODMAN" -eq 1 ]]; then
        run_args+=(--hostname "$CONTAINER_NAME")
    fi

    dnsmasq_args=(dnsmasq --no-daemon --conf-file=/etc/dnsmasq.d/dhcp.conf)

    if [[ "$FOREGROUND" -eq 1 ]]; then
        exec "$ENGINE" run -it "${run_args[@]}" "$IMAGE_NAME" "${dnsmasq_args[@]}"
    fi

    "$ENGINE" run -d "${run_args[@]}" "$IMAGE_NAME" "${dnsmasq_args[@]}" >/dev/null
    cat <<MSG
Serving DHCP in the background as '$CONTAINER_NAME'.

  ./run-dhcp.sh --leases    see what has been handed out
  ./run-dhcp.sh --shell     shell inside it (ssh out to clients from there)
  ./run-dhcp.sh --stop      stop it
  $ENGINE logs -f $CONTAINER_NAME   follow DHCP transactions
MSG
    ;;
esac
