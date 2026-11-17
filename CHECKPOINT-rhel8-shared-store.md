# Checkpoint: rhel9-dev on RHEL 8 — /tmp and sudo broken in the shared-store image

Written 2026-11-17 on ubuntu-rack (branch `web-dev`, after commit a33ea9a), to
resume on a RHEL 8.10 test host. Claude: read this whole file first, then
start at "Next steps".

## The problem

Seen on dipper-dl380 (RHEL 8.8, rootless podman, image from the shared store
at /var/lib/shared-images loaded by install-shared.sh). That host is NOT
available to us; a similar RHEL 8.10 host stands in for it.

Inside a rhel9-dev container:

| Check | Seen | Expected |
|---|---|---|
| `ls -ld /tmp` | `drwxr-xr-x+ nobody nobody` (0755) | `drwxrwxrwt root root` (1777) |
| `touch /tmp/x` as the user | Permission denied | ok |
| `sudo` | "must be owned by uid 0 and have the setuid bit set" | works |

Impact: the Java core build (`Execution Software/Gen1.5/java/build.sh`)
compiles, but 155/266 JUnit tests fail, all because `/tmp` isn't writable.
That breaks Mockito/ByteBuddy self-attach (98), JUnit `@TempDir` (54), and
jzmq extracting libjzmq.so to tmpdir (3; needs an exec tmpdir). The same tree
passes on bare metal. Note: with Ant 1.10.18, neither `-D` nor `ANT_OPTS`
reach the forked test JVM; only `<jvmarg>` in build.xml does.

`rhel9-dev --check` on dipper printed:

```
engine: podman (rootless)
ok: rhel9-dev comes from the shared image store
ok: you are uid 1000 inside, as on the host
PROBLEM: sudo doesn't work inside (files in the image may show as owned by nobody).
  If the image is in a shared store, it was probably loaded without
  force_mask: an admin re-runs the current install-shared.sh (INSTALL.md).
ok: started and stopped in 8s
```

## Diagnosis so far (a theory, not yet proven on the host)

This is not a Dockerfile problem: `RUN chmod 1777 /tmp` would change nothing,
and the `docker exec` fix in the original report doesn't apply to rootless
podman containers, which are recreated on every start.

install-shared.sh loads the store with `overlay.force_mask=shared`: every
file goes to disk as root-owned **0755**, and its real owner and mode go in a
`user.containers.override_stat` xattr (e.g. `0:0:4755`). The user's rootless
podman mounts the store with fuse-overlayfs (`mount_program` in
/etc/containers/storage.conf), which should show those real values.

The symptoms fit **force_mask applied but the xattr not honored**:
- /tmp shows 0755. Without force_mask it would show 1777 (owned by nobody).
  So force_mask was applied, and the --check message above is misleading.
- sudo's error fits a file that is 0755 with no setuid bit, owned by a uid
  the user namespace doesn't map.

Leading suspect: RHEL 8.8's fuse-overlayfs doesn't read
`user.containers.override_stat`. fuse-overlayfs NEWS first names that xattr
in 1.14 ("prefer user.containers.override_stat over user.fuseoverlayfs.");
1.2 introduced an override xattr, probably `user.fuseoverlayfs.override_stat`,
which older versions may honor only with a mount option such as
`xattr_permissions`. Not verified: the main.c source fetch failed. Also
unchecked: whether fuse-overlayfs keys this on the xattr being present on
each layer's diff root dir, and whether podman 4.4 (RHEL 8.8) sets it there.

dipper's exact package versions are unknown. If someone can run
`rpm -q fuse-overlayfs podman containers-common` there, get it.

## Change made (uncommitted when this was written)

`run.sh` `check()`: the test container now also prints
`stat -c "%a %u" /usr/bin/sudo`. When sudo fails, the message now tells the
two causes apart:
- `755` → "loaded with force_mask, but fuse-overlayfs isn't applying its
  owner/mode xattrs (so /tmp is 0755 too)"
- otherwise (4755 owned by nobody) → the old "loaded without force_mask"
  advice.

Checked with `bash -n` only; not yet run against a real store.

## Next steps (on the RHEL 8.10 host)

1. Install the package from this branch with `install-shared.sh` (see
   INSTALL.md / PROCEDURES.md), then as a normal user run
   `rhel9-dev --check`.
2. Collect:
   ```bash
   rpm -q fuse-overlayfs podman containers-common
   sudo stat -c '%a %U %n' /var/lib/shared-images/overlay/*/diff/usr/bin/sudo
   sudo getfattr -d -m - /var/lib/shared-images/overlay/*/diff/usr/bin/sudo
   sudo getfattr -n user.containers.override_stat /var/lib/shared-images/overlay/*/diff   # layer roots
   podman run --rm rhel9-dev sh -c 'grep fuse /proc/self/mountinfo | head -2; ls -ld /tmp; stat -c "%a %u" /usr/bin/sudo'
   ```
3. Then, depending on what 8.10 shows:
   - **It's broken on 8.10 too:** debug it there. Read fuse-overlayfs's
     behavior for that version (source or `strings`), try
     `user.fuseoverlayfs.override_stat` xattrs and/or a `mountopt` such as
     `xattr_permissions=2`, and check the layer-root xattr.
   - **It works on 8.10:** dipper's older fuse-overlayfs is the likely cause.
     Install the RHEL 8.8-era fuse-overlayfs on this host (8.8 media, or
     another `container-tools` module stream; see
     `dnf module list container-tools`) to reproduce it.
4. Fix it in install-shared.sh (and its storage.conf edit) so it works with
   RHEL 8.8's fuse-overlayfs, since dipper can't be upgraded. Possible
   approaches: also write the xattr name that older fuse-overlayfs reads, set
   a mount option, or a different store layout. Keep the fix working on
   RHEL 9 and newer fuse-overlayfs too. Update INSTALL.md and the --check
   messages to match.
5. Verify: `rhel9-dev --check` all ok; inside the container `/tmp` is 1777
   root, `sudo -n true` works, and ideally the Java suite reaches 266/266.

Stopgap for the Java build meanwhile: point `java.io.tmpdir` at a writable,
exec-allowed directory via `<jvmarg>` in build.xml (plus
`-Djdk.attach.allowAttachSelf=true`).
