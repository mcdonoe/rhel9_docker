# rhel9-dev

A persistent RHEL9 (UBI9) development image: git, cmake, make, autotools,
gcc-toolset 12 & 14, Python 3.11 & 3.12, OpenJDK 21 + Ant, uv, vim, btop,
plus an opt-in dnsmasq DHCP server (see below).

## Build

```
./build.sh                # free UBI + EPEL repos only (covers everything below)
./build.sh --subscription # also registers with subscription-manager during
                           # the build (prompts for Red Hat credentials once,
                           # caches them in ./.secrets which is gitignored)
```

## Run

```
docker run -it --rm -v "$HOME/GIT_REPOS:/workspace" rhel9-dev bash
```

Container starts as root (so ad-hoc `dnf install` works like the stock
`redhat/ubi9` image). A passwordless-sudo `mcdonoe` user also exists (UID/GID
1000, matching your host user, so bind-mounted files keep sane ownership)
for attaching as non-root, e.g. via VS Code's Dev Containers extension
("Attach to Running Container") or `docker exec -u mcdonoe -it <container> bash`.

## Notes

- **gcc**: gcc-toolset-12 is active by default in every interactive shell.
  Switch to 14 for the current shell with:
  ```
  source /opt/rh/gcc-toolset-14/enable
  ```
- **Python**: `python3.11` and `python3.12` are both installed as explicit
  commands (no `python3` alias change) — RHEL's own tooling depends on the
  system Python, so it's left alone. Use `python3.11 -m venv` / `python3.12 -m venv`,
  or `uv` for project-level dependency management.
- **Ant/Java**: Ant isn't packaged for RHEL9 or EPEL9 at all, so it's
  installed from the official Apache tarball (checksum-pinned in the
  Dockerfile) against OpenJDK 21.
- **VS Code**: nothing VS Code-specific is installed in the image — the
  intended workflow is installing VS Code + the "Dev Containers" extension
  on the Ubuntu host and attaching to the running container, which gets you
  full IntelliSense/extensions without baking anything into the image.
- Rebuilding after adding a package: edit the `dnf install` list in
  `Dockerfile`, then `./build.sh` again.

## DHCP server (dnsmasq)

`dnsmasq` is installed in the image but not started by default — the
container's normal `CMD` is still an interactive `bash` shell. DHCP is
opt-in via how you invoke `docker run`.

**Setup:**

```
cp dnsmasq/dhcp.conf.example dnsmasq/dhcp.conf
```

Edit `dnsmasq/dhcp.conf` (gitignored, network-specific): set `interface` to
the host NIC you want to serve DHCP on, and adjust the `dhcp-range` /
`dhcp-option` lines to match that network's subnet. This box has several
physical interfaces (`ip addr` — `eno1`, `eno2`, `ens1f0`, etc.); pick a
dedicated/isolated one, not your main LAN uplink.

**Run:**

```
./run-dhcp.sh
```

This runs the container with `--network host` (required — DHCP needs raw
L2 broadcast access to the physical interface; Docker's default bridge
network NATs traffic and won't pass broadcast requests through) plus
`NET_ADMIN`/`NET_RAW`, and starts `dnsmasq` in the foreground instead of a
shell. `docker logs` (or the foreground output) shows every DHCP
transaction.

**Before running this against a real network:** confirm nothing else on
that segment is already handing out DHCP leases. Two DHCP servers
answering the same broadcast domain race each other and can break
connectivity for every device on it, not just this container.
`dhcp.conf.example` sets `dhcp-authoritative`, which assumes this is the
only DHCP server on the segment.

## Expanding the image

**Add a package that's in an already-enabled repo** (most things — the base
image ships UBI AppStream, BaseOS and CodeReady Builder; the Dockerfile adds
EPEL). Add the name to the `dnf install -y \` list in the `Dockerfile`
(alphabetical-ish within its comment group, doesn't matter functionally),
then:

```
./build.sh
```

Docker's layer cache means this only re-runs from that `RUN dnf install`
layer down — the base image pull and earlier layers are reused, so it's
fast. Check whether a package exists first with a throwaway container so you
don't find out mid-build:

```
docker run --rm redhat/ubi9 bash -c 'dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && dnf list --available "<name>*"'
```

**Add a package from a repo that isn't enabled yet** (e.g. something
subscription-gated beyond UBI/CRB, or a third-party repo like Microsoft's
for `code`/`azure-cli`, or Docker's own repo). Add the repo setup as its own
`RUN` step before the main install, e.g.:

```dockerfile
RUN rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
    dnf install -y 'dnf-command(config-manager)' && \
    dnf config-manager --add-repo https://packages.microsoft.com/yumrepos/vscode
```

then add the package name to the main `dnf install` list (or a new one) and
rebuild.

**Add something not packaged for RHEL9 at all** (like Ant or uv here) —
follow that same pattern: a dedicated `RUN` block that `curl`s a release
tarball or installer script, verifies a checksum if one's published, and
drops the result under `/opt` or `/usr/local/bin`. Keep the checksum pin —
it's what makes the build fail loudly instead of silently drifting if
upstream ever swaps the file.

**Add a Python tool globally** — prefer `uv tool install <name>` or a venv
inside your own repos over baking it into the image; the image is meant to
stay a base toolchain, not accumulate every project's dependencies.

**Sanity-check without a full rebuild** — `docker run -it --rm redhat/ubi9
bash` and try the `dnf install` by hand first; once it works, copy the
package name(s) into the Dockerfile. This is exactly how the current package
list was chosen.
