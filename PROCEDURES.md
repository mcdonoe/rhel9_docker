# Procedures

Step-by-step instructions for everything this repo does, in the order you
do it. Each step says where it runs, what to type, and how to tell it worked.
For *why* things work the way they do, see [README.md](README.md).

**Contents**

- [A. The big picture](#a-the-big-picture)
- [B. Set up the build machine (once)](#b-set-up-the-build-machine-once)
- [C. Build the images (connected machine)](#c-build-the-images-connected-machine)
- [D. Package and carry them to the air-gapped machine](#d-package-and-carry-them-to-the-air-gapped-machine)
- [E. Install the development image (air-gapped machine)](#e-install-the-development-image-air-gapped-machine)
- [F. Develop in the container](#f-develop-in-the-container)
- [G. Run a Java application as a service (rhel9-runtime)](#g-run-a-java-application-as-a-service-rhel9-runtime)
- [H. Update things](#h-update-things)
- [I. Troubleshooting](#i-troubleshooting)
- [J. Quick reference](#j-quick-reference)

---

## A. The big picture

There are two images and two kinds of machine.

| Image | What it's for | Size |
| --- | --- | --- |
| `rhel9-dev` | Developing and building: compilers, Java 21 + Maven, Node 22 + pnpm, buf, Playwright browsers, the OMP agent, the offline maps, a vendored npm registry and a vendored Maven repository | ~7 GB |
| `rhel9-runtime` | Running a built Java application as a system service: Java 21 runtime and the offline maps, nothing else | ~0.8 GB |

| Machine | What happens there |
| --- | --- |
| **Connected build machine** | Build the images (needs internet: base images, RPMs, npm, maps). Package them into `.tar` files. |
| **Air-gapped machine** | Install the packages. Develop in `rhel9-dev`. Run applications as services in `rhel9-runtime`. No network needed. |

The whole flow:

```
 CONNECTED MACHINE                                     AIR-GAPPED MACHINE
 ─────────────────                                     ──────────────────
 C1 build OMP bundle (omp_distro)
 C2 build rhel9-dev            ─┐
 C3 fetch maps, rebuild         │
 C4 build rhel9-runtime         │
 D1 ./package.sh               ─┼─ dist/rhel9-dev-<date>.tar ────▶ E  install-shared.sh
 D1 ./package.sh --runtime     ─┘  dist/rhel9-runtime-<date>.tar ─▶ G1 install-shared.sh --runtime
                                                                   F  develop, build jars
                                                                   G2 install-shared.sh --app ...
```

Because the air-gapped side has no network, **everything is vendored** into
the images: npm packages, Playwright browsers, map tiles, fonts. Maven
dependencies mostly come from each project's own Maven repository (its
wrappers set `maven.repo.local`); the image adds a small read-only one,
`/opt/maven-repo`, for what those lack (protobuf 4.36, its Maven plugins,
antrun's Ant libraries).

---

## B. Set up the build machine (once)

**Where:** the connected build machine, as your normal user.

1. **Install podman** (or docker): `sudo dnf install podman`.
2. **Check out the repos side by side** in one folder (called `GIT_REPOS`
   here; it can live anywhere):

   ```
   GIT_REPOS/
   ├── rhel9_docker/     this repo
   └── omp_distro/       builds the OMP bundle
   ```

   The scripts find each other through this layout: `build.sh` looks for
   OMP bundles in `../omp_distro/dist/`, and `run.sh` mounts `GIT_REPOS`
   into the container as your work folder.

**Check:** `ls ../omp_distro` from inside `rhel9_docker` lists omp_distro's
files.

---

## C. Build the images (connected machine)

**Where:** inside `GIT_REPOS/rhel9_docker`, as your normal user (not sudo).

### C1. Build the OMP bundle (skip if you already have the bundle you want)

OMP's build runs inside `rhel9-dev`, so the very first time, do C2 first
with no bundle, then come back here.

```
npm_config_registry=https://registry.npmjs.org/ ./run.sh 'cd omp_distro && ./build.sh'
```

The `npm_config_registry` part makes the build use the public npm registry
instead of the image's offline one, which only has the web UI's packages.

**Check:** `ls ../omp_distro/dist/` shows a new
`omp-portable-<version>-<date>-linux-x64.tar.gz`.

### C2. Build rhel9-dev

```
./build.sh
```

It takes the newest OMP bundle from `../omp_distro/dist/` automatically
(use `--omp-bundle PATH` to pick one, or `--no-omp` to leave OMP out). If
the build stops on `can't read maps/ (SELinux? ...)`, you ran the engine by
hand: use `./build.sh`, which passes the needed SELinux option.

**Check:** the build ends with `Built image: rhel9-dev`, and

```
./run.sh 'java -version && node --version && pnpm --version && omp --version'
```

prints Java 21, Node 22, pnpm 12, and the OMP version you built.

### C3. Fetch the offline maps, then rebuild (first time, or to refresh them)

The map tiles are too large for git (about 350 MB), so they're downloaded
into `maps/` and baked in at build time. `fetch-maps.sh` uses the
`pmtiles` tool from `rhel9-dev`, which is why C2 comes first.

```
./fetch-maps.sh --dry-run     # shows the download size; nothing is written
./fetch-maps.sh               # writes maps/eastern-seaboard.pmtiles
./build.sh                    # rebuild so the image includes it
```

Defaults: Maine to the Florida Keys, zoom 0–11. `--maxzoom 12` gives more
street detail at about twice the size (z12 ≈ 800 MB, z13 ≈ 1.7 GB,
z14 ≈ 3.4 GB). `maps/` stays on disk, so later rebuilds include the tiles
without fetching again.

**Check:** `./run.sh 'ls -lh /opt/maps'` lists `eastern-seaboard.pmtiles`
and `basemaps-assets/`.

### C4. Build rhel9-runtime

```
./build.sh --runtime
```

It reuses the same map stage, so build it after C3.

**Check:**

```
podman run --rm rhel9-runtime --version    # Java 21, the same build as rhel9-dev
podman images | grep rhel9                 # rhel9-dev ~7 GB, rhel9-runtime ~0.8 GB
```

---

## D. Package and carry them to the air-gapped machine

**Where:** connected machine, inside `rhel9_docker`.

### D1. Package

```
./package.sh                  # dist/rhel9-dev-<date>.tar      (several GB)
./package.sh --runtime        # dist/rhel9-runtime-<date>.tar  (~480 MB)
```

Each package holds the image, the installer (`install-shared.sh`), an
`INSTALL.md`, a `PACKAGE-INFO` saying exactly what's inside, and
`SHA256SUMS`. Always package from a fresh build; a package made from an
older checkout can carry older docs.

**Check:** `tar -tf dist/rhel9-runtime-<date>.tar` lists `INSTALL.md`,
`install-shared.sh`, `PACKAGE-INFO`, `SHA256SUMS` and the image `.tar.gz`.

### D2. Carry them over

Copy the `.tar` files to the air-gapped machine by whatever transfer
process you use. The installers verify `SHA256SUMS` on arrival, so a
damaged copy is caught before anything is installed.

---

## E. Install the development image (air-gapped machine)

**Where:** the air-gapped machine. Full detail: `INSTALL.md` in the package
(this repo's [INSTALL-PACKAGE.md](INSTALL-PACKAGE.md)).

### E1. Prerequisites (once per machine, as root)

- `dnf install podman fuse-overlayfs` (on RHEL8, fuse-overlayfs usually
  comes with podman). The installer needs it on every RHEL version.
- Every user who'll use the container has `/etc/subuid` and `/etc/subgid`
  entries (`grep "^$USER:" /etc/subuid /etc/subgid`; add with
  `usermod --add-subuids 100000-165535 --add-subgids 100000-165535 <user>`).
- If people run OMP on the host too, the host's OMP must be the same version
  as the image's: `diff OMP-BUILD-INFO /opt/omp/BUILD-INFO` prints nothing.

### E2. Install (as root)

```
tar -xf rhel9-dev-<date>.tar
cd rhel9-dev-<date>
./install-shared.sh
```

This loads the image once into a shared store that every user reads, and
installs the `rhel9-dev` command. It prints each change it makes.

**Short on space in `/var/tmp`?** Loading unpacks the whole image (several
GB) into a temporary folder first, `/var/tmp` by default. Point it at a
bigger filesystem with `--tmpdir`:

```
./install-shared.sh --tmpdir /DATA/tmp
```

The same switch works with `--runtime` (G1).

### E3. Each user, once (as yourself, not sudo)

```
rhel9-dev --check
```

It checks your setup and tells you exactly what to fix if anything's wrong.

**Check:** `--check` ends with everything OK, and `rhel9-dev` opens a shell
in your repo folder within a few seconds.

### E4. If `rhel9-dev` won't start, or `--check` reports a problem

Run these as the user it fails for, and compare with what's expected:

```
grep "^$USER:" /etc/subuid /etc/subgid        # one line from each file
podman info --format '{{.Store.GraphDriverName}} {{json .Store.GraphOptions}}'
                                              # overlay, with overlay.mount_program
                                              #   = /usr/bin/fuse-overlayfs
grep -A3 additionalimagestores /etc/containers/storage.conf
ls ~/.config/containers/storage.conf          # should not exist (it would replace
                                              #   the system file)
```

- **No `fuse-overlayfs` in `podman info`, or `--check` says `sudo doesn't
  work inside`:** the store was set up by an older installer. Re-run the
  current `install-shared.sh` as root. It sets `mount_program` in
  `/etc/containers/storage.conf`, and if the store was loaded without
  `force_mask` it empties it and loads the image again (everyone must be
  out of `rhel9-dev` first). It also repairs the store's owner/mode
  xattrs, which podman 4.x (RHEL 8) writes without setuid bits.
- **`--check` says `/tmp isn't writable inside`** (or sudo fails while
  `/usr/bin/sudo` is mode 4111 owner 0): on RHEL 8, the image is older than
  its entrypoint's fix for RHEL 8's fuse-overlayfs. Install a package built
  from the current repo. To run just the new script from an older
  unpacked package: copy it in over the old one and add `--skip-checksums`.
- **No subuid/subgid line:** add them as in E1, then run
  `podman system migrate` as that user.
- **After changing either,** run `podman system migrate` as the user, then
  `rhel9-dev --check`.

---

## F. Develop in the container

**Where:** any machine with `rhel9-dev` installed, as yourself.

### F1. Start it

```
rhel9-dev                         # shell in your repo base folder
rhel9-dev 'cd myrepo && make'     # run one command and exit
rhel9-dev --omp myrepo            # the OMP coding agent in myrepo
```

(In the git checkout, `./run.sh` is the same command.) Never use `sudo`:
files you create would end up owned by root.

Your repo base folder is mounted at its real host path, so paths are the
same inside and outside the container. It's chosen in this order: `WORKSPACE=`
if set, the checkout's parent folder (when you use `./run.sh`), `~/GIT_REPOS`,
or it asks once and remembers.

The container shares the host's network: a server on port 8080 in the
container is `http://localhost:8080` in the host's browser.

### F2. npm and pnpm (offline, vendored)

`pnpm install` and `pnpm add` work as normal, served from the image's own
registry. What's available is listed in
[npm-vendor/README.md](npm-vendor/README.md) (and in the container at
`/opt/npm-vendor/package.json`).

- A package that isn't vendored fails at once with **404**. To add it, see
  [H3](#h3-add-or-update-npm-packages).
- Don't put `registry=` in a project `.npmrc`: it would bypass the vendored
  registry.
- Commit your project's `pnpm-lock.yaml`.

### F3. Maven

Use your project's own Maven wrappers, which set `maven.repo.local` to the
project's repository. The image also has a read-only repository,
`/opt/maven-repo`, which its global `settings.xml` puts ahead of Central:
protobuf-java and protoc 4.36.2, the xolstice `protobuf-maven-plugin` with
`os-maven-plugin`, and `maven-antrun-plugin` 3.1.0 with its Ant libraries
(list and usage: [maven-vendor/README.md](maven-vendor/README.md)). Maven
copies what it uses from there into your local repository. Your `~/.m2` is
a per-user volume, so it survives between runs.

### F4. Playwright browser tests

Chromium and Firefox are installed in the image, offline.

- Your project's `@playwright/test` must be **exactly** the image's version:
  `rhel9-dev 'echo $RHEL9DEV_PLAYWRIGHT_VERSION'` (currently 1.64.1).
  Anything else fails with `Executable doesn't exist at /opt/ms-playwright/...`.
- Configure only the `chromium` and `firefox` projects; WebKit isn't
  available on RHEL9.
- Tests run headless. Headless Firefox in the container has no WebGL2, so a
  MapLibre map won't render there; Chromium renders it.

### F5. Offline maps

The tiles, fonts and sprites are at `/opt/maps` in both images. Serve that
folder from your app (with HTTP range requests, which PMTiles needs) and point
the MapLibre style's `pmtiles://` source, `glyphs` and `sprite` URLs at it.
The styles come from the vendored `@protomaps/basemaps` npm package. The
map must show "© OpenStreetMap contributors".

`../web_test` is a complete working example of all of F2–F5 (React UI,
Spring Boot bridge, Playwright test, offline map); see its README.

---

## G. Run a Java application as a service (rhel9-runtime)

**The idea:** the application isn't in the image. You build its jars in
`rhel9-dev`, your deployment puts them in folders on the host (for example
`/OUTPUT/web/output_libs` for your own jars and `/OUTPUT/web/cots_libs` for
third-party jars), and a systemd service runs them in `rhel9-runtime`. To
deploy a new build you replace the jars and restart the service; the image
and service stay as they are.

**Where:** the machine that runs the service, as root. Full option list:
`INSTALL.md` in the runtime package (this repo's
[INSTALL-RUNTIME.md](INSTALL-RUNTIME.md)).

### G1. Install the runtime image (once, and for each new package)

```
tar -xf rhel9-runtime-<date>.tar
cd rhel9-runtime-<date>
./install-shared.sh --runtime
```

It loads the image into root's podman storage (separate from the shared
store in E) and installs the installer to `/opt/rhel9-runtime/`. Add
`--tmpdir /DATA/tmp` if `/var/tmp` is short of space (about 1 GB needed).

**Check:** it prints the image's Java version (21).

### G2. Put the jars in place

Build in `rhel9-dev`, then copy:

- **your application's jars** (thin jars, not a Spring Boot fat jar: use
  `target/*.jar.original` if the Spring Boot plugin repackaged it) into
  one folder, e.g. `/OUTPUT/web/output_libs`
- **all third-party jars** into another, e.g. `/OUTPUT/web/cots_libs`. In
  Maven:
  ```
  mvn -pl <module> -am package dependency:copy-dependencies \
      -DincludeScope=runtime -DexcludeGroupIds=<your.group.id> \
      -DoutputDirectory=/OUTPUT/web/cots_libs
  ```

The service runs as `nobody` by default, so the folders and jars must be
readable by everyone: `chmod -R a+rX /OUTPUT/web`.

### G3. Create the service

```
/opt/rhel9-runtime/install-shared.sh --app web-bridge \
    --classpath /OUTPUT/web/output_libs:/OUTPUT/web/cots_libs \
    --main com.example.bridge.BridgeApplication \
    --start
```

Common additions:

| Add | When |
| --- | --- |
| `--mount /OUTPUT/web/config` | The app reads another host folder (config, a built web UI, data). Read-only, same path. Repeatable. |
| `--mount-rw /var/log/web-bridge` | The app writes to a host folder. Must be writable by the service's user. |
| `--args "--server.port=8080"` | Arguments to the main class |
| `--java-opts "-Xmx2g"` | JVM options |
| `--env NAME=VALUE` | An environment variable. Repeatable. |
| `--user 1000:1000` | Run as someone other than `nobody` |
| `--unit-dir /tmp/review` | Write the unit file there and change nothing, so you can read it first |

The service uses the host's network (so it reaches the backend's ZMQ ports
on `localhost` and serves its own port directly), starts at boot, and
restarts if it crashes. On podman 4.4 or newer it's a quadlet in
`/etc/containers/systemd/NAME.container`; on older podman, a plain
`/etc/systemd/system/NAME.service`. Both behave the same.

**Check:**

```
systemctl status web-bridge        # active (running)
journalctl -u web-bridge -f        # first line: run-app: java -cp ... ; then the app's log
```

### G4. Day-to-day

| Task | Command |
| --- | --- |
| Deploy a new build | Replace the jars, then `systemctl restart web-bridge` |
| Change options | Run the same `--app` command with the new options; it shows a diff of the unit |
| Stop / start | `systemctl stop web-bridge` / `systemctl start web-bridge` |
| Remove the service | `/opt/rhel9-runtime/install-shared.sh --remove-app web-bridge` (jars are left alone) |

---

## H. Update things

### H1. A new OMP version

1. Connected machine: C1 (build the bundle), C2 (`./build.sh`), D1
   (`./package.sh`).
2. Air-gapped machine: upgrade the host's OMP to the same version, then E2
   with the new package.
3. Once nobody is in a `rhel9-dev` container, delete the old image:
   `/opt/rhel9-dev/install-shared.sh --prune`.

### H2. A new rhel9-dev image (any other change)

Same as H1 without the OMP steps: `./build.sh`, `./package.sh`, then
`./install-shared.sh` from the new package, then `--prune` later. Users get
the new image the next time they start `rhel9-dev`.

### H3. Add or update npm packages

On the connected machine, in the container, against the public registry:

```
./run.sh
cd rhel9_docker/npm-vendor
export pnpm_config_registry=https://registry.npmjs.org/
pnpm add --save-exact --ignore-scripts <package>             # -D for build tools
pnpm update --save-exact --ignore-scripts <package>@<ver>    # update one
exit
```

Then rebuild (C2), commit `npm-vendor/package.json` and `pnpm-lock.yaml`,
and ship the new image (D, E). Only versions at least 14 days old can be
vendored. Keep `@playwright/test` at the image's Playwright version.

### H4. Upgrade Playwright

Change `PLAYWRIGHT_VERSION` in the `Dockerfile` and `@playwright/test` in
`npm-vendor/package.json` (H3) to the same version, rebuild, and update
every project's `@playwright/test` to match at the same time.

### H5. Refresh the maps

`./fetch-maps.sh` (C3), then rebuild **both** images (C2, C4) and ship both
(D, E, G1).

### H6. A new rhel9-runtime image

1. Connected: `./build.sh --runtime`, `./package.sh --runtime`.
2. Target, as root: `./install-shared.sh --runtime` from the new package. It
   lists the services; each keeps running the old image until restarted.
3. `systemctl restart <each service>`
4. `/opt/rhel9-runtime/install-shared.sh --runtime --prune` deletes the old
   image.

---

## I. Troubleshooting

| You see | Cause | Fix |
| --- | --- | --- |
| `creating container storage: error during chown: storage-chown-by-maps: lchown ...: operation not permitted` when starting `rhel9-dev` | podman isn't using fuse-overlayfs with the shared store (installers before Nov 2026 didn't set it on RHEL8), and/or the image has files owned by the build user (images before Nov 2026: `/opt/omp`) | Install a current package with `./install-shared.sh` (it sets `mount_program`), then `rhel9-dev --check`. See [E4](#e4-if-rhel9-dev-wont-start-or---check-reports-a-problem) |
| `no space left on device` while `install-shared.sh` loads the image | podman unpacks the image into `/var/tmp` first | Re-run with `--tmpdir /DATA/tmp` (any folder with room for the full image) |
| `--check`: `PROBLEM: sudo doesn't work inside (/usr/bin/sudo is mode 755 ...)`, or inside the container `/tmp` is `drwxr-xr-x` and sudo says `must be owned by uid 0 and have the setuid bit set` | The shared store's owner/mode xattrs are as podman 4.x (RHEL 8) writes them with `force_mask`: no setuid or sticky bits, and none on the layer roots, so fuse-overlayfs ignores them all | Re-run the current `install-shared.sh` as root (it repairs them in place, no reload); see [E4](#e4-if-rhel9-dev-wont-start-or---check-reports-a-problem) |
| `--check`: `PROBLEM: sudo doesn't work inside (/usr/bin/sudo is mode 4111, owner uid 0)`, sudo says `/etc/sudoers.d is owned by uid 65534`, or `/tmp` turns `drwxr-xr-x nobody nobody` after the first file is created in it (Java tests: `@TempDir`, Mockito self-attach fail) | RHEL 8's fuse-overlayfs (before 1.14) copies a directory into the container's writable layer with its owner and mode on disk in the shared store (nobody, 0755), and the image's entrypoint predates the fix for that | Build a package from the current repo and install it; see [E4](#e4-if-rhel9-dev-wont-start-or---check-reports-a-problem) |
| `--check`: `PROBLEM: sudo doesn't work inside (/usr/bin/sudo is mode 4111, owner uid 65534)` | The shared store was loaded without `force_mask = "shared"`, so rootless users see its root-owned files (`/usr/bin/sudo` included) as owned by nobody | Re-run the current `install-shared.sh` as root; see [E4](#e4-if-rhel9-dev-wont-start-or---check-reports-a-problem) |
| `can't read maps/ (SELinux? ...)` during a build | The engine was run by hand without `--security-opt label=disable` | Build with `./build.sh` |
| `404` from `pnpm install` / `pnpm add` | The package (or that version) isn't vendored | Use a vendored version, or add it (H3). On a connected machine you can use `npm_config_registry=https://registry.npmjs.org/ ./run.sh ...` |
| omp_distro's build fails fetching npm packages | It needs the public registry, not the vendored one | Prefix with `npm_config_registry=https://registry.npmjs.org/` (C1) |
| `Executable doesn't exist at /opt/ms-playwright/...` | The project's `@playwright/test` isn't the image's version | Pin it to `$RHEL9DEV_PLAYWRIGHT_VERSION` |
| Map shows "Map unavailable" in Firefox tests | Headless Firefox in the container has no WebGL2 | Expected; check the map in Chromium |
| `run-app: /OUTPUT/... doesn't exist in the container: is it mounted, and readable by uid 65534?` | A classpath folder is missing, or not readable by the service user | Check the path, then `chmod -R a+rX` the folder |
| `run-app: no .jar files in /OUTPUT/...` | The folder exists but is empty | Copy the jars in (G2) and restart |
| Service starts, then `ClassNotFoundException` | A jar is missing, or the app jar is a Spring Boot fat jar | Use the thin jar (`*.jar.original`) plus the third-party jars folder (G2) |
| Port already in use | Two services (or a dev server) on one port; the host network is shared | Change one with `--args "--server.port=..."` |
| `rhel9-dev` is slow to start, or `--check` complains | See `rhel9-dev --check`'s output; it says what to fix | |

More, for podman, SELinux and DHCP: [README.md](README.md#troubleshooting).

---

## J. Quick reference

```
# --- connected machine, in rhel9_docker -------------------------------------
npm_config_registry=https://registry.npmjs.org/ ./run.sh 'cd omp_distro && ./build.sh'
./fetch-maps.sh                         # only first time / to refresh
./build.sh                              # rhel9-dev
./build.sh --runtime                    # rhel9-runtime
./package.sh                            # dist/rhel9-dev-<date>.tar
./package.sh --runtime                  # dist/rhel9-runtime-<date>.tar

# --- air-gapped machine, as root --------------------------------------------
./install-shared.sh                     # in the unpacked rhel9-dev package
                                        #   (add --tmpdir /DATA/tmp if /var/tmp is small)
./install-shared.sh --runtime           # in the unpacked rhel9-runtime package
/opt/rhel9-runtime/install-shared.sh --app NAME \
    --classpath /OUTPUT/web/output_libs:/OUTPUT/web/cots_libs \
    --main CLASS [--mount DIR] [--args "..."] [--java-opts "..."] --start
/opt/rhel9-dev/install-shared.sh --prune            # after a rhel9-dev update
/opt/rhel9-runtime/install-shared.sh --runtime --prune   # after a runtime update

# --- air-gapped machine, as yourself ----------------------------------------
rhel9-dev --check                       # once
rhel9-dev                               # shell
rhel9-dev --omp REPO                    # OMP agent

# --- services ---------------------------------------------------------------
systemctl status|restart|stop NAME
journalctl -u NAME -f
```
