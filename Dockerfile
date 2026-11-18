# syntax=docker/dockerfile:1.7
#
# RHEL9 (UBI9) general-purpose development environment.
# Builds under docker or podman; see build.sh.
# Build:  ./build.sh                     (free repos only)
#         ./build.sh --subscription      (also registers with Red Hat during
#                                          the build, using build secrets)
# Run:    docker run -it --rm -v "$HOME/GIT_REPOS:/workspace" rhel9-dev bash
#
# Three stages:
#   maps     the offline map data, shared by both images below
#   runtime  rhel9-runtime: Java 21 runtime + maps, for running a built
#            application as a system service (./build.sh --runtime)
#   dev      rhel9-dev: the full development environment (the default)

# ---------------------------------------------------------------------------
# Offline maps for MapLibre, in /opt/maps:
#   - basemaps-assets/: the fonts (glyph PBFs) and sprites that Protomaps'
#     map styles use, pinned to one commit. Without local glyphs, map labels
#     fail offline. The style itself comes from the vendored npm package
#     @protomaps/basemaps.
#   - eastern-seaboard.pmtiles: the map tiles, if ./fetch-maps.sh has put
#     them in maps/ (they're too big for git). Otherwise this is skipped and
#     the images build without them, as with the OMP bundle.
# ---------------------------------------------------------------------------
FROM docker.io/redhat/ubi9 AS maps

ARG BASEMAPS_ASSETS_COMMIT=028c18f713baecad011301ff7a69acc39bcc2ae7
ARG BASEMAPS_ASSETS_SHA256=57e40e8c512bd8042d0a3a251f19d0d1c8523ad963c666c3c6643bada4dc92d0

RUN set -eux; \
    curl -fsSL -o /tmp/assets.tar.gz \
        "https://github.com/protomaps/basemaps-assets/archive/${BASEMAPS_ASSETS_COMMIT}.tar.gz"; \
    echo "${BASEMAPS_ASSETS_SHA256}  /tmp/assets.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/maps/basemaps-assets; \
    tar -xzf /tmp/assets.tar.gz -C /opt/maps/basemaps-assets --strip-components=1 \
        --wildcards '*/fonts' '*/sprites' '*/README.md'; \
    rm /tmp/assets.tar.gz

RUN --mount=type=bind,source=maps,target=/mnt/maps \
    set -eux; \
    ls /mnt/maps >/dev/null || { echo "error: can't read maps/ (SELinux? build with ./build.sh)" >&2; exit 1; }; \
    if [ -f /mnt/maps/eastern-seaboard.pmtiles ]; then \
        cp /mnt/maps/eastern-seaboard.pmtiles /mnt/maps/eastern-seaboard.json /opt/maps/; \
    else \
        echo "No maps/eastern-seaboard.pmtiles staged (see fetch-maps.sh); building without map tiles."; \
    fi; \
    chmod -R a+rX /opt/maps

# ---------------------------------------------------------------------------
# rhel9-runtime: runs one built Java application, as a system service. The
# application's jars stay on the host and are mounted read-only at their
# host paths; run-app puts every jar in the folders listed in APP_CLASSPATH
# on the classpath and starts MAIN_CLASS. install-shared.sh --app writes the
# service. No compilers, build tools, Node or browsers: only what running
# needs.
# ---------------------------------------------------------------------------
FROM docker.io/redhat/ubi9-minimal AS runtime

LABEL description="RHEL9 UBI minimal runtime: OpenJDK 21 (headless) and offline map data, for running a built Java application" \
      rhel9-dev.image=runtime

RUN microdnf install -y --nodocs --setopt=install_weak_deps=0 \
        java-21-openjdk-headless tzdata \
    && microdnf clean all

COPY --from=maps /opt/maps /opt/maps
COPY --chmod=755 run-app.sh /usr/local/bin/run-app

# Unprivileged by default; the service can choose another user (--user).
USER 65534:65534
WORKDIR /tmp
ENTRYPOINT ["/usr/local/bin/run-app"]

# ---------------------------------------------------------------------------
# rhel9-dev: the development environment. Last, so it's the default target.
# ---------------------------------------------------------------------------
FROM redhat/ubi9 AS dev

LABEL description="RHEL9 UBI dev environment: gcc-toolset 12/14/15, Python 3.11/3.12/3.14, Go + gopls/delve, OpenJDK 21 + Ant + Maven 3.9 (+ vendored Maven repo), Node.js 22 + pnpm, buf, Playwright (Chromium, Firefox), Boost 1.81, cmake/make, btop, vim, opt-in dnsmasq DHCP server, optional OMP coding agent"

