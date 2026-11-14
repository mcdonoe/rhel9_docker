# Installing the rhel9-dev package

This package holds a prebuilt `rhel9-dev` image and the scripts that run it,
for a machine that won't build the image itself, such as RHEL8 with podman.
`README.md` covers what the image is and how `run.sh` behaves. These are the
steps for getting it running on a new machine.

| File | What it is |
| --- | --- |
| `rhel9-dev-image.tar.gz` | The image, as written by `docker save` (linux/amd64) |
| `run.sh`, `engine.sh` | Start the container as you (see README: Run) |
| `run-dhcp.sh`, `dnsmasq/` | The optional DHCP server (see README) |
| `PACKAGE-INFO` | Which image and repo commit this package is |
| `OMP-BUILD-INFO` | The OMP bundle inside the image |
| `SHA256SUMS` | Checksums for the files above |

## 1. Check the copy

```
sha256sum -c SHA256SUMS
```

## 2. Prerequisites (once per machine, as root)

- **x86_64.** The image is amd64 only.
- **podman:** `dnf install podman` (or `container-tools`).
- **Rootless podman for each user.** Each user needs entries in `/etc/subuid`
  and `/etc/subgid`. `useradd` adds them on RHEL8, but accounts from LDAP/IdM
  or older installs may have none:
  ```
  grep "^$USER:" /etc/subuid /etc/subgid      # as the user; both should match
  usermod --add-subuids 100000-165535 --add-subgids 100000-165535 <user>
  ```
  User namespaces must be enabled too: `sysctl user.max_user_namespaces`
  must be above 0.
- **OMP on the host at the same bundle version.** The container uses each
  user's host `~/.omp`, which points at files under `/opt/omp` by bundle
  version. Compare the two before relying on it:
  ```
  diff OMP-BUILD-INFO /opt/omp/BUILD-INFO     # no output means they match
  ```

## 3. Load the image

There are two ways to do this. **A shared store** (3a) keeps one copy for
everyone. **Per user** (3b) is simpler but costs each user several GB.

### 3a. One shared copy for everyone (recommended)

Root loads the image into a read-only store that every user's podman reads
from, using podman's "additional image store" feature. Each user's own
store then holds only the small writable layer of each running container
(deleted when it exits; `run.sh` uses `--rm`), their Go cache volumes, and
any images they pull themselves.

**Once per machine, as root:**

```
mkdir -p /var/lib/shared-images
podman --root /var/lib/shared-images load -i rhel9-dev-image.tar.gz
chmod -R a+rX /var/lib/shared-images
```

Then in `/etc/containers/storage.conf`, under `[storage.options]`:

```
additionalimagestores = [ "/var/lib/shared-images" ]
```

And, on RHEL9 or newer only, under `[storage.options.overlay]`:

```
mount_program = "/usr/bin/fuse-overlayfs"
```

(`dnf install fuse-overlayfs` if it's missing.) RHEL8 already uses
fuse-overlayfs for rootless podman, so skip that there.

Why each step matters:

- **`chmod -R a+rX` is required, not optional.** Rootless podman reads the
  store's files as your own host UID, and files owned by host root can't be
  overridden even by root inside the container. When the container starts,
  `run.sh` creates your user, which rewrites `/etc/passwd`, `/etc/shadow`
  and `/etc/group`. That means reading them from the store, and
  `/etc/shadow` is mode 0000 in the image. Without the chmod, creating the
  user fails and the container exits at once. The side effect is that
  `/etc/shadow` is world-readable inside the container; it holds no
  passwords. **Re-run the chmod after every load.**
- **fuse-overlayfs** is what makes files owned by root in the store show up
  as root inside a rootless container. Without it, newer kernels' native
  overlay can't remap ownership. Podman then either shows those files as
  owned by `nobody` (breaking `sudo`), or makes each user a private
  re-owned copy of the whole image on first start. That takes minutes and
  defeats the shared store.
- **A user's own `~/.config/containers/storage.conf` replaces the system
  file**; podman doesn't merge them. Anyone who has one must add the
  `additionalimagestores` line (and `mount_program`, if it applies) there
  too.

**Once per user, as that user:** remove any private copy, which would
otherwise hide the shared one (podman checks your own store first), then
check:

```
podman rmi rhel9-dev 2>/dev/null; podman image prune -f
podman images --format '{{.Repository}} {{.ReadOnly}}' | grep rhel9-dev
                                            # should print: ... true
/opt/rhel9-dev/run.sh 'id; sudo true && echo sudo-ok'
                                            # your own UID, then sudo-ok
```

The first start should take seconds. If it takes minutes, podman is making
a private copy; check `mount_program` above. `du -sh
~/.local/share/containers` should stay well under 1 GB, plus Go caches.

**Updating the shared image**, as root:

```
podman --root /var/lib/shared-images load -i rhel9-dev-image.tar.gz
chmod -R a+rX /var/lib/shared-images
podman --root /var/lib/shared-images image prune -f   # drops the old one
```

Users can't remove or prune images in the shared store. Prune the old image
only when nobody has a container running from it; with `--rm` containers,
that just means when nobody is logged into one.

### 3b. Per user

Each user loads their own copy into `~/.local/share/containers`:

```
podman load -i rhel9-dev-image.tar.gz
podman images rhel9-dev                     # check it's there
```

To update, load the newer image the same way, then `podman image prune`.

## 4. Run it

Put this directory somewhere everyone can read (e.g. `/opt/rhel9-dev`), then
as each user, **without sudo**:

```
/opt/rhel9-dev/run.sh                    # shell, in your repo base directory
/opt/rhel9-dev/run.sh --omp <repo>       # the OMP agent in that repo
```

The first run asks for your git repo base directory if you have no
`~/GIT_REPOS`, and remembers it (README: Your repo base directory).

Notes:

- **Don't use sudo.** Under sudo, `run.sh` runs as root and anything you
  create in your repos ends up owned by root. Rootless podman is what lets
  each user run it safely, without access to the rest of the machine.
- **SELinux.** `run.sh` starts the container with
  `--security-opt label=disable`, so it never relabels your files. Relabelling
  (`:z`) would walk your whole repo tree on every start, change your files'
  labels, and fail on any file you don't own. The trade-off is that SELinux
  doesn't confine this one container; rootless podman's user namespace and
  seccomp still do.
- **"Failed to mount subscriptions" warning.** podman on a subscribed RHEL
  host tries to share the host's Red Hat subscription with every container,
  and a normal user can't read it. This is harmless; the image doesn't use it.
- **Updating.** Load a newer package's image the way you loaded this one:
  root updates a shared store (step 3a), or each user runs `podman load`
  and then `podman image prune` (step 3b).
