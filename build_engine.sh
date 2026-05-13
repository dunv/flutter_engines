#!/usr/bin/env bash
#
# Host wrapper for the Flutter engine build. Builds the docker image
# and runs the container with a persistent scratch dir so subsequent
# runs reuse the gclient checkout (~30GB) and incremental ninja state.
#
# Usage:
#   ./build_engine.sh <ENGINE_SHA>                       # all three variants
#   ./build_engine.sh <ENGINE_SHA> x64_release           # one variant
#   ENGINE_SHA=<sha> ./build_engine.sh                   # SHA via env
#   SCRATCH_DIR=/big/disk ./build_engine.sh <ENGINE_SHA> # custom scratch
#
# Where ENGINE_SHA is a commit SHA in https://github.com/flutter/flutter
# (the engine source repo was merged into flutter/flutter in late 2024).
# To find the SHA for a given Flutter SDK version, look at
# bin/internal/engine.version inside that SDK release.
#
# Outputs land in ${SCRATCH_DIR}/artifacts/:
#   flutter_engine_linux_x64_release-<sha>.tar.gz
#   flutter_engine_linux_x64_debug-<sha>.tar.gz
#   flutter_engine_linux_arm64_release-<sha>.tar.gz
#   SHA256SUMS

set -euo pipefail

# This wrapper runs on the build host; the Dockerfile + in-container
# build.sh sit in the docker/ subdir. Resolve docker/ relative to this
# script's location so the wrapper works regardless of CWD.
DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/docker" && pwd)"

# SHA can come from arg 1 or the ENGINE_SHA env var. The arg wins so
# `ENGINE_SHA=<old> ./build_engine.sh <new>` always builds <new>.
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    ENGINE_SHA="$1"; shift
fi
: "${ENGINE_SHA:?ENGINE_SHA is required (pass as first arg or env var)}"

VARIANTS="${*:-x64_release x64_debug arm64_release}"

# Scratch dir survives across runs so gclient sync is incremental.
# ~30-40GB once fully populated.
SCRATCH_DIR="${SCRATCH_DIR:-${HOME}/.cache/flutter_engine_build/${ENGINE_SHA}}"
mkdir -p "${SCRATCH_DIR}"

IMAGE_TAG="flutter-engine-builder:local"

echo "=== Engine SHA   : ${ENGINE_SHA}"
echo "=== Variants     : ${VARIANTS}"
echo "=== Scratch dir  : ${SCRATCH_DIR}"
echo "=== Docker image : ${IMAGE_TAG}"
echo

echo "=== Building docker image"
docker build \
    --build-arg "BUILDER_UID=$(id -u)" \
    --build-arg "BUILDER_GID=$(id -g)" \
    -t "${IMAGE_TAG}" \
    "${DOCKER_DIR}"

echo
echo "=== Running build"
# --network=host so gclient sync can hit chromium.googlesource.com,
# github, dart's CIPD, etc. without docker DNS quirks.
docker run --rm -it \
    --network=host \
    -e "ENGINE_SHA=${ENGINE_SHA}" \
    -e "VARIANTS=${VARIANTS}" \
    -e "JOBS=${JOBS:-$(nproc)}" \
    -v "${SCRATCH_DIR}:/work" \
    "${IMAGE_TAG}"

echo
echo "=== Artifacts:"
ls -lh "${SCRATCH_DIR}/artifacts/"
echo
echo "=== Checksums:"
cat "${SCRATCH_DIR}/artifacts/SHA256SUMS"