# ---------------------------------------------------------------------------
# Container-engine neutrality (podman vs docker).
#
# On a subscribed RHEL host, podman bind-mounts the host's subscription
# secrets into every container: /usr/share/containers/mounts.conf maps
# /usr/share/rhel/secrets -> /run/secrets. That makes UBI's /etc/rhsm-host and
# /etc/pki/entitlement-host symlinks resolve to real directories, which is
# exactly how rhsm.config.in_container() decides it is running in a container,
# and that flips subscription-manager into "container mode":
#
#   - the CLI hard-exits 78 (EX_CONFIG) on *every* subcommand, so the
#     --subscription register below dies under `set -eux`
#   - its dnf plugin regenerates /etc/yum.repos.d/redhat.repo from the host's
#     entitlement certs, enabling rhel-9-for-x86_64-{baseos,appstream}-rpms
#     with sslverifystatus=1; cdn.redhat.com serves no OCSP response, so dnf
#     fails with curl error 91 and even the plain build dies
#
# Docker/BuildKit has no equivalent auto-mount, which is why this only bites
# on podman. Dropping the two symlinks makes both engines behave identically.
# On docker they are dangling anyway, so this is a no-op there.
#
# Trade-off: containers from this image can no longer borrow a RHEL host's
# entitlements at runtime. Nothing installed below needs them.
# ---------------------------------------------------------------------------
RUN rm -f /etc/rhsm-host /etc/pki/entitlement-host

# ---------------------------------------------------------------------------
# Package installs.
#
# Everything below resolves from the free UBI AppStream/BaseOS/CodeReady
# Builder repos (already enabled in this base image) plus EPEL, with three
# exceptions installed by hand further down: Apache Ant and the uv Python
# installer aren't packaged for RHEL9 at all, and Go comes from the upstream
# release tarball rather than RHEL's go-toolset (see the Go section).
#
# subscription-manager registration is wired in and OPTIONAL: if you build
# with `--secret id=rh_username --secret id=rh_password` (see build.sh), this
# step registers, installs, and unregisters within a single RUN so no consumer
# certs or credentials persist in any image layer. Without those secrets it's
# skipped entirely — nothing in this package list actually needs it.
# ---------------------------------------------------------------------------
RUN --mount=type=secret,id=rh_username \
    --mount=type=secret,id=rh_password \
    set -eux; \
    REGISTERED=0; \
    if [ -s /run/secrets/rh_username ] && [ -s /run/secrets/rh_password ]; then \
        subscription-manager register \
            --username="$(cat /run/secrets/rh_username)" \
            --password="$(cat /run/secrets/rh_password)" \
            --auto-attach; \
        REGISTERED=1; \
    else \
        echo "No rh_username/rh_password secrets supplied; building from free UBI + EPEL repos only."; \
    fi; \
    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm; \
    /usr/bin/crb enable; \
    # Node.js 22 and Maven 3.9 are module streams. Without enabling them dnf
    # installs RHEL9's defaults: an end-of-life Node.js and Maven 3.6.
    dnf module enable -y nodejs:22 maven:3.9; \
    dnf install -y \
        # --- version control / build systems ---
        git git-lfs cmake make patch \
        # --- C/C++ toolchains: gcc 12, 14 and 15 side by side, 12 active by default ---
        gcc-toolset-12 gcc-toolset-12-gdb \
        gcc-toolset-14 \
        gcc-toolset-15 \
        gdb \
        # --- autotools, commonly paired with cmake/make C/C++ projects ---
        autoconf automake libtool pkgconf-pkg-config \
        # --- compression libs for Boost.Iostreams (Boost is built below) ---
        bzip2 bzip2-devel zlib-devel xz-devel libzstd-devel \
        # --- C/C++ libraries with headers and pkg-config files: ZeroMQ 4.3
        #     and CZMQ 4.2 (EPEL; pull in libsodium, openpgm, krb5 -devel),
        #     OpenSSL 3, log4cxx 1.x (EPEL). zlib-devel is above; Eigen 3
        #     is installed from source below (RHEL has it only in the
        #     subscription-only CodeReady Builder repo) ---
        zeromq-devel czmq-devel openssl-devel log4cxx-devel \
        # --- Python ---
        python3.11 python3.11-devel python3.11-pip \
        python3.12 python3.12-devel python3.12-pip \
        python3.14 python3.14-devel python3.14-pip \
        # --- Java 21: jmods for jlink/jpackage, Maven 3.9 (Ant is installed by hand below) ---
        java-21-openjdk-devel java-21-openjdk-jmods maven-openjdk21 \
        # --- web: Node.js 22 + npm; nodejs-devel holds the headers node-gyp
        #     needs to build native npm packages without downloading them ---
        nodejs npm nodejs-devel \
        # --- packaging builds as RPMs ---
        rpm-build \
        # --- libraries and fonts Playwright's Chromium and Firefox need
        #     (Playwright's own install-deps only knows apt) ---
        nss nspr atk at-spi2-atk at-spi2-core cups-libs libdrm libxkbcommon \
        mesa-libgbm alsa-lib cairo-gobject gtk3 dbus-glib dbus-libs libatomic \
        libX11 libX11-xcb libxcb libXcomposite libXcursor libXdamage libXext \
        libXfixes libXi libXrandr libXrender libXtst libxshmfence \
        fontconfig freetype liberation-fonts-common liberation-mono-fonts \
        dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts \
        # --- native libs needed by common Python packages (e.g. WeasyPrint) ---
        cairo pango gdk-pixbuf2 libffi-devel \
        # --- editor / terminal tooling ---
        vim-enhanced btop ripgrep fd-find jq \
        # --- general shell/dev utilities ---
        sudo which findutils procps-ng tar gzip unzip xz wget openssh-clients \
        file \
        glibc-langpack-en \
        # --- DHCP server, opt-in at runtime (see dnsmasq/ + README) ---
        dnsmasq \
    && dnf clean all; \
    if [ "$REGISTERED" = "1" ]; then \
        subscription-manager unregister; \
        subscription-manager clean; \
    fi

