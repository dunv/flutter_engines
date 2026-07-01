#!/usr/bin/env bash
#
# In-container driver for the Flutter engine build. See ../README.md
# for the host-side wrapper.
#
# Layout note: the engine source repo was merged into flutter/flutter
# in late 2024. At engine SHAs after that merge, the canonical setup
# is:
#   <root>/                      flutter/flutter clone (HEAD = ENGINE_SHA)
#   <root>/.gclient              copied from engine/scripts/standard.gclient
#   <root>/engine/src/flutter/   engine source (was flutter/engine in old layout)
#   <root>/engine/src/out/<v>/   ninja build outputs
# gclient manages everything *under* <root>/ via the top-level DEPS,
# but does NOT touch flutter/flutter itself (managed=False, name=".").
#
# Expects:
#   /work                 bind-mounted scratch dir on the host (~40GB)
#   ENGINE_SHA            engine commit to check out (required)
#   VARIANTS              space-separated list, default = all three
#                         supported: x64_release x64_debug arm64_release
#   JOBS                  ninja -j; default = nproc
#
# Layout under /work after a full run:
#   /work/engine/                       gclient root (= flutter/flutter checkout)
#   /work/engine/engine/src/            gn/ninja working dir
#   /work/engine/engine/src/out/<v>/    per-variant outputs
#   /work/artifacts/                    packaged .tar.gz tarballs + SHA256SUMS

set -euo pipefail

: "${ENGINE_SHA:?ENGINE_SHA is required}"

VARIANTS="${VARIANTS:-x64_release x64_debug arm64_release}"
JOBS="${JOBS:-$(nproc)}"
WORK_DIR=/work
ENGINE_DIR="${WORK_DIR}/engine"           # gclient root + flutter/flutter checkout
SRC_DIR="${ENGINE_DIR}/engine/src"        # gn/ninja work directory
FLUTTER_DIR="${SRC_DIR}/flutter"          # engine source (./tools/gn lives here)
ARTIFACTS_DIR="${WORK_DIR}/artifacts"

log()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

mkdir -p "${ENGINE_DIR}" "${ARTIFACTS_DIR}"

# ----------------------------------------------------------------------
# Bootstrap flutter/flutter checkout at ENGINE_SHA
# ----------------------------------------------------------------------
#
# With managed=False, gclient doesn't fetch the top-level repo — we
# have to put it there ourselves. Subsequent runs short-circuit if the
# checkout is already at the requested SHA.
log "Bootstrapping flutter/flutter at ${ENGINE_SHA}"
cd "${ENGINE_DIR}"

if [[ ! -d .git ]]; then
    git init -q .
    git remote add origin https://github.com/flutter/flutter.git
fi

CURRENT_SHA="$(git rev-parse --verify --quiet HEAD || true)"
if [[ "${CURRENT_SHA}" != "${ENGINE_SHA}" ]]; then
    # Single-commit fetch keeps the clone tiny (~1GB vs ~10GB for full history).
    git fetch --depth=1 origin "${ENGINE_SHA}"
    git -c advice.detachedHead=false checkout --force "${ENGINE_SHA}"
fi

[[ -f engine/scripts/standard.gclient ]] \
    || fail "engine/scripts/standard.gclient not in repo at this SHA (pre-monorepo SHA?)"

cp engine/scripts/standard.gclient .gclient

# ----------------------------------------------------------------------
# gclient sync — pulls Dart SDK, Skia, buildtools/clang, libc++, sysroots
# ----------------------------------------------------------------------
log "gclient sync (engine SHA ${ENGINE_SHA})"
gclient sync --no-history -D

[[ -x "${FLUTTER_DIR}/tools/gn" ]] \
    || fail "expected ${FLUTTER_DIR}/tools/gn after gclient sync"

# ----------------------------------------------------------------------
# Build variants
# ----------------------------------------------------------------------

run_gn() {
    local out_subdir="$1"; shift
    log "gn gen for ${out_subdir}"
    (
        cd "${SRC_DIR}"
        ./flutter/tools/gn "$@"
    )
    [[ -d "${SRC_DIR}/out/${out_subdir}" ]] \
        || fail "expected out/${out_subdir} after gn (output dir name may differ in this engine SHA)"
}

