# rhel9-dev

A persistent RHEL9 (UBI9) development image: git, cmake, make, autotools,
gcc-toolset 12, 14 & 15, Python 3.11, 3.12 & 3.14, Go (+ gopls, delve),
OpenJDK 21 + Ant, uv, vim, btop,
the OMP coding agent from an omp_distro bundle (see [OMP](#omp-coding-agent)),
plus an opt-in dnsmasq DHCP server (see below).

## Repo layout

| File | Purpose |
| --- | --- |
| `Dockerfile` | The image definition |
| `build.sh` | Builds it, optionally registering with Red Hat (`--subscription`) |
| `run.sh` | Starts a dev shell, one command, or the OMP agent (`--omp`), as you |
| `entrypoint.sh` | Creates the calling host user in the container and drops to it |
| `run-dhcp.sh` | Runs the image as a DHCP server, and inspects a running one |
| `engine.sh` | Shared docker/podman detection, sourced by the scripts above |
| `dnsmasq/dhcp.conf.example` | Template to copy to `dhcp.conf` (gitignored) |
| `omp-bundle/` | Where `build.sh` stages the OMP bundle for the build (contents gitignored) |
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
./run.sh                                 # login shell as you, in your repo base dir
./run.sh --root                          # same, as root
./run.sh 'cd omp_distro && ./build.sh'   # run one command and exit
./run.sh --omp REPO                      # the OMP agent in REPO
```

Anyone on the host can use it: the container runs as **whoever started it**,
with their host UID/GID.

### Users and file ownership

A bind mount doesn't translate ownership. Files under your repo base
directory carry the
same numeric UID/GID as on the host, and the kernel checks those numbers
against the container process's UID. So the process has to run as your
host UID, or your edits land owned by someone else (or fail).

The image has no user baked in. `run.sh` passes your `id -u`, `id -g` and
user name to `entrypoint.sh`, which creates a matching user (home
`/home/<you>`, passwordless `sudo`) and then drops to it. Without those
variables, e.g. a plain `docker run -it rhel9-dev bash`, `run.sh --root` or
`run-dhcp.sh`, the container runs as root like the stock `redhat/ubi9` image.

- **Rootless podman** maps container UIDs to subordinate host UIDs, so
  `run.sh` adds `--userns=keep-id` to keep your UID the same on both sides.
- **Rootless docker** maps only container root to you, so there `run.sh`
  runs as container root.
- The `docker` group is root-equivalent on the host. For people you wouldn't
  give root, use rootless podman instead.

To attach a second shell or VS Code's Dev Containers extension ("Attach to
Running Container"), use your own user name: `docker exec -u <you> -it
<container> bash -l`.

### Your repo base directory

Your git repo base directory is chosen in this order:

1. `WORKSPACE=/path/to/repos ./run.sh` if set
2. `~/GIT_REPOS` if it exists
3. otherwise `run.sh` asks once and saves the answer in
   `~/.config/rhel9-dev/workspace` (edit or delete it to change)

It's mounted at **the same path as on the host** (e.g. `/home/you/GIT_REPOS`),
with `/workspace` as a symlink to it, and the container's `$HOME` is your
host home path too. OMP keys sessions and memory by path, so this is what
lets the container and the host share them (see [OMP](#omp-coding-agent)).
System paths such as `/usr` or `/opt` can't be used, since mounting there
would hide the image's own files.

### What else `run.sh` adds

- **`--security-opt seccomp=unconfined`**, which **omp_distro's `build.sh`
  needs**. Its offline smoke tests run in a private network namespace
  (`unshare -rn`). The engines' default seccomp profiles refuse `unshare` to
  anything without `CAP_SYS_ADMIN`, root included, so preflight fails with
  *"an isolated unshare network namespace is unavailable"*. This adds no
  capabilities, so it's narrower than `--cap-add SYS_ADMIN` or `--privileged`.
  `--omp` leaves it off.
- **`--security-opt label=disable`**, so on an SELinux host (RHEL with
  podman) your repos and `~/.omp` are used as they are instead of being
  relabelled. `:z` would relabel the whole repo tree on every start, and it
  fails with `lsetxattr ... operation not permitted` on any file you don't
  own. SELinux doesn't confine this container as a result; the user
  namespace and seccomp still apply. Hosts without SELinux ignore it.
- **A login shell**, so `/etc/profile.d` sets up `PATH`, `GOTOOLCHAIN`,
  `JAVA_HOME` and gcc-toolset-12.
- **Your host `~/.omp`**, bind-mounted at the same path (see
  [OMP](#omp-coding-agent)).
- **Per-user named volumes** for the Go caches (`rhel9-dev-<you>-gopath`,
  `rhel9-dev-<you>-gocache`), so repeated builds skip re-downloading modules.
  Remove yours with
  `docker volume rm rhel9-dev-$USER-gopath rhel9-dev-$USER-gocache`.

The equivalent by hand:

```
docker run -it --rm --security-opt seccomp=unconfined \
    -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) -e HOST_USER=$USER \
    -e HOST_HOME=$HOME -e HOST_WORKSPACE=$HOME/GIT_REPOS \
    -v "$HOME/GIT_REPOS:$HOME/GIT_REPOS" -v "$HOME/.omp:$HOME/.omp" \
    -w "$HOME/GIT_REPOS" rhel9-dev bash -l
```

The environment is also set in `/etc/profile.d/10-dev-env.sh`, so `su -`
(which throws away the image's `ENV`) gets it too.

`podman` is a drop-in substitute for `docker` in every command in this README.
On RHEL, `docker` is usually the `podman-docker` shim wrapping podman anyway.

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

## OMP coding agent

The image can carry the [OMP](https://omp.sh) coding agent from an
omp_distro bundle, so it runs in the container but works on your host
repos. Using it from the container is optional: it's the same OMP, with the
same config, as on the host, just sandboxed.

```
./run.sh 'cd omp_distro && ./build.sh'   # 1. build a bundle (lands in omp_distro/dist/)
./build.sh                               # 2. rebuild the image with it
./run.sh --omp rhel9_docker              # 3. run OMP in rhel9_docker
```

- **Which bundle**: `build.sh` takes the newest
  `~/GIT_REPOS/omp_distro/dist/omp-portable-*-linux-x64.tar.gz` (point it at
  another `dist/` with `OMP_DIST=`). Pick a specific bundle with
  `--omp-bundle PATH`, or leave OMP out with `--no-omp`. The image is shared:
  build it once and every user runs the same OMP. With no bundle
  the image builds without OMP.
- **Keep it in step with the host**: build the image from the same bundle
  version that's installed on the hosts, and upgrade both together. The
  container uses each user's host `~/.omp`, which points at files under
  `/opt/omp` (native addons, skills, extensions) by bundle version, and
  those have to exist at the same paths in the image.
- **Your `~/.omp`**: `run.sh` bind-mounts your host `~/.omp`, so the
  container uses the config, models, `omp-mcp-setup` identities, sessions,
  memory and `/undo` snapshots you already have on the host. Your repos are
  at their host paths too, so a session started on the host can be resumed
  in the container and the other way round. Avoid running OMP on the host and
  in the container against the same `~/.omp` at the same time.
- **Setup**: run `omp-user-setup` and `omp-mcp-setup` on the host as usual;
  the container doesn't re-run them. Only if `~/.omp` has never been set up
  at all does the container run `omp-user-setup` on login.
- **Model router**: the image's RouteLM URL (`ROUTELM_URL=http://host:port/v1
  ./build.sh`, default `http://192.168.1.151:11400/v1`) only matters for
  that first-time setup. Otherwise the URL in your `~/.omp/agent/models.yml`
  is what's used, on the host and in the container alike. The container
  reaches it over its normal network.
- **Per repo**: `omp-bp-init` once in each repo, as the bundle's
  `README-TEAM.md` says. It writes into the repo, so it's left to you.
- **What the agent can reach**: your repo base directory and `~/.omp`
  read-write (for `~/GIT_REPOS`, that includes this repo's `.secrets/`; for
  `~/.omp`, your MCP tokens, just as on the host), the whole network, and
  passwordless `sudo` inside the
  container. It has no access to the rest of the host. No SSH keys or git
  credentials are mounted, so it can commit but not push. `--omp` keeps the
  engine's default seccomp profile, because unlike omp_distro's build, OMP
  doesn't need `unshare`.

`./run.sh --omp` with no repo starts in your repo base directory; anything after the repo
goes to `omp` itself, e.g. `./run.sh --omp omp_distro --version`. You can also
just run `omp` from a normal `./run.sh` shell.

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
