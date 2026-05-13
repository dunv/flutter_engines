# syntax=docker/dockerfile:1.6
#
# Build environment for the Flutter engine (libflutter_engine.so /
# gen_snapshot) at the SHA pinned in //flutter:engine.version.
#
# Pragmatic, not hermetic: engine upstream drives its build with
# depot_tools + gclient + gn + ninja, none of which fit Bazel. This
# image isolates the host from depot_tools/gclient state and gives us
# a reproducible set of OS-level deps. The engine checkout itself
# (Dart SDK, Skia, Buildtools, libc++, etc.) is pulled via gclient at
# image-run time and pinned by the engine SHA's DEPS file.
#
# The container expects a bind-mounted scratch dir at /work
# (~30-40GB after a full sync + builds). See build.sh for the inside-
# container driver and bin/build_flutter_engine.sh for the host wrapper.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Minimal OS-level deps. Engine ships its own clang + libc++ via
# buildtools/, but we still need a host toolchain for depot_tools'
# bootstrap steps, plus python/git/curl/etc.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        lsb-release \
        sudo \
        python3 \
        python3-pip \
        python3-setuptools \
        python3-distutils \
        pkg-config \
        build-essential \
        ninja-build \
        unzip \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

# depot_tools. Floating tip is fine for engine builds — the engine
# DEPS file pins everything that matters. To pin depot_tools too, set
# DEPOT_TOOLS_REF at build time.
#
# Note: depot_tools writes back into its own install dir (cipd cache,
# .cipd_bin/, .cipd_client, gclient_*.pyc, etc.) during gclient sync,
# so the build user needs write access. We chown after the chown-aware
# user is created further down.
ARG DEPOT_TOOLS_REF=main
RUN git clone --depth 1 --branch "${DEPOT_TOOLS_REF}" \
        https://chromium.googlesource.com/chromium/tools/depot_tools.git \
        /opt/depot_tools

ENV PATH="/opt/depot_tools:${PATH}" \
    DEPOT_TOOLS_UPDATE=0

# Non-root build user. gclient/gn refuse to run as root in some code
# paths and it also keeps the bind-mounted scratch dir owned by the
# host user. UID/GID are overridable at image build time so the host
# wrapper can match the invoking user.
ARG BUILDER_UID=1000
ARG BUILDER_GID=1000
# If a group with the requested GID already exists (e.g. GID 100 is
# Ubuntu's `users` group — common when host UID/GID is 1000/100),
# reuse it instead of failing. useradd --gid accepts a numeric ID
# whether the group is freshly created or pre-existing.
RUN if ! getent group "${BUILDER_GID}" >/dev/null; then \
        groupadd --gid "${BUILDER_GID}" builder; \
    fi \
    && useradd --uid "${BUILDER_UID}" --gid "${BUILDER_GID}" --create-home --shell /bin/bash builder \
    && echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && chown -R "${BUILDER_UID}:${BUILDER_GID}" /opt/depot_tools

USER builder
WORKDIR /work

# The in-container driver. Lives at /usr/local/bin in the image so the
# host wrapper can invoke it without worrying about the bind-mount
# path.
COPY --chown=builder:builder build.sh /usr/local/bin/build_flutter_engine
RUN sudo chmod +x /usr/local/bin/build_flutter_engine

ENTRYPOINT ["/usr/local/bin/build_flutter_engine"]
