# Shared container-engine detection. Sourced by build.sh, run.sh and run-dhcp.sh;
# not executable on its own. Sets:
#
#   ENGINE           docker | podman   (override with ENGINE=... in the env)
#   ENGINE_ROOTLESS  1 if that engine runs rootless, else 0
#   ENGINE_IS_PODMAN 1 if that engine is really podman, else 0
#
# On RHEL, `docker` is usually the podman-docker shim wrapping podman, while a
# podman-only box may have no `docker` binary at all — so don't assume either
# is present, and don't assume `docker` means Docker.

ENGINE="${ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
    if command -v docker >/dev/null 2>&1; then
        ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then
        ENGINE=podman
    else
        echo "error: neither docker nor podman found on PATH" >&2
        exit 1
    fi
fi

# Rootless engines can't hand a container real capabilities over the host
# network namespace, which run-dhcp.sh needs. The two engines report this
# under different keys, and a template referencing a missing key fails as a
# whole, so probe them separately.
# Detect podman by what the binary REPORTS, not what it is called: the
# podman-docker shim answers to `docker` but is podman underneath, so testing
# "$ENGINE" = podman would miss it on every RHEL box.
ENGINE_IS_PODMAN=0
if "$ENGINE" --version 2>/dev/null | grep -qi podman; then
    ENGINE_IS_PODMAN=1
fi

ENGINE_ROOTLESS=0
if "$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -qix true; then
    ENGINE_ROOTLESS=1          # podman, including via the podman-docker shim
elif "$ENGINE" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    ENGINE_ROOTLESS=1          # rootless docker
fi