run_ninja() {
    local out_subdir="$1"; shift
    # Explicit targets are required. Running ninja with no target on a
    # cross-arch build (e.g. linux_release_arm64) only builds the host
    # helper subset (flutter_tester etc.) — the target-arch
    # libflutter_engine.so isn't part of the default. We pass exactly
    # the targets we ship.
    log "ninja -j${JOBS} -C out/${out_subdir} $*"
    (
        cd "${SRC_DIR}"
        ninja -j"${JOBS}" -C "out/${out_subdir}" "$@"
    )
}

# Skip a variant if its tarball is already on disk. The build
# infrastructure is idempotent (gclient sync no-ops, ninja is
# incremental) but a successful arm64 follow-up shouldn't rebuild a
# perfectly good x64 tarball from a previous run.
already_built() {
    local tarball="$1"
    if [[ -f "${ARTIFACTS_DIR}/${tarball}" ]]; then
        log "Skipping ${tarball} (already in artifacts/, delete to force rebuild)"
        return 0
    fi
    return 1
}

# Per-variant packaging. Tarballs are flat (no top-level dir) so a
# Bazel http_archive can apply a build_file without strip_prefix.
#
# Each tarball ships the upstream Flutter engine LICENSE alongside the
# binaries so downstream consumers get the upstream notice they need to
# redistribute. The source is engine/src/flutter/LICENSE in the gclient
# checkout (BSD-3-Clause). This file is also what Flutter's own CDN
# embedder zips include.
package() {
    local tarball="$1"; shift
    local src_root="$1"; shift
    log "Packaging ${tarball}"
    cp "${FLUTTER_DIR}/LICENSE" "${src_root}/LICENSE"
    tar -C "${src_root}" -czf "${ARTIFACTS_DIR}/${tarball}" LICENSE "$@"
}

# --no-enable-unittests: gn evaluates the shell_unittests target lazily
# at `if (enable_unittests)` (//flutter/shell/common/BUILD.gn:200).
# That target deps on //flutter/third_party/angle:libEGL_static, which
# requires a `wayland_dir` variable that isn't set in our config and
# crashes gn at gen time. We don't ship unit tests in the embedder
# tarball anyway, so disabling them sidesteps the whole subtree.
COMMON_GN_FLAGS=(--no-enable-unittests)

# Ninja target reference:
#   flutter/shell/platform/embedder:flutter_engine
#     Group target; depends on the shared_library flutter_engine_library
#     which produces libflutter_engine.so + copies flutter_embedder.h into
#     root_out_dir. Confirmed against shell/platform/embedder/BUILD.gn:447
#     and :560 in flutter/flutter at engine SHA 425cfb54...
#   gen_snapshot   (file target)
#     Produced by //third_party/dart/runtime/bin:gen_snapshot. When
#     target_arch == host_arch (x64 release here), lands at root_out_dir.
#     When cross-compiling (arm64 release), the host-x64 binary lands at
#     clang_x64/gen_snapshot in the same out tree, which is what we need
#     for AOT compilation of arm64 Flutter bundles on x64 build hosts.

build_x64_release() {
    local tarball="flutter_engine_linux_x64_release-${ENGINE_SHA}.tar.gz"
    already_built "${tarball}" && return 0
    run_gn linux_release_x64 \
        "${COMMON_GN_FLAGS[@]}" --runtime-mode=release --linux --linux-cpu=x64
    run_ninja linux_release_x64 \
        flutter/shell/platform/embedder:flutter_engine \
        gen_snapshot
    package "${tarball}" \
            "${SRC_DIR}/out/linux_release_x64" \
            libflutter_engine.so flutter_embedder.h gen_snapshot icudtl.dat
}

build_x64_debug() {
    local tarball="flutter_engine_linux_x64_debug-${ENGINE_SHA}.tar.gz"
    already_built "${tarball}" && return 0
    run_gn linux_debug_x64 \
        "${COMMON_GN_FLAGS[@]}" --runtime-mode=debug --linux --linux-cpu=x64
    run_ninja linux_debug_x64 \
        flutter/shell/platform/embedder:flutter_engine
    package "${tarball}" \
            "${SRC_DIR}/out/linux_debug_x64" \
            libflutter_engine.so flutter_embedder.h
}