# ---------------------------------------------------------------------------
# Apache Ant — dropped from RHEL9/EPEL9 packaging, install the official
# binary release by hand. Checksum pinned against a version bump by accident.
# ---------------------------------------------------------------------------
# downloads.apache.org only keeps the latest release, so an outdated pin
# fails with a 404 rather than silently building something else.
ARG ANT_VERSION=1.10.18
ARG ANT_SHA512=c510d744876d8da48dabc9495b023b6ec5284a0f18b40ee50d98ce099e791ca5c73e3cd4c80d3c90d3efc03f9620be43aad0a373ed47198284f7e3373e0db2c3

RUN set -eux; \
    curl -fsSL -o /tmp/ant.tar.gz \
        "https://downloads.apache.org/ant/binaries/apache-ant-${ANT_VERSION}-bin.tar.gz"; \
    echo "${ANT_SHA512}  /tmp/ant.tar.gz" | sha512sum -c -; \
    mkdir -p /opt/ant; \
    tar -xzf /tmp/ant.tar.gz -C /opt/ant --strip-components=1; \
    rm /tmp/ant.tar.gz; \
    ln -s /opt/ant/bin/ant /usr/local/bin/ant

# ---------------------------------------------------------------------------
# uv — fast Python package/venv manager, not packaged for RHEL9. RouteLM
# (in your GIT_REPOS) uses it for dependency resolution via uv.lock.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# ---------------------------------------------------------------------------
# pnpm — not packaged for RHEL. The official standalone build (it carries
# its own Node.js, so it doesn't depend on the system one), checksum pinned.
# The binary needs the dist/ directory beside it, so the whole release goes
# in /opt/pnpm. Bump PNPM_VERSION/PNPM_SHA256 together; GitHub shows each
# release asset's sha256 digest. Projects pin their own pnpm version with
# "packageManager" in package.json; keep this in step with that.
#
# Each user's package store defaults to ~/.local/share/pnpm/store, which
# run.sh keeps in a per-user named volume.
# ---------------------------------------------------------------------------
ARG PNPM_VERSION=12.16.1
ARG PNPM_SHA256=565ff81174a14f6f7bd5d84c1b17e51031a80230d370a1fe24be5d16bd02a825

RUN set -eux; \
    curl -fsSL -o /tmp/pnpm.tar.gz \
        "https://github.com/pnpm/pnpm/releases/download/v${PNPM_VERSION}/pnpm-linux-x64.tar.gz"; \
    echo "${PNPM_SHA256}  /tmp/pnpm.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/pnpm; \
    tar -xzf /tmp/pnpm.tar.gz -C /opt/pnpm; \
    rm /tmp/pnpm.tar.gz; \
    chown -R root:root /opt/pnpm; \
    ln -s /opt/pnpm/pnpm /usr/local/bin/pnpm; \
    [ "$(pnpm --version)" = "${PNPM_VERSION}" ]

# ---------------------------------------------------------------------------
# Playwright, vendored: its browsers live in the image, so browser tests run
# with no network. Playwright only supports Ubuntu/Debian officially, but
# its Chromium and Firefox run on UBI9 with the libraries installed above.
# WebKit doesn't: it's built against Ubuntu 24.04's exact library versions
# (ICU 74, GTK4, GStreamer, WPE...), so it isn't installed.
#
# Browser builds are tied to the Playwright version, so a project must use
# exactly PLAYWRIGHT_VERSION for its @playwright/test devDependency. A
# mismatch fails with "Executable doesn't exist at /opt/ms-playwright/...".
# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD stops package installs from fetching
# browsers. The `playwright` CLI is also installed globally, for
# `playwright --version` and codegen-free one-offs.
#
# The last step launches both browsers and renders a page, so a build that
# succeeds is known to run them.
# ---------------------------------------------------------------------------
ARG PLAYWRIGHT_VERSION=1.64.1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
    RHEL9DEV_PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION}

RUN set -eux; \
    npm install -g --no-fund --no-audit "playwright@${PLAYWRIGHT_VERSION}"; \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD= playwright install chromium chromium-headless-shell firefox; \
    chmod -R a+rX /opt/ms-playwright; \
    rm -rf /root/.npm; \
    NODE_PATH="$(npm root -g)" node -e ' \
        const pw = require("playwright"); \
        (async () => { for (const n of ["chromium", "firefox"]) { \
            const b = await pw[n].launch(); const p = await b.newPage(); \
            await p.setContent("<p id=x>ok</p>"); \
            if (await p.textContent("#x") !== "ok") throw new Error(n); \
            console.log(n, b.version(), "ok"); await b.close(); } })() \
        .catch(e => { console.error(e); process.exit(1); });'

