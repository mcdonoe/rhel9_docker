# syntax=docker/dockerfile:1.7
#
# RHEL9 (UBI9) general-purpose development environment.
# Builds under docker or podman; see build.sh.
# Build:  ./build.sh                     (free repos only)
#         ./build.sh --subscription      (also registers with Red Hat during
#                                          the build, using build secrets)
# Run:    docker run -it --rm -v "$HOME/GIT_REPOS:/workspace" rhel9-dev bash

FROM redhat/ubi9

LABEL description="RHEL9 UBI dev environment: gcc-toolset 12/14/15, Python 3.11/3.12/3.14, Go + gopls/delve, OpenJDK 21 + Ant, cmake/make, btop, vim, opt-in dnsmasq DHCP server, optional OMP coding agent"

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
        # --- Python ---
        python3.11 python3.11-devel python3.11-pip \
        python3.12 python3.12-devel python3.12-pip \
        python3.14 python3.14-devel python3.14-pip \
        # --- Java, for Ant (installed by hand below) ---
        java-21-openjdk-devel \
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
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
for d in /opt/ant/bin /usr/local/go/bin; do
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
case ":$PATH:" in *":$HOME/go/bin:"*) ;; *) PATH="$PATH:$HOME/go/bin" ;; esac
unset d
export PATH
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
    set -- /mnt/omp-bundle/omp-portable-*.tar.gz; \
    if [ ! -e "$1" ]; then echo "No OMP bundle staged; skipping OMP."; exit 0; fi; \
    [ $# -eq 1 ] || { echo "error: more than one OMP bundle staged" >&2; exit 1; }; \
    mkdir /tmp/omp; \
    tar -xzf "$1" -C /tmp/omp; \
    /tmp/omp/*/install.sh --routelm-url "$ROUTELM_URL"; \
    rm -rf /tmp/omp

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

# No user is baked in. entrypoint.sh creates one at startup with the UID/GID
# of whoever ran run.sh, so bind-mounted files keep their host ownership for
# every user, not just one. The image's USER stays root: without run.sh's
# HOST_* variables, `docker run -it rhel9-dev bash` is root, as in redhat/ubi9.
COPY --chmod=755 entrypoint.sh /usr/local/sbin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
CMD ["/bin/bash"]