# Cross-build from x64 host to arm64 target. Engine's gclient checkout
# ships its own sysroot at buildtools/sysroot/, so no host packages are
# needed. The host-x64 gen_snapshot for arm64 AOT lands in clang_x64/.
#
# --embedder-for-target is critical for cross builds. Without it, the
# group target //flutter/shell/platform/embedder:flutter_engine is empty
# on the target toolchain (see BUILD.gn:560-573: `build_embedder_api =
# current_toolchain == host_toolchain || embedder_for_target`). With
# host_toolchain = clang_x64 and current = clang_arm64, the embedder
# library isn't pulled in unless we opt into target embedder builds.
build_arm64_release() {
    local tarball="flutter_engine_linux_arm64_release-${ENGINE_SHA}.tar.gz"
    already_built "${tarball}" && return 0
    run_gn linux_release_arm64 \
        "${COMMON_GN_FLAGS[@]}" --runtime-mode=release --linux --linux-cpu=arm64 \
        --embedder-for-target
    # Explicit targets: the embedder library (arm64 .so) plus the
    # host-toolchain (clang_x64) gen_snapshot binary, which is what
    # actually does cross-AOT for arm64 carts.
    run_ninja linux_release_arm64 \
        flutter/shell/platform/embedder:flutter_engine \
        clang_x64/gen_snapshot

    # Flatten clang_x64/gen_snapshot to a top-level entry so the tarball
    # mirrors the x64 release shape (and ardera's per-arch layout).
    local stage
    stage="$(mktemp -d)"
    cp "${SRC_DIR}/out/linux_release_arm64/libflutter_engine.so" "${stage}/"
    cp "${SRC_DIR}/out/linux_release_arm64/flutter_embedder.h"   "${stage}/"
    cp "${SRC_DIR}/out/linux_release_arm64/icudtl.dat"           "${stage}/"
    cp "${SRC_DIR}/out/linux_release_arm64/clang_x64/gen_snapshot" \
       "${stage}/gen_snapshot_host_x64_target_arm64"
    package "${tarball}" \
            "${stage}" \
            libflutter_engine.so flutter_embedder.h icudtl.dat \
            gen_snapshot_host_x64_target_arm64
    rm -rf "${stage}"
}

# Official GTK desktop embedder (flutter_linux) for arm64. Unlike the bare
# embedder (libflutter_engine.so, consumed by flutter-pi), this is the
# libflutter_linux_gtk.so used by a compiled GTK runner — the path the arm64
# carts move to (Wayland client on sway). Reuses the same linux_release_arm64
# gn config as build_arm64_release (gn gen is idempotent), so if both run the
# out tree is shared. Ships the public flutter_linux headers so the downstream
# cmake runner can compile against them.
build_arm64_gtk_release() {
    local tarball="flutter_engine_linux_arm64_gtk_release-${ENGINE_SHA}.tar.gz"
    already_built "${tarball}" && return 0
    run_gn linux_release_arm64 \
        "${COMMON_GN_FLAGS[@]}" --runtime-mode=release --linux --linux-cpu=arm64 \
        --embedder-for-target
    run_ninja linux_release_arm64 \
        flutter/shell/platform/linux:flutter_linux_gtk
    local stage
    stage="$(mktemp -d)"
    cp "${SRC_DIR}/out/linux_release_arm64/libflutter_linux_gtk.so" "${stage}/"
    cp "${SRC_DIR}/out/linux_release_arm64/icudtl.dat"              "${stage}/"
    # Public GTK embedder headers (umbrella flutter_linux.h + fl_*.h).
    mkdir -p "${stage}/flutter_linux"
    cp "${FLUTTER_DIR}"/shell/platform/linux/public/flutter_linux/*.h \
       "${stage}/flutter_linux/"
    package "${tarball}" \
            "${stage}" \
            libflutter_linux_gtk.so icudtl.dat flutter_linux
    rm -rf "${stage}"
}

for v in ${VARIANTS}; do
    case "$v" in
        x64_release)      build_x64_release      ;;
        x64_debug)        build_x64_debug        ;;
        arm64_release)    build_arm64_release    ;;
        arm64_gtk_release) build_arm64_gtk_release ;;
        *) fail "unknown variant: $v" ;;
    esac
done

# ----------------------------------------------------------------------
# Checksums
# ----------------------------------------------------------------------
log "Computing SHA256 of artifacts"
(
    cd "${ARTIFACTS_DIR}"
    sha256sum *.tar.gz > SHA256SUMS
    cat SHA256SUMS
)

log "Done. Artifacts in /work/artifacts (= host scratch dir)."
