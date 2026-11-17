# Checkpoint: rhel9-dev on RHEL 8 — /tmp and sudo broken in the shared-store image

Updated 2026-11-17 on the RHEL 8.10 stand-in host (fuse-overlayfs 1.13,
podman 4.9.4), branch `web-dev`. Claude: read this whole file first, then
start at "Still to do".

## The problem (seen on dipper-dl380, RHEL 8.8, not available to us)

Inside a rhel9-dev container from the shared store: `/tmp` is
`drwxr-xr-x nobody nobody`, `touch /tmp/x` is denied, and sudo says "must be
owned by uid 0 and have the setuid bit set". The Java core build's tests fail
155/266: Mockito self-attach, JUnit `@TempDir` and jzmq all need a writable
/tmp.

## Root cause: three bugs, all reproduced here without root

Reproduced by loading the real image (`rhel9devimage.podman`, Aug 31) into a
scratch store with `--storage-opt overlay.force_mask=shared`. The store is
then run as an additional image store via `--storage-opt overlay.imagestore=`
(note: `CONTAINERS_STORAGE_CONF` silently didn't take effect here; use
explicit `--root`/`--storage-opt` flags). `podman unshare chown -R 65534` on
the layers simulates a root-owned store, as a rootless user sees it. RHEL
8.8's fuse-overlayfs 1.10 and 1.11 (from `dnf download`, unpacked, used as
mount_program) behave the same as 8.10's 1.13 in every test.

1. **podman 4.x force_mask drops special bits from the xattr.**
   `user.containers.override_stat` records sudo (4111) as `0:0:0111`, /tmp
   (1777) as `0:0:0777`, and setgid is lost too.
2. **podman 4.x puts no override xattr on each layer's diff root.**
   fuse-overlayfs (direct.c, layer load) only reads a layer's override
   xattrs if its root dir has one, so it ignores them all: everything shows
   0755. This alone gives dipper's `--check` output (sudo 755).
3. **fuse-overlayfs before 1.14 copies directories up with raw on-disk
   owner/mode.** `create_node_directory()` in main.c uses `fstat()`, not the
   override-aware `statat()` (file copy-up is fine). From a shared store
   that is nobody/0755, so the first file created in /tmp leaves /tmp
   `755 nobody` and every later write fails; the entrypoint writing
   /etc/sudoers.d leaves it nobody-owned, and sudo then refuses
   ("/etc/sudoers.d is owned by uid 65534, should be 0"). Fixed upstream in
   1.14 ("propagate extended attributes permissions with copyup"); RHEL 8
   tops out at 1.13. `xattr_permissions=2` doesn't help.

## Fixes made (uncommitted)

- **install-shared.sh**: after `podman load`, a Python step rewrites the
  override xattrs from the image's own layer tars (matched to the store's
  layers by diff digest via overlay-layers/layers.json): real
  uid:gid:mode, special bits included, and on every layer root. Fixes #1 and
  #2. Idempotent; it also repairs an existing store on re-run. Takes ~30 s
  for the 2 GB image. Hardlinks take their target's values.
- **entrypoint.sh**: as root, before anything writes, records owner/mode of
  /etc, /etc/profile.d, /etc/sudoers.d, /tmp and /var/tmp, then sets them
  back (forcing the copy-up with the right values) before exec. Works around
  #3. Needs an **image rebuild**.
- **run.sh `--check`**: also creates two files in /tmp (the second fails
  under #3), and distinguishes sudo failure causes by sudo's mode/owner:
  3-digit mode → xattrs unrepaired (re-run install-shared.sh);
  `4111 0` → old entrypoint (install a current package); otherwise →
  store without force_mask.
- INSTALL-PACKAGE.md, PROCEDURES.md (E4 + troubleshooting table) updated.

Verified (scratch store, simulated root-owned, fuse-overlayfs 1.10/1.11/1.13,
keep-id, repo's entrypoint mounted over the old image): sudo works, /tmp and
/var/tmp stay 1777 root across repeated writes, `--check` all ok; and
`--check` gives the right advice for the unrepaired and old-entrypoint cases.
Normal (non-shared) storage unchanged. Not done: the Java suite.

Residual on RHEL 8: other directories that root first writes into during a
session (e.g. /opt after `sudo mkdir`) show as `nobody:nobody`. Root can
still write them; it's cosmetic unless something checks dir ownership.

## Still to do

1. Rebuild the image from this branch (entrypoint change), `package.sh`.
2. On a RHEL 8 host with sudo: `sudo ./install-shared.sh` from the package;
   check it prints "Repairing the store's owner/mode xattrs ... fixed N".
   Then as a normal user `rhel9-dev --check` (all ok), and the Java suite
   (`Execution Software/Gen1.5/java/build.sh`), ideally 266/266.
3. dipper: install the new package (re-running the installer repairs its
   existing store in place).
4. Delete this file once verified.

Scratch artifacts from this session were under the session scratchpad
(stores chowned in a user namespace: remove with `podman unshare rm -rf`).