# ---------------------------------------------------------------------------
# Boost — built from the official source release, checksum pinned. RHEL9
# only packages 1.75 (boost-devel), so it isn't installed and can't clash.
#
# Installed under /usr/local (headers in include/, libs in lib64/, both
# shared and static, release + multithreaded), so gcc finds the headers with
# no -I, ld finds the libs with no -L, CMake finds it with
# find_package(Boost 1.81 CONFIG), and ld.so finds the .so files through
# the ld.so.conf.d entry below. Built with gcc-toolset-12, the image's
# default; the libraries work from gcc-toolset-14/15 too.
#
# Left out: Boost.Python (it would tie the build to one of the three
# Pythons) and Boost.MPI/Graph.Parallel (no MPI in the image).
# Bump BOOST_VERSION/BOOST_SHA256 together; the sha256 is published next to
# each tarball as boost_X_Y_Z.tar.bz2.json.
# ---------------------------------------------------------------------------
ARG BOOST_VERSION=1.81.0
ARG BOOST_SHA256=71feeed900fbccca04a3b4f2f84a7c217186f28a940ed8b7ed4725986baf99fa

RUN set -eux; \
    v="${BOOST_VERSION//./_}"; \
    curl -fsSL -o /tmp/boost.tar.bz2 \
        "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${v}.tar.bz2"; \
    echo "${BOOST_SHA256}  /tmp/boost.tar.bz2" | sha256sum -c -; \
    tar -xjf /tmp/boost.tar.bz2 -C /tmp; \
    rm /tmp/boost.tar.bz2; \
    cd "/tmp/boost_${v}"; \
    set +u; source /opt/rh/gcc-toolset-12/enable; set -u; \
    ./bootstrap.sh --with-toolset=gcc \
        --without-libraries=python,mpi,graph_parallel; \
    ./b2 -j"$(nproc)" -d0 \
        toolset=gcc variant=release threading=multi link=shared,static \
        --prefix=/usr/local --libdir=/usr/local/lib64 install; \
    cd /; \
    rm -rf "/tmp/boost_${v}"; \
    echo /usr/local/lib64 > /etc/ld.so.conf.d/usr-local-lib64.conf; \
    ldconfig; \
    grep -q "define BOOST_LIB_VERSION \"${v%_0}\"" /usr/local/include/boost/version.hpp

# ---------------------------------------------------------------------------
# Protocol Buffers 3.15.6 — protoc and the C++ runtime (libprotobuf,
# libprotobuf-lite, libprotoc), built from the official protobuf-cpp source
# release, checksum pinned. RHEL9's own protobuf packages aren't installed,
# so nothing clashes.
#
# Installed under /usr/local like Boost: protoc in bin/, headers in
# include/google/protobuf, shared and static libs in lib64/, pkg-config
# files (pkg-config --cflags --libs protobuf), and CMake's
# find_package(Protobuf) finds it. Built with gcc-toolset-12. protoc also
# generates Java, Python, etc.; the language runtimes for those come from
# each project (e.g. protobuf-java 3.15.x from the project's Maven repo).
# Bump PROTOBUF_VERSION/PROTOBUF_SHA256 together.
# ---------------------------------------------------------------------------
ARG PROTOBUF_VERSION=3.15.6
ARG PROTOBUF_SHA256=bbdfb7455431d7d58666e8a2996d14b236718ff238eecde10646581e4c87f168

RUN set -eux; \
    curl -fsSL -o /tmp/protobuf.tar.gz \
        "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_VERSION}/protobuf-cpp-${PROTOBUF_VERSION}.tar.gz"; \
    echo "${PROTOBUF_SHA256}  /tmp/protobuf.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/protobuf.tar.gz -C /tmp --no-same-owner; \
    rm /tmp/protobuf.tar.gz; \
    cd "/tmp/protobuf-${PROTOBUF_VERSION}"; \
    set +u; source /opt/rh/gcc-toolset-12/enable; set -u; \
    ./configure --quiet --prefix=/usr/local --libdir=/usr/local/lib64; \
    make -s -j"$(nproc)"; \
    make -s install; \
    cd /; \
    rm -rf "/tmp/protobuf-${PROTOBUF_VERSION}"; \
    ldconfig; \
    protoc --version | grep -qx "libprotoc ${PROTOBUF_VERSION}"; \
    PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig pkg-config --modversion protobuf | grep -qx "${PROTOBUF_VERSION}"

# ---------------------------------------------------------------------------
# Eigen 3 (header-only C++ linear algebra), from the official source
# release, checksum pinned. RHEL 9 ships eigen3-devel only in CodeReady
# Builder, which needs a subscription, and this build must also work from
# UBI + EPEL alone; same version as RHEL's (3.4.0).
#
# Installed under /usr/local like Boost: headers in include/eigen3,
# pkg-config file in lib64/pkgconfig (pkg-config --cflags eigen3), and
# CMake's find_package(Eigen3 3.4 REQUIRED NO_MODULE) with target
# Eigen3::Eigen. Its CMake setup wants a C++ compiler even though nothing
# is compiled. Bump EIGEN_VERSION/EIGEN_SHA256 together.
# ---------------------------------------------------------------------------
ARG EIGEN_VERSION=3.4.0
ARG EIGEN_SHA256=8586084f71f9bde545ee7fa6d00288b264a2b7ac3607b974e54d13e7162c1c72

