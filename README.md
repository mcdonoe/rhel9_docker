# rhel9-dev

A persistent RHEL9 (UBI9) development image: git, cmake, make, autotools,
gcc-toolset 12, 14 & 15, Python 3.11, 3.12 & 3.14, Go (+ gopls, delve),
OpenJDK 21 + Ant, uv, vim, btop,
plus an opt-in dnsmasq DHCP server (see below).

## Repo layout

| File | Purpose |
| --- | --- |
| `Dockerfile` | The image definition |
| `build.sh` | Builds it, optionally registering with Red Hat (`--subscription`) |
| `run.sh` | Starts a dev shell (or one command) with the flags omp_distro's build needs |
| `run-dhcp.sh` | Runs the image as a DHCP server, and inspects a running one |
| `engine.sh` | Shared docker/podman detection, sourced by the scripts above |
| `dnsmasq/dhcp.conf.example` | Template to copy to `dhcp.conf` (gitignored) |
| `.secrets/` | Cached Red Hat credentials (gitignored, created on demand) |

## Build

```
./build.sh                # free UBI + EPEL repos only (covers everything below)
./build.sh --subscription # also registers with subscription-manager during
                           # the build (prompts for Red Hat credentials once,
                           # caches them in ./.secrets which is gitignored)
```

Works with either **docker** or **podman** — `build.sh` picks whichever is on
`PATH` (docker first). Override with `ENGINE=podman ./build.sh`.

One podman-specific wrinkle is handled inside the Dockerfile: on a *subscribed
RHEL host*, podman bind-mounts the host's subscription secrets into every
container, which flips the UBI image's `subscription-manager` into "container
mode". That breaks `--subscription` (the CLI refuses every subcommand) and
also breaks the plain build (its dnf plugin pulls in host `cdn.redhat.com`
repos that fail OCSP validation). The image drops `/etc/rhsm-host` and
`/etc/pki/entitlement-host` in an early layer to opt out; the trade-off is
that containers from this image can't borrow a RHEL host's entitlements at
runtime. Nothing in the package list needs them.

## Run

```
./run.sh                                 # login shell as mcdonoe in /workspace
./run.sh --root                          # same, as root
./run.sh 'cd omp_distro && ./build.sh'   # run one command and exit
```

`run.sh` mounts `~/GIT_REPOS` at `/workspace` (override with `WORKSPACE=`)
and adds what a bare `docker run` lacks:

- **`--security-opt seccomp=unconfined`**, which **omp_distro's `build.sh`
  needs**. Its offline smoke tests run in a private network namespace
  (`unshare -rn`). The engines' default seccomp profiles refuse `unshare` to
  anything without `CAP_SYS_ADMIN`, root included, so preflight fails with
  *"an isolated unshare network namespace is unavailable"*. This adds no
  capabilities, so it's narrower than `--cap-add SYS_ADMIN` or `--privileged`.
- **A login shell**, so `/etc/profile.d` sets up `PATH`, `GOTOOLCHAIN`,
  `JAVA_HOME` and gcc-toolset-12.
- **Named volumes for the Go caches** (`rhel9-dev-gopath`,
  `rhel9-dev-gocache`), so repeated builds skip re-downloading modules.
  Remove them with `docker volume rm rhel9-dev-gopath rhel9-dev-gocache`.

The equivalent by hand:

```
docker run -it --rm --security-opt seccomp=unconfined \
    -v "$HOME/GIT_REPOS:/workspace" rhel9-dev bash
```

Entering the container with `su - mcdonoe` also works: the same environment
is set in `/etc/profile.d/10-dev-env.sh` because `su -` throws away the
image's `ENV`.

`podman` is a drop-in substitute for `docker` in every command in this README.
On RHEL, `docker` is usually the `podman-docker` shim wrapping podman anyway.

Container starts as root (so ad-hoc `dnf install` works like the stock
`redhat/ubi9` image). A passwordless-sudo `mcdonoe` user also exists (UID/GID
1000, matching your host user, so bind-mounted files keep sane ownership)
for attaching as non-root, e.g. via VS Code's Dev Containers extension
("Attach to Running Container") or `docker exec -u mcdonoe -it <container> bash`.

## Notes

- **gcc**: gcc-toolset-12 is active by default in every interactive shell.
  Switch to 14 or 15 for the current shell with:
  ```
  source /opt/rh/gcc-toolset-14/enable    # or gcc-toolset-15
  ```
- **Python**: `python3.11`, `python3.12` and `python3.14` are installed as
  explicit commands (no `python3` alias change) — RHEL's own tooling depends
  on the system Python, so it's left alone. Use `python3.X -m venv`, or `uv`
  for project-level dependency management.
