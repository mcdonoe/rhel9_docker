# Installing the rhel9-runtime package

This package holds a prebuilt `rhel9-runtime` image: a minimal RHEL9 (UBI9)
with a Java 21 runtime and the offline map data, for running a built Java
application, such as the WebSocket bridge, as a system service. Installing
it needs no network.

The application itself isn't in the image. Its jars stay on the host,
wherever your deployment puts them (for example `/OUTPUT/web/output_libs`
and `/OUTPUT/web/cots_libs`), and the service mounts those folders into the
container read-only, at the same paths, and starts the main class with every
jar in them on the classpath. Deploying a new build is copying in new jars
and restarting the service; the image and the service don't change.

| File | What it is |
| --- | --- |
| `install-shared.sh` | Installs the image (step 2) and writes each application's service (step 3) |
| `rhel9-runtime-image.tar.gz` | The image, as written by `docker save` (linux/amd64) |
| `PACKAGE-INFO` | Which image, repo commit and Java version this package is |
| `SHA256SUMS` | Checksums for the files above |

In short, as root:

```
tar -xf rhel9-runtime-<date>.tar && cd rhel9-runtime-<date>
./install-shared.sh --runtime
/opt/rhel9-runtime/install-shared.sh --app web-bridge \
    --classpath /OUTPUT/web/output_libs:/OUTPUT/web/cots_libs \
    --main com.example.bridge.Main --start
```

## 1. Prerequisites (once per machine, as root)

- **x86_64.** The image is amd64 only.
- **podman:** `dnf install podman` (or `container-tools`), from the host's
  RHEL repos or install media.
- **For quadlet services, podman 4.4 or later** (RHEL 8.8+, RHEL 9.2+).
  Check with `podman --version`. On older podman, `--app` writes a plain
  systemd unit that calls `podman run` instead; it behaves the same.

## 2. Install the image (as root)

```
./install-shared.sh --runtime
```

It checks the package against `SHA256SUMS`, loads the image into root's
podman storage (system services run as root's podman), prints the image's
Java version, and installs `install-shared.sh` and these docs to
`/opt/rhel9-runtime`. Safe to re-run.

This doesn't touch the shared image store or `storage.conf` that the
`rhel9-dev` package sets up; the two packages can share a host.

## 3. Add an application (as root)

```
/opt/rhel9-runtime/install-shared.sh --app NAME \
    --classpath DIR[:DIR...] --main CLASS [options]
```

This writes the service `NAME`, starts it at boot from then on, and with
`--start` starts it now:

| Option | What it sets |
| --- | --- |
| `--classpath LIST` | Folders (every `*.jar` in each) and/or single `.jar` files, colon-separated, in classpath order |
| `--main CLASS` | The main class |
| `--args "ARGS"` | Arguments to it, e.g. `"--spring.config.additional-location=/OUTPUT/web/config/"` |
| `--java-opts "OPTS"` | JVM options, e.g. `"-Xmx2g -XX:+UseZGC"` |
| `--env NAME=VALUE` | An environment variable (repeatable) |
| `--mount DIR` | Another folder, read-only at the same path: config, a UI folder, data (repeatable) |
| `--mount-rw DIR` | A writable folder, e.g. for logs or saved state (repeatable) |
| `--user UID[:GID]` | Who the application runs as (default 65534, `nobody`) |
| `--workdir DIR` | Its working directory (default `/tmp`) |
| `--start` | Start it now, or restart it if it's running |

The container uses the host's network, so the application reaches the
backend's ZMQ ports on `localhost` and serves its own port (e.g. 8080)
directly on the host. The map data is in the image at `/opt/maps`.

Example: the WebSocket bridge, with its config in a folder of its own:

```
/opt/rhel9-runtime/install-shared.sh --app web-bridge \
    --classpath /OUTPUT/web/output_libs:/OUTPUT/web/cots_libs \
    --main com.example.bridge.BridgeApplication \
    --mount /OUTPUT/web/config \
    --args "--spring.config.additional-location=/OUTPUT/web/config/" \
    --java-opts "-Xmx2g" --start
```

**Permissions.** The application runs as `--user` (default `nobody`), so
the jar folders and anything under `--mount` must be readable by it
(world-readable is simplest), and `--mount-rw` folders writable by it.
SELinux labels are ignored for these mounts, as for `rhel9-dev`.

To change a service, run `--app` again with the new options: it shows what
changed. `--remove-app NAME` stops and deletes a service, leaving its jars
alone.

## 4. Run it

```
systemctl status web-bridge          is it running?
journalctl -u web-bridge -f          its log (the first line shows the classpath)
systemctl restart web-bridge         after deploying new jars
systemctl stop web-bridge
```

If a classpath folder is missing or unreadable, the log says which one,
e.g. `run-app: /OUTPUT/web/cots_libs doesn't exist in the container: is it
mounted, and readable by uid 65534?`

## Updating the image

Install the newer package the same way (`./install-shared.sh --runtime`).
It lists the application services; each keeps running the old image until
restarted. Restart them, then delete the old image:

```
systemctl restart web-bridge
/opt/rhel9-runtime/install-shared.sh --runtime --prune
```

The application's jars must suit the image's Java (21; see `PACKAGE-INFO`).