RUN set -eux; \
    curl -fsSL -o /tmp/eigen.tar.gz \
        "https://gitlab.com/libeigen/eigen/-/archive/${EIGEN_VERSION}/eigen-${EIGEN_VERSION}.tar.gz"; \
    echo "${EIGEN_SHA256}  /tmp/eigen.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/eigen.tar.gz -C /tmp --no-same-owner; \
    rm /tmp/eigen.tar.gz; \
    set +u; source /opt/rh/gcc-toolset-12/enable; set -u; \
    cmake -S "/tmp/eigen-${EIGEN_VERSION}" -B /tmp/eigen-build \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DPKGCONFIG_INSTALL_DIR=/usr/local/lib64/pkgconfig \
        -DBUILD_TESTING=OFF; \
    cmake --install /tmp/eigen-build; \
    rm -rf "/tmp/eigen-${EIGEN_VERSION}" /tmp/eigen-build; \
    PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig pkg-config --modversion eigen3 | grep -qx "${EIGEN_VERSION}"

# ---------------------------------------------------------------------------
# CUDA toolkit 12.2.1 (nvcc V12.2.128), from NVIDIA's RHEL 9 repo, every
# package pinned to the version that release shipped (the repo's
# meta-packages only ask for "at least", so they'd drift to later updates).
# Matches the hosts' CUDA (dipper: 12.2, V12.2.128); run.sh can use a newer
# toolkit from the host instead (RHEL9DEV_CUDA=host, see run.sh).
#
# The common set: nvcc and friends, cuda-gdb, the runtime, Thrust/CUB
# (cccl), the driver API stub (libcuda.so, to link against; the real one
# comes with the host's driver), NVRTC, NVTX, the profiler API, and cuBLAS,
# cuFFT, cuRAND, cuSOLVER and cuSPARSE (+ nvJitLink, which they need). Not
# NPP, nvJPEG, cuFile, OpenCL or the Nsight tools: add them below (versions
# from `dnf repoquery --requires cuda-libraries-devel-12-2-12.2.1`).
#
# The libraries' static archives (~2 GB, cuBLASLt alone 0.7 GB) are deleted;
# projects link the shared ones. libcudart_static.a (nvcc's default runtime)
# and libcudadevrt.a (separate compilation) stay.
#
# Installs to /usr/local/cuda-12.2, with /usr/local/cuda pointing at it and
# its lib directory in /etc/ld.so.conf.d, so binaries find the libraries
# without LD_LIBRARY_PATH; /etc/profile.d/20-cuda.sh puts nvcc on PATH. CUDA
# 12.2 supports gcc up to 12, i.e. the default gcc-toolset-12 (and RHEL's
# gcc 11), not gcc-toolset-14/15. Running kernels needs the GPU and the
# host's driver (R525 or newer for CUDA 12) in the container; compiling
# doesn't. NVIDIA's repo stays configured but disabled. Bump the versions
# together, from that repoquery.
# ---------------------------------------------------------------------------
ARG CUDA_VERSION=12.2.1
ARG CUDA_NVCC_VERSION=12.2.128
LABEL rhel9-dev.cuda.version="${CUDA_VERSION}" \
      rhel9-dev.cuda.nvcc="${CUDA_NVCC_VERSION}"

RUN set -eux; \
    curl -fsSL -o /etc/yum.repos.d/cuda-rhel9.repo \
        https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo; \
    C="${CUDA_NVCC_VERSION}"; \
    dnf install -y --setopt=install_weak_deps=0 \
        cuda-nvcc-12-2-$C cuda-cuobjdump-12-2-$C cuda-cuxxfilt-12-2-$C \
        cuda-nvprune-12-2-$C cuda-gdb-12-2-$C \
        cuda-cudart-12-2-$C cuda-cudart-devel-12-2-$C cuda-cccl-12-2-$C \
        cuda-driver-devel-12-2-$C \
        cuda-nvrtc-12-2-$C cuda-nvrtc-devel-12-2-$C \
        cuda-nvtx-12-2-$C cuda-profiler-api-12-2-$C \
        libnvjitlink-12-2-$C libnvjitlink-devel-12-2-$C \
        libcublas-12-2-12.2.4.5 libcublas-devel-12-2-12.2.4.5 \
        libcufft-12-2-11.0.8.91 libcufft-devel-12-2-11.0.8.91 \
        libcurand-12-2-10.3.3.129 libcurand-devel-12-2-10.3.3.129 \
        libcusolver-12-2-11.5.1.129 libcusolver-devel-12-2-11.5.1.129 \
        libcusparse-12-2-12.1.2.129 libcusparse-devel-12-2-12.1.2.129; \
    find /usr/local/cuda-12.2/targets/x86_64-linux/lib -name '*_static*.a' \
        ! -name libcudart_static.a -delete; \
    sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/cuda-rhel9.repo; \
    dnf clean all; \
    ldconfig; \
    /usr/local/cuda/bin/nvcc --version | grep -q ", V${CUDA_NVCC_VERSION}\$"

