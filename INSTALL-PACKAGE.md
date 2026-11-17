# Installing the rhel9-dev package

This package holds a prebuilt `rhel9-dev` development image and the scripts
that run it, for a machine that won't build the image itself, such as an
airgapped RHEL8 host with podman. Installing it needs no network.
`README.md` covers what the image is and how `run.sh` behaves.

| File | What it is |
| --- | --- |
| `install-shared.sh` | Installs everything for all users (step 2) |
| `rhel9-dev-image.tar.gz` | The image, as written by `docker save` (linux/amd64) |
| `run.sh`, `engine.sh` | Start the container as you; installed as the `rhel9-dev` command |
| `PACKAGE-INFO` | Which image and repo commit this package is |
| `OMP-BUILD-INFO` | The OMP bundle inside the image |
| `SHA256SUMS` | Checksums for the files above |

In short, as root:

```
tar -xf rhel9-dev-<date>.tar && cd rhel9-dev-<date>
./install-shared.sh
```

then each user runs `rhel9-dev --check` once, and `rhel9-dev` from then on.

## 1. Prerequisites (once per machine, as root)

- **x86_64.** The image is amd64 only.
- **podman:** `dnf install podman` (or `container-tools`), from the host's
  RHEL repos or install media.
- **fuse-overlayfs:** `dnf install fuse-overlayfs` (RHEL8 usually has it
  already, as part of podman). The installer stops if it's missing (see
  step 2 for why it's needed).
- **Rootless podman for each user.** Each user needs entries in `/etc/subuid`
  and `/etc/subgid`. `useradd` adds them on RHEL8, but accounts from LDAP/IdM
  or older installs may have none:
  ```
  grep "^$USER:" /etc/subuid /etc/subgid      # as the user; both should match
  usermod --add-subuids 100000-165535 --add-subgids 100000-165535 <user>
  ```
  User namespaces must be enabled too: `sysctl user.max_user_namespaces`
  must be above 0.
- **OMP on the host at the same bundle version**, if users run OMP. The
  container uses each user's host `~/.omp`, which points at files under
  `/opt/omp` by bundle version:
  ```
  diff OMP-BUILD-INFO /opt/omp/BUILD-INFO     # no output means they match
  ```

## 2. Install (as root)

```
./install-shared.sh
```

This loads the image **once** into a shared, read-only image store that
every user's podman reads from (podman's "additional image store"). Each
user's own storage then holds only what they create: each container's small
writable layer (deleted on exit, since `rhel9-dev` uses `--rm`), their Go
cache volumes, and any images they pull themselves.

It prints what it changes at each step:

1. Checks the package against `SHA256SUMS`.
2. Loads the image into `/var/lib/shared-images` and makes it
   world-readable.
3. Labels the store for SELinux the same way as podman's own storage.
4. Edits `/etc/containers/storage.conf`, after backing it up. It adds the
   store to `additionalimagestores` and sets
   `mount_program = "/usr/bin/fuse-overlayfs"`.
5. Installs the scripts to `/opt/rhel9-dev` and links
   `/usr/local/bin/rhel9-dev` to `run.sh`.
6. Lists users whose own `storage.conf` would hide the shared store.

Options: `--store DIR`, `--prefix DIR`, `--bindir DIR`,
`--no-fuse-overlayfs`, `--prune`, `--skip-checksums`, `--tmpdir DIR`; see
`--help`.

**Temporary space.** While loading, podman unpacks the whole image into a
temporary folder first: several GB, in `/var/tmp` by default. If `/var/tmp`
is small, point it elsewhere: `./install-shared.sh --tmpdir /DATA/tmp`. The
installer shows the free space before it starts.

Why the store is set up this way:

- **World-readable store.** Rootless podman reads the store as each user's
  own host UID, and files owned by host root can't be overridden even by
  root inside the container. The container's entrypoint creates your user,
  which rewrites `/etc/passwd`, `/etc/shadow` and `/etc/group`, starting
  from their copies in the store, and `/etc/shadow` is mode 0000 in the
  image. If those files can't be read, the container exits at once. The
  side effect is that `/etc/shadow` is world-readable inside the container,
  where it holds no passwords.
