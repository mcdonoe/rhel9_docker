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

Rootless podman keeps images per user, so each user loads their own copy
(about 6 GB in `~/.local/share/containers`):

```
podman load -i rhel9-dev-image.tar.gz
podman images rhel9-dev                     # check it's there
```

To store one copy for everyone instead, load it as root into a shared
read-only store and point everyone's podman at it. This is podman's
"additional image store" feature; it hasn't been tested with this image:

```
sudo podman --root /var/lib/shared-images load -i rhel9-dev-image.tar.gz
sudo chmod -R a+rX /var/lib/shared-images
# then in /etc/containers/storage.conf, under [storage.options]:
#   additionalimagestores = [ "/var/lib/shared-images" ]
```

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
- **Updating.** Load a newer package's image with `podman load` the same way.
  Then remove the old one with `podman image prune`.