# ---------------------------------------------------------------------------
# Go — official upstream tarball into /usr/local/go, checksum pinned.
#
# omp_distro's build.sh compiles github-mcp-server from patched source, whose
# go.mod declares `go 1.25.12` (mcdonoe/omp_distro#2). RHEL's go-toolset can
# trail that floor, and it's a Red Hat-patched (FIPS/OpenSSL) build; upstream
# keeps CGO_ENABLED=0 static builds identical to what upstream CI produces.
# Any Go >= the go.mod floor works; bump GO_VERSION/GO_SHA256 together from
# https://go.dev/dl/?mode=json.
#
# gopls and delve go into /usr/local/bin (not a per-user GOPATH) so root and
# every user get them. Their module caches are thrown away afterwards so
# the layer carries binaries only; root-owned caches under /root would also
# have nothing to do with the build user's own GOPATH/GOCACHE.
# ---------------------------------------------------------------------------
ARG GO_VERSION=1.27.1
ARG GO_SHA256=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445
ARG GOPLS_VERSION=v0.23.0
ARG DELVE_VERSION=v1.27.2

RUN set -eux; \
    curl -fsSL -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"; \
    echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/go.tar.gz -C /usr/local; \
    rm /tmp/go.tar.gz; \
    export GOTOOLCHAIN=local GOPATH=/tmp/gopath GOCACHE=/tmp/gocache GOBIN=/usr/local/bin; \
    /usr/local/go/bin/go install "golang.org/x/tools/gopls@${GOPLS_VERSION}"; \
    /usr/local/go/bin/go install "github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION}"; \
    rm -rf /tmp/gopath /tmp/gocache

# GOTOOLCHAIN=local: never let `go` silently download a different toolchain
# because a go.mod asks for one; a too-old Go must fail loudly instead.
# GOPROXY/GOSUMDB stay at upstream's defaults (proxy.golang.org,
# sum.golang.org); override with -e GOPROXY=... for an internal proxy.
# GOPATH/GOCACHE default to ~/go and ~/.cache/go-build, writable by whichever
# user runs the build; mount a volume there to keep module downloads warm.
# Keep in sync with /etc/profile.d/10-dev-env.sh below (login shells).
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
    ANT_HOME=/opt/ant \
    GOTOOLCHAIN=local \
    PATH="/usr/local/go/bin:/opt/ant/bin:${PATH}" \
    PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# gcc-toolset-12 active by default in every interactive shell (RHEL's
# /etc/bashrc sources /etc/profile.d/*.sh even for non-login shells, which
# covers `docker run -it ... bash`). Switch per-session to 14 or 15 with:
#   source /opt/rh/gcc-toolset-14/enable   (or gcc-toolset-15)
RUN echo 'source /opt/rh/gcc-toolset-12/enable' > /etc/profile.d/00-gcc-toolset.sh && \
    chmod +x /etc/profile.d/00-gcc-toolset.sh

# Mirror the ENV block above for login shells. `su - <user>`, `bash -l` and
# ssh start from a clean environment and rebuild PATH from login.defs, which
# drops everything ENV set: no `go` on PATH, no GOTOOLCHAIN or JAVA_HOME.
# Plain `docker run`/`docker exec` keep ENV and are unaffected; the PATH
# guards keep this idempotent there. Also adds ~/go/bin, where `go install`
# puts each user's own tools.
RUN cat > /etc/profile.d/10-dev-env.sh <<'EOF_PROFILE'
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
export ANT_HOME=/opt/ant
export GOTOOLCHAIN=local
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
for d in /opt/ant/bin /usr/local/go/bin; do
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
case ":$PATH:" in *":$HOME/go/bin:"*) ;; *) PATH="$PATH:$HOME/go/bin" ;; esac
# pkg-config files for what's built into /usr/local (protobuf)
case ":${PKG_CONFIG_PATH:-}:" in *":/usr/local/lib64/pkgconfig:"*) ;;
    *) export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;; esac
unset d
export PATH
EOF_PROFILE

# CUDA for login shells: the image's toolkit (/usr/local/cuda), or the
# host's newer one, which run.sh mounts at /opt/host-cuda and names in
# RHEL9DEV_CUDA_HOME when asked to (RHEL9DEV_CUDA=host). The image's
# libraries are in the loader cache; a host toolkit's go first on
# LD_LIBRARY_PATH so they win.
# Also the host's GPU driver libraries, which run.sh mounts under
# /opt/host-nvidia (RHEL9DEV_NVIDIA) on a host with NVIDIA GPUs.
RUN cat > /etc/profile.d/20-cuda.sh <<'EOF_PROFILE'
CUDA_HOME="${RHEL9DEV_CUDA_HOME:-/usr/local/cuda}"
if [ -x "$CUDA_HOME/bin/nvcc" ]; then
    CUDA_PATH="$CUDA_HOME"
    export CUDA_HOME CUDA_PATH
    case ":$PATH:" in *":$CUDA_HOME/bin:"*) ;; *) PATH="$CUDA_HOME/bin:$PATH" ;; esac
    export PATH
    if [ -n "${RHEL9DEV_CUDA_HOME:-}" ]; then
        case ":${LD_LIBRARY_PATH:-}:" in *":$CUDA_HOME/lib64:"*) ;;
            *) export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;; esac
    fi
else
    unset CUDA_HOME