- **fuse-overlayfs** makes the store's root-owned files show up as root
  inside a rootless container. Without that setting, podman tries to make
  each user a private, re-owned copy of the whole image on first start. On
  RHEL8 that fails, so no container starts (`creating container storage:
  error during chown: storage-chown-by-maps: lchown ...: operation not
  permitted`); on RHEL9 and later it works but takes minutes and several
  GB per user, which defeats the shared store. The setting
  in `storage.conf` also applies to root's own podman, which is a little
  slower through fuse-overlayfs but otherwise unaffected.
- **`force_mask = "shared"`** is how the store keeps each file's real
  owner and mode. The installer loads the image into the store with it:
  every file is stored as root-owned and readable,
  with the real owner and mode (setuid bits included) in an extended
  attribute that fuse-overlayfs shows inside the container. Without it,
  a rootless user sees the store's root-owned files as owned by `nobody`,
  and `sudo` inside the container fails. Only loading needs the option;
  it isn't set in `storage.conf`. If the installer finds a store made
  without it (by an older installer), it empties the store and loads the
  image again. Needs podman 4.0 or later (RHEL 8.6+).
  Podman 4.x (RHEL 8) writes those attributes without the setuid, setgid
  and sticky bits, and leaves them off each layer's top directory, so
  fuse-overlayfs ignores them all (`/tmp` unwritable, `sudo` broken). After
  loading, the installer rewrites them from the image's own layer files.
  Re-running a current installer repairs an existing store in place. On
  RHEL 8, fuse-overlayfs (before 1.14) also loses them when a container
  first writes into a directory. The image's entrypoint compensates for the
  directories that matters for (`/tmp`, `/var/tmp`, `/etc/sudoers.d`).
  Others that root first writes into during a session show as owned by
  `nobody`, which is cosmetic.
- **Users' own `~/.config/containers/storage.conf`** replaces the system
  file, because podman doesn't merge them. Anyone listed in step 6 must add
  the store to `additionalimagestores` (and the same `mount_program`) in
  theirs.

## 3. Each user, once

As yourself, **not** with sudo:

```
rhel9-dev --check
```

This checks that the image comes from the shared store and that podman is
set up to use it without copying it. It then starts a test container to
confirm that you have your own UID inside it, that `sudo` works, and that
it started in seconds. It tells you exactly what to fix if not. The most
likely fix: if you loaded a private copy of the image before, it hides the
shared one, and `--check` prints the `podman rmi <ID>` that removes it. That
command removes only your copy.

## 4. Use it

```
rhel9-dev                     # shell, in your repo base directory
rhel9-dev --omp <repo>        # the OMP agent in that repo
rhel9-dev 'make -j8'          # run one command and exit
```

The first run asks for your git repo base directory if you have no
`~/GIT_REPOS`, and remembers it (README: Your repo base directory).

Notes:

- **Don't use sudo.** Under sudo, `rhel9-dev` runs as root and anything you
  create in your repos ends up owned by root. Rootless podman is what lets
  each user run it safely, without access to the rest of the machine.
- **SELinux.** The container runs with `--security-opt label=disable`, so
  it never relabels your files. Relabelling (`:z`) would walk your whole
  repo tree on every start, change your files' labels, and fail on any file
  you don't own. The trade-off is that SELinux doesn't confine this one
  container; rootless podman's user namespace and seccomp still do.
- **"Failed to mount subscriptions" warning.** podman on a subscribed RHEL
  host tries to share the host's Red Hat subscription with every container,
  and a normal user can't read it. This is harmless; the image doesn't use it.

## Updating

Copy over a newer package and run its `install-shared.sh` the same way. It
loads the new image under the same name, so users pick it up the next time
they start `rhel9-dev`.

The image it replaces stays in the store, with no name, until you delete
it. Containers that are running keep using it until they exit. Once nobody
is in a `rhel9-dev` container, delete it with:

```
/opt/rhel9-dev/install-shared.sh --prune      # from the new package dir
```

`--prune` refuses while it can see a container using the store. Users
can't delete images from the shared store themselves.

## Without the shared store

On a single-user machine, or without root, a user can instead load a
private copy (several GB in `~/.local/share/containers`) and run the
scripts from the package directory:

```
podman load -i rhel9-dev-image.tar.gz
./run.sh
```

To update, load the newer image the same way, then `podman image prune`.
