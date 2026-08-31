#!/usr/bin/env bash
# Runs rhel9-dev as a DHCP server (dnsmasq) instead of an interactive shell.
#
# Requires:
#   - dnsmasq/dhcp.conf present and edited for your network (copy it from
#     dnsmasq/dhcp.conf.example first — see that file's comments)
#   - --network host, since DHCP needs direct L2 broadcast access to the
#     physical interface named in dhcp.conf; Docker's default bridge
#     network NATs traffic and won't pass broadcast DHCP requests through
#   - NET_ADMIN/NET_RAW, since dnsmasq sends DHCP replies from privileged
#     raw sockets
#
# This puts a live DHCP responder on whatever interface dhcp.conf names.
# Only run this against a network segment you're sure has no other DHCP
# server (see dhcp.conf.example for why).
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-rhel9-dev}"
CONF="$(dirname "$0")/dnsmasq/dhcp.conf"

if [[ ! -f "$CONF" ]]; then
    echo "Missing $CONF" >&2
    echo "Copy dnsmasq/dhcp.conf.example to dnsmasq/dhcp.conf and edit it for your network first." >&2
    exit 1
fi

docker run -it --rm \
    --network host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -v "$CONF:/etc/dnsmasq.d/dhcp.conf:ro" \
    "$IMAGE_NAME" \
    dnsmasq --no-daemon --conf-file=/etc/dnsmasq.d/dhcp.conf