fi
# The host's NVIDIA driver libraries and nvidia-smi, when run.sh mounts them.
if [ -n "${RHEL9DEV_NVIDIA:-}" ]; then
    case ":${LD_LIBRARY_PATH:-}:" in *":$RHEL9DEV_NVIDIA/lib:"*) ;;
        *) export LD_LIBRARY_PATH="$RHEL9DEV_NVIDIA/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;; esac
    case ":$PATH:" in *":$RHEL9DEV_NVIDIA/bin:"*) ;; *) PATH="$PATH:$RHEL9DEV_NVIDIA/bin" ;; esac
    export PATH
fi
EOF_PROFILE

# Bind-mounting host repos (e.g. -v ~/GIT_REPOS:/workspace) trips git's
# dubious-ownership check when the container UID differs from the host
# owner; every repo under /workspace belongs to the user running it, so trust
# them all.
RUN git config --system --add safe.directory '*'

# ---------------------------------------------------------------------------
# OMP coding agent, from an omp_distro bundle (optional).
#
# build.sh stages the newest ~/GIT_REPOS/omp_distro/dist/omp-portable-*.tar.gz
# into omp-bundle/, and this step runs the bundle's own install.sh against it:
# /opt/omp, /etc/profile.d/omp.sh, and the RouteLM URL stamped into the
# models.yml template. With nothing staged the step is a no-op, so the image
# still builds without omp_distro. The bundle is bind-mounted rather than
# COPYed so the tarball never lands in a layer.
#
# The bundle was made for airgapped hosts, but nothing in it stops it reaching
# the router over the container's normal network.
# ---------------------------------------------------------------------------
ARG ROUTELM_URL=http://192.168.1.151:11400/v1

