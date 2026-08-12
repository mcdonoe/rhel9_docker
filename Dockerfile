# syntax=docker/dockerfile:1.7
#
# RHEL9 (UBI9) general-purpose development environment.
# Build:  ./build.sh                     (free repos only)
#         ./build.sh --subscription      (also registers with Red Hat during
#                                          the build, using BuildKit secrets)
# Run:    docker run -it --rm -v "$HOME/GIT_REPOS:/workspace" rhel9-dev bash

FROM redhat/ubi9

LABEL description="RHEL9 UBI dev environment: gcc-toolset 12/14, Python 3.11/3.12, OpenJDK 21 + Ant, cmake/make, btop, vim"

# ---------------------------------------------------------------------------
# Package installs.
#
# Everything below resolves from the free UBI AppStream/BaseOS/CodeReady
# Builder repos (already enabled in this base image) plus EPEL, with two
# exceptions: Apache Ant and the uv Python installer aren't packaged for
# RHEL9 at all, so those are installed by hand further down.
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
        # --- C/C++ toolchains: gcc 12 and 14 side by side, 12 active by default ---
        gcc-toolset-12 gcc-toolset-12-gdb \
        gcc-toolset-14 \
        gdb \
        # --- autotools, commonly paired with cmake/make C/C++ projects ---
        autoconf automake libtool pkgconf-pkg-config \
        # --- Python ---
        python3.11 python3.11-devel python3.11-pip \
        python3.12 python3.12-devel python3.12-pip \
        # --- Java, for Ant (installed by hand below) ---
        java-21-openjdk-devel \
        # --- native libs needed by common Python packages (e.g. WeasyPrint) ---
        cairo pango gdk-pixbuf2 libffi-devel \
        # --- editor / terminal tooling ---
        vim-enhanced btop ripgrep fd-find jq \
        # --- general shell/dev utilities ---
        sudo which findutils procps-ng tar gzip unzip xz wget openssh-clients \
        glibc-langpack-en \
    && dnf clean all; \
    if [ "$REGISTERED" = "1" ]; then \
        subscription-manager unregister; \
        subscription-manager clean; \
    fi

# ---------------------------------------------------------------------------
# Apache Ant — dropped from RHEL9/EPEL9 packaging, install the official
# binary release by hand. Checksum pinned against a version bump by accident.
# ---------------------------------------------------------------------------
ARG ANT_VERSION=1.10.17
ARG ANT_SHA512=a96ca6455ec9af5e702df7d1ed5a2ec1cfb381eac3e9a767ecb6be1706e826941045e8fd7ca663ba101bc47bfa18351f540dd27e9e7af57908ac78e65268eee7

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

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
    ANT_HOME=/opt/ant \
    PATH="/opt/ant/bin:${PATH}" \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# gcc-toolset-12 active by default in every interactive shell (RHEL's
# /etc/bashrc sources /etc/profile.d/*.sh even for non-login shells, which
# covers `docker run -it ... bash`). Switch per-session to 14 with:
#   source /opt/rh/gcc-toolset-14/enable
RUN echo 'source /opt/rh/gcc-toolset-12/enable' > /etc/profile.d/00-gcc-toolset.sh && \
    chmod +x /etc/profile.d/00-gcc-toolset.sh

# Bind-mounting host repos (e.g. -v ~/GIT_REPOS:/workspace) trips git's
# dubious-ownership check when the container UID differs from the host
# owner; this container is for personal single-user use, so trust it broadly.
RUN git config --system --add safe.directory '*'

# Non-root user for anyone attaching via VS Code's Dev Containers extension
# (docker exec / attach as this user) or interactive use with `--user mcdonoe`.
# UID/GID 1000 matches the host mcdonoe user, so files touched through a
# bind mount (e.g. -v ~/GIT_REPOS:/workspace) keep sane host-side ownership.
# Default container USER stays root so `docker run -it rhel9-dev bash` keeps
# ad-hoc `dnf install` working the same way redhat/ubi9 does out of the box.
RUN groupadd -g 1000 mcdonoe && \
    useradd -m -u 1000 -g 1000 -G wheel -s /bin/bash mcdonoe && \
    echo 'mcdonoe ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/mcdonoe

WORKDIR /workspace
CMD ["/bin/bash"]
