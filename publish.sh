#!/usr/bin/env bash
#
# Publish a GitHub release for an already-built engine SHA.
# Pulls artifacts from a remote build host via rsync into a /tmp
# staging dir on this machine, verifies SHA256SUMS, uploads to the
# GitHub release tagged engine_<sha>, and cleans up the staging dir.
#
# This split exists because the build is heavy (~40GB scratch, ~hours
# of CPU) and naturally lives on a beefier box, but `gh` is usually
# authenticated on the user's workstation. Run the build there, the
# publish here.
#
# Usage:
#   ./publish.sh <ENGINE_SHA> <BUILD_HOST>
#   BUILD_HOST=builder.lan ./publish.sh <ENGINE_SHA>
#
# Where BUILD_HOST is anything ssh/rsync resolves: a hostname, a
# ~/.ssh/config alias, or user@host. Artifacts are pulled from
#   <BUILD_HOST>:~/.cache/flutter_engine_build/<sha>/artifacts/
# unless REMOTE_ARTIFACTS overrides the remote path (e.g. when the
# build used a non-default SCRATCH_DIR).
#
# Other env knobs:
#   REPO              GitHub repo, default dunv/flutter_engines
#   REMOTE_ARTIFACTS  remote dir to rsync from

set -euo pipefail

if [[ $# -ge 1 && -n "${1:-}" ]]; then
    ENGINE_SHA="$1"; shift
fi
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    BUILD_HOST="$1"; shift
fi
: "${ENGINE_SHA:?ENGINE_SHA is required (pass as first arg or env var)}"
: "${BUILD_HOST:?BUILD_HOST is required (pass as second arg or env var)}"

REPO="${REPO:-dunv/flutter_engines}"
REMOTE_ARTIFACTS="${REMOTE_ARTIFACTS:-.cache/flutter_engine_build/${ENGINE_SHA}/artifacts/}"

# /tmp on most systems is tmpfs and gets wiped on reboot — perfect for
# transient staging. The trap ensures we don't leave ~half a GB of
# tarballs sitting around if anything fails partway through.
staging="$(mktemp -d -t flutter-engine-publish.XXXXXX)"
trap 'rm -rf "$staging"' EXIT

echo "=== Engine SHA   : ${ENGINE_SHA}"
echo "=== Build host   : ${BUILD_HOST}"
echo "=== Remote path  : ${REMOTE_ARTIFACTS}"
echo "=== Staging dir  : ${staging}"
echo "=== GH repo      : ${REPO}"
echo

echo "=== Rsyncing artifacts from build host"
rsync -avh --progress \
    "${BUILD_HOST}:${REMOTE_ARTIFACTS}" \
    "${staging}/"

echo
echo "=== Verifying SHA256SUMS (independent integrity check after transfer)"
(cd "${staging}" && sha256sum -c SHA256SUMS)

echo
echo "=== Creating GitHub release engine_${ENGINE_SHA} on ${REPO}"
gh release create "engine_${ENGINE_SHA}" \
    --repo "${REPO}" \
    --title "Flutter engine ${ENGINE_SHA}" \
    --notes-file "${staging}/SHA256SUMS" \
    "${staging}"/flutter_engine_*.tar.gz \
    "${staging}/SHA256SUMS"

echo
echo "=== Release URL:"
gh release view "engine_${ENGINE_SHA}" --repo "${REPO}" --json url --jq .url