RUN --mount=type=bind,source=omp-bundle,target=/mnt/omp-bundle \
    set -eux; \
    ls /mnt/omp-bundle >/dev/null || { echo "error: can't read omp-bundle/ (SELinux? build with ./build.sh)" >&2; exit 1; }; \
    set -- /mnt/omp-bundle/omp-portable-*.tar.gz; \
    if [ ! -e "$1" ]; then echo "No OMP bundle staged; skipping OMP."; exit 0; fi; \
    [ $# -eq 1 ] || { echo "error: more than one OMP bundle staged" >&2; exit 1; }; \
    mkdir /tmp/omp; \
    tar -xzf "$1" -C /tmp/omp; \
    /tmp/omp/*/install.sh --routelm-url "$ROUTELM_URL"; \
    rm -rf /tmp/omp; \
    chown -R root:root /opt/omp

# run.sh bind-mounts the host's ~/.omp. Users set it up on the host
# (omp-user-setup, omp-mcp-setup) against the same bundle version as this
# image, at the same /opt/omp paths, so it works here as is; re-running setup
# would only re-apply bundle settings over their changes. Only for someone
# who has never set up OMP anywhere, seed ~/.omp on login. Setup only warns
# if the router is unreachable; fix it later with omp-refresh-models. Named
# zz- so it runs after omp.sh puts omp on PATH.
RUN cat > /etc/profile.d/zz-omp-user-setup.sh <<'EOF_PROFILE'
if [ -x /opt/omp/bin/omp-user-setup ] && [ "$(id -u)" -ne 0 ] && [ -w "$HOME" ] \
        && [ ! -e "$HOME/.omp/agent/models.yml" ]; then
    echo "==> No OMP setup in ~/.omp yet; running omp-user-setup"
    /opt/omp/bin/omp-user-setup
fi
EOF_PROFILE

# ---------------------------------------------------------------------------
# Vendored npm packages, for development with no npm registry (air-gapped).
#
# npm-vendor/package.json lists the packages the console UI's design
# proposal calls for, at exact versions, and npm-vendor/pnpm-lock.yaml pins
# their whole dependency tree. build-registry.mjs turns that into a small
# read-only registry in /opt/npm-registry holding only those versions, and
# the entrypoint serves it on 127.0.0.1 and points npm and pnpm at it. So
# `pnpm install` and `pnpm add <vendored package>` work as usual, offline,
# and anything not vendored fails at once with a clear message instead of a
# network timeout. See npm-vendor/README.md for adding packages.
#
# The last step installs the whole vendored set into a fresh project through
# the registry alone, so a build that succeeds is known to serve everything.
# ---------------------------------------------------------------------------
COPY npm-vendor/ /opt/npm-vendor/
RUN set -eux; \
    node /opt/npm-vendor/build-registry.mjs /opt/npm-vendor/pnpm-lock.yaml /opt/npm-registry; \
    cp /opt/npm-vendor/serve.mjs /opt/npm-registry/; \
    chmod -R a+rX /opt/npm-vendor /opt/npm-registry; \
    node /opt/npm-registry/serve.mjs /tmp/registry-port & REGISTRY_PID=$!; \
    for _ in $(seq 50); do [ -s /tmp/registry-port ] && break; sleep 0.1; done; \
    export pnpm_config_registry="http://127.0.0.1:$(cat /tmp/registry-port)/" \
           pnpm_config_store_dir=/tmp/selftest-store pnpm_config_cache_dir=/tmp/selftest-cache; \
    mkdir /tmp/selftest; cd /tmp/selftest; \
    echo '{"name":"selftest","private":true}' > package.json; \
    pnpm add --ignore-scripts $(node -e ' \
        const p = require("/opt/npm-vendor/package.json"); \
        for (const [n, v] of Object.entries(p.dependencies)) process.stdout.write(`${n}@${v} `);'); \
    pnpm add -D --ignore-scripts $(node -e ' \
        const p = require("/opt/npm-vendor/package.json"); \
        for (const [n, v] of Object.entries(p.devDependencies)) process.stdout.write(`${n}@${v} `);'); \
    kill "$REGISTRY_PID"; \
    cd /; rm -rf /tmp/selftest /tmp/selftest-store /tmp/selftest-cache /tmp/registry-port

# ---------------------------------------------------------------------------
# Vendored Maven artifacts, for development with no Maven repository
# (air-gapped): protobuf-java 4.36 and protoc 4.36 (linux-x86_64 exe), the
# xolstice protobuf-maven-plugin with os-maven-plugin, maven-antrun-plugin
# 3.1.0 with its Ant libraries, Maven's default jar-lifecycle plugins, and
# everything they need.
#
# maven-vendor/pom.xml is a project that uses all of them. build-repo.sh
# builds it online, keeps what Maven downloaded as a plain read-only Maven
# repository in /opt/maven-repo, checks every file against the SHA-256s
# pinned in maven-vendor/checksums.sha256, and builds the project again
# from /opt/maven-repo alone, so a build that succeeds is known to resolve
# everything offline. The image's global settings.xml puts /opt/maven-repo
# ahead of Maven Central for every project. See maven-vendor/README.md.
# ---------------------------------------------------------------------------
COPY maven-vendor/ /opt/maven-vendor/
RUN set -eux; \
    /opt/maven-vendor/build-repo.sh /opt/maven-vendor /opt/maven-repo; \
    install -m 644 /opt/maven-vendor/settings.xml /etc/maven/settings.xml; \
    chmod -R a+rX /opt/maven-vendor; \
    rm -rf /root/.m2

# ---------------------------------------------------------------------------
# buf — the Protobuf CLI (lint, breaking-change checks, generate), the
# official standalone binary, checksum pinned (sha256.txt in each GitHub
# release). Same version as the vendored @bufbuild/buf npm package, so
# `buf` and `pnpm exec buf` agree. Bump BUF_VERSION/BUF_SHA256 together.
# ---------------------------------------------------------------------------
ARG BUF_VERSION=1.75.0
ARG BUF_SHA256=fad1e38d6909bbb583a4da81d8c02a01046e2cd663bde7e337dd24277393764b

RUN set -eux; \
    curl -fsSL -o /tmp/buf \
        "https://github.com/bufbuild/buf/releases/download/v${BUF_VERSION}/buf-Linux-x86_64"; \
    echo "${BUF_SHA256}  /tmp/buf" | sha256sum -c -; \
    install -m 755 /tmp/buf /usr/local/bin/buf; \
    rm /tmp/buf; \
    [ "$(buf --version)" = "${BUF_VERSION}" ]

# ---------------------------------------------------------------------------
# Maps: the offline map data from the maps stage, in /opt/maps, plus
# pmtiles, Protomaps' CLI (inspect, serve or cut .pmtiles archives), built
# from pinned source with the image's Go.
# ---------------------------------------------------------------------------
ARG PMTILES_VERSION=v1.31.2

RUN set -eux; \
    GOPATH=/tmp/gopath GOCACHE=/tmp/gocache GOBIN=/usr/local/bin \
        go install "github.com/protomaps/go-pmtiles@${PMTILES_VERSION}"; \
    mv /usr/local/bin/go-pmtiles /usr/local/bin/pmtiles; \
    rm -rf /tmp/gopath /tmp/gocache

COPY --from=maps /opt/maps /opt/maps
RUN if [ -f /opt/maps/eastern-seaboard.pmtiles ]; then \
        pmtiles show /opt/maps/eastern-seaboard.pmtiles | head -20; \
    fi

# Nothing in the image may be owned by an ordinary user's UID/GID (such as
# the build user's, carried in by a tarball). In a shared image store those
# IDs are real host IDs that rootless podman can't map, and container
# creation fails with "storage-chown-by-maps: lchown ...: operation not
# permitted". Only system accounts (below 1000) and nobody (65534) are OK.
RUN bad="$(find / -xdev \( -uid +999 -o -gid +999 \) ! -uid 65534 ! -gid 65534 \
              -printf '%U:%G %p\n' 2>/dev/null | head -20)"; \
    if [ -n "$bad" ]; then \
        echo "error: files owned by a non-system UID/GID (chown them to root):" >&2; \
        echo "$bad" >&2; exit 1; \
    fi

# No user is baked in. entrypoint.sh creates one at startup with the UID/GID
# of whoever ran run.sh, so bind-mounted files keep their host ownership for
# every user, not just one. The image's USER stays root: without run.sh's
# HOST_* variables, `docker run -it rhel9-dev bash` is root, as in redhat/ubi9.
COPY --chmod=755 entrypoint.sh /usr/local/sbin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
CMD ["/bin/bash"]