- **Go**: the official go.dev tarball in `/usr/local/go` (checksum-pinned via
  `GO_VERSION`/`GO_SHA256` in the Dockerfile), with `gopls` and `dlv` in
  `/usr/local/bin`. It's there so omp_distro's `build.sh` can compile
  `github-mcp-server` from patched source (needs Go >= 1.25.12,
  mcdonoe/omp_distro#2). Notes:
  - `GOTOOLCHAIN=local` is set image-wide, so a `go.mod` that wants a newer
    Go fails loudly instead of quietly downloading a toolchain.
  - Module downloads need outbound HTTPS to `proxy.golang.org` and
    `sum.golang.org`. For an internal proxy, pass `-e GOPROXY=... -e GOSUMDB=...`
    (or `GONOSUMDB`) to `run`.
  - `GOPATH` and `GOCACHE` default to `~/go` and `~/.cache/go-build` for
    whichever user runs the build. To keep module downloads warm across
    `--rm` runs, mount a volume at both. `~/go/bin` is on `PATH` for
    `go install`ed tools.
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
`dhcp-option` lines to match that network's subnet. Pick a dedicated/isolated
interface, not your main LAN uplink.

**Which name do I use?** The host's. `--network host` means the container
shares the host's network namespace, so it sees your bare-metal interfaces
under your bare-metal names — there is no separate container-side naming to
discover. Whatever this prints is what goes in `dhcp.conf`:

```
ip -br addr show
```

**The interface must be UP with an address inside the `dhcp-range` subnet.**
dnsmasq derives which range applies from the addresses on that NIC, so it
refuses to start otherwise, with a message that misleadingly looks like a
naming problem:

```
dnsmasq: unknown interface eno1
```

That means "no usable address", not "no such name". Two ways to hit it:

- **No carrier.** A NIC with nothing plugged in stays `DOWN` no matter what
  (`Link detected: no` from `ethtool`), and can't be used.
- **Wrong subnet.** An interface on `192.168.1.16/24` cannot serve
  `dhcp-range=192.168.100.50,192.168.100.150` — no address in range.

So before starting the server, confirm the NIC actually looks like this,
with an address and not blank:

```
$ ip -br addr show eno1
eno1   UP   192.168.100.1/24
```

If it has no address, give it one in the range's subnet — typically the
address your `dhcp.conf` advertises as `option:router`, if this box is the
gateway for that segment:

```
sudo nmcli connection modify eno1 ipv4.method manual \
     ipv4.addresses 192.168.100.1/24 connection.autoconnect yes
sudo nmcli connection up eno1
```

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

### Inspecting a running server

```
./run-dhcp.sh              # serve in the foreground (Ctrl-C to stop)
./run-dhcp.sh --detach     # serve in the background, return your prompt
./run-dhcp.sh --leases     # print the current lease table
./run-dhcp.sh --shell      # open a shell inside the running server
./run-dhcp.sh --stop       # stop a running server
```

`--leases` renders dnsmasq's table with a readable expiry:

```
LEASE EXPIRES        MAC                IP               HOSTNAME
2026-01-01 00:00:00  c8:d3:ff:b4:bd:a5  192.168.100.57   buildbox
2026-01-01 01:00:00  aa:bb:cc:dd:ee:01  192.168.100.58   -
```

Leases are **ephemeral** — the table lives only inside the container, so it
resets when the server stops, and `--leases` needs a running server to read.

`--shell` drops you into the server. Because it uses `--network host`, that
shell shares the host's network stack, so `ssh user@192.168.100.57` reaches a
leased client exactly as it would from the host — the container just has
`openssh-clients` at hand. Note this is ssh *out* to clients; the image runs
no `sshd`, so nothing can ssh *into* the container.

**Why that shell's prompt looks the way it does.** Sharing the host's network
namespace means inheriting its network identity, hostname included — so by
default a root shell in the DHCP container renders as `[root@rhel10-ws /]#`,
indistinguishable from a root shell on the metal. (In dev mode, with its own
namespace, the engine stamps the container ID instead, which is the "random
string" hostname you see there.) `run-dhcp.sh` passes `--hostname rhel9-dhcp`
so the prompt reads:

```
[root@rhel9-dhcp /]#
```

That flag is applied **only under podman**, which is detected from what the
binary reports rather than what it's called — the `podman-docker` shim answers
to `docker` but is podman underneath. Docker rejects `--hostname` alongside
`--net=host` (`conflicting options: hostname and the network mode`), so on a
real Docker daemon the flag is omitted and the prompt shows the host's name.

Note this changes only the prompt. The container's *name* is `rhel9-dhcp`
either way — that's what `docker ps` lists and what the flags above use to
find it; hostname and name are independent.

The container is named `rhel9-dhcp` (override with `CONTAINER_NAME=`), which
is what lets the flags above find it. Since a foreground `./run-dhcp.sh`
occupies its terminal, `--leases` and `--shell` either want a second terminal
or a `--detach` start.

**On podman, DHCP mode needs root.** A rootless container gets `--cap-add`
capabilities only inside its own user namespace, but the host network
namespace is owned by the initial one — so `dnsmasq` is denied its
`AF_PACKET` raw socket and can't bind port 67. `run-dhcp.sh` detects this and
tells you rather than failing cryptically. Because rootful podman keeps a
*separate image store* from your rootless one, the image has to be built
there too:

```
sudo ./build.sh && sudo ./run-dhcp.sh
```

None of this applies to a normal (rootful) Docker daemon, where
`./run-dhcp.sh` works as-is. SELinux is handled for you: the config mount
uses `:z` so an enforcing host relabels it to `container_file_t` instead of
failing with `cannot read /etc/dnsmasq.d/dhcp.conf: Permission denied`.

**Before running this against a real network:** confirm nothing else on
that segment is already handing out DHCP leases. Two DHCP servers
answering the same broadcast domain race each other and can break
connectivity for every device on it, not just this container.
`dhcp.conf.example` sets `dhcp-authoritative`, which assumes this is the
only DHCP server on the segment.

### Testing without touching a real network

A disconnected physical NIC does *not* work as a test target — see above. Use
a `dummy` interface instead: it always has carrier, takes an address, and
goes nowhere. Run it inside a container on the **default** (isolated) network
so nothing can escape onto your LAN:

```
docker run --rm -it --cap-add=NET_ADMIN --cap-add=NET_RAW rhel9-dev bash
```

Then, inside that container:

```
ip link add test0 type dummy
ip addr add 192.168.100.1/24 dev test0
ip link set test0 up

cat > /tmp/test.conf <<EOF
interface=test0
bind-interfaces
port=0
dhcp-range=192.168.100.50,192.168.100.150,12h
EOF

dnsmasq --no-daemon --conf-file=/tmp/test.conf
```

That proves your config parses and dnsmasq binds. It cannot prove clients get
leases — packets sent to a dummy interface are discarded, so nothing can
answer. For a real end-to-end test you need a second machine (or a veth pair
into a network namespace) on an isolated segment.

`dnsmasq --test --conf-file=...` checks config syntax alone, without binding
anything — safe to run anywhere, including against a live config.

## Troubleshooting

Most of these are podman-on-RHEL behaviours that simply don't arise with
Docker on a non-SELinux host, which is why something can work on one machine
and fail on another.

| Message | Cause | Fix |
| --- | --- | --- |
| `subscription-manager is operating in container mode` | On a *subscribed RHEL host*, podman bind-mounts host subscription secrets into every container, so UBI's `-host` symlinks resolve and the CLI disables itself | Already handled — the Dockerfile drops those symlinks. Rebuild if you removed that layer. |
| `Curl error (91) ... No OCSP response received`, or `Failed to download metadata for repo 'rhel-9-for-x86_64-...'` | Same cause: the subscription-manager dnf plugin pulled the host's `cdn.redhat.com` repos into the build, and they fail OCSP | Same fix — that layer prevents it. |
| `cannot read /etc/dnsmasq.d/dhcp.conf: Permission denied` | SELinux: repo files are `unlabeled_t`, the container runs as `container_t` | Already handled by `:z` on the mount. Add `:z` yourself if invoking the engine by hand. |
| `dnsmasq: unknown interface eno1` | The NIC has no address in the `dhcp-range` subnet — **not** a naming problem | See the DHCP setup section: bring it up with an in-range address. |
| `error: podman is running rootless, which cannot serve DHCP` | Rootless containers get `--cap-add` only inside their user namespace | `sudo ./build.sh && sudo ./run-dhcp.sh` |
| `error: no DHCP container named 'rhel9-dhcp' is running` | `--leases`/`--shell`/`--stop` with nothing serving | Start one with `--detach`. If you started it with `sudo`, run these with `sudo` too — a rootful container is invisible to your user's engine. |
| `error: 'rhel9-dhcp' is already serving DHCP` | A server is already up | `./run-dhcp.sh --shell` or `--stop` |
| `error: neither docker nor podman found on PATH` | No container engine installed | Install one, or set `ENGINE=`. |

## Expanding the image

**Add a package that's in an already-enabled repo** (most things — the base
image ships UBI AppStream, BaseOS and CodeReady Builder; the Dockerfile adds
EPEL). Add the name to the `dnf install -y \` list in the `Dockerfile`
(alphabetical-ish within its comment group, doesn't matter functionally),
then:

```
./build.sh
```

The layer cache means this only re-runs from that `RUN dnf install`
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

**Add something not packaged for RHEL9 at all** (like Ant, Go or uv here) —
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
