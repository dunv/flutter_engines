# flutter_engines

Builds and hosts Linux Flutter engine binaries (`libflutter_engine.so`
+ `gen_snapshot`) for arbitrary engine SHAs, packaged as flat tarballs
suitable for direct consumption by Bazel `http_archive`, CMake
`ExternalProject`, or anything else that fetches a URL.

Modeled after
[`ardera/flutter-engine-binaries-for-arm`](https://github.com/ardera/flutter-engine-binaries-for-arm).

## Why

- **Flutter's CDN ships no release-flavored x64 embedder.** At
  `storage.googleapis.com/flutter_infra_release/flutter/<sha>/linux-x64/`
  only `linux-x64-embedder.zip` exists, and it's a **debug-mode** build
  of `libflutter_engine.so`. That forces x64 deployments into JIT
  (`kernel_blob.bin`) instead of AOT (`app.so`).
- The arm64 release engine is available from `ardera/flutter-engine-binaries-for-arm`,
  but only for engine SHAs that project chooses to publish.

This repo can build x64 release, x64 debug, and arm64 release engines
from one consistent toolchain at any engine SHA you ask for.

## What gets built

Per engine SHA, three flat tarballs:

| Tarball | Mode | Target | Contents |
|---|---|---|---|
| `flutter_engine_linux_x64_release-<sha>.tar.gz` | release | x64 | `libflutter_engine.so` (AOT), `flutter_embedder.h`, `gen_snapshot` (host x64 → x64), `icudtl.dat` |
| `flutter_engine_linux_x64_debug-<sha>.tar.gz` | debug | x64 | `libflutter_engine.so` (JIT), `flutter_embedder.h` |
| `flutter_engine_linux_arm64_release-<sha>.tar.gz` | release | arm64 | `libflutter_engine.so` (AOT), `flutter_embedder.h`, `gen_snapshot_host_x64_target_arm64` (cross AOT), `icudtl.dat` |

Plus a `SHA256SUMS` file.

Tarballs are flat (no top-level dir) so a Bazel `http_archive` can
apply a `build_file` with no `strip_prefix`.

## Why a docker build, not Bazel / Nix

Flutter engine is built with `gclient` + `gn` + `ninja`. There is no
realistic path to driving that hermetically from Bazel or Nix — gclient
pulls Dart SDK, Skia, libc++, sysroots, and ~25GB of other deps from
chromium's CIPD and various git mirrors. We isolate all of that inside
an Ubuntu 22.04 container.

The build itself is **not hermetic**: it pulls from the public
internet (chromium.googlesource.com, github, Dart's CIPD endpoints).
The engine SHA pins `DEPS`, which pins everything except `depot_tools`.

## Disk + time requirements

- ~30–40 GB scratch space (gclient checkout + ninja outputs).
- ~1–2 h wall time on a fast x64 box (Ryzen 7950X-ish) for all three
  variants. Subsequent runs at the same engine SHA are incremental
  and much faster.
- 8+ CPU cores recommended. ninja parallelism defaults to `nproc`.
- Docker.

## Usage

### Find the engine SHA for your Flutter version

The engine SHA is recorded inside each Flutter SDK release at
`bin/internal/engine.version`. For example, Flutter 3.41.6's engine
SHA is `425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb`.

### Build

```sh
# All three variants:
./build_engine.sh 425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb

# Or one variant:
./build_engine.sh 425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb x64_release

# Custom scratch dir (default: ~/.cache/flutter_engine_build/<sha>):
SCRATCH_DIR=/scratch/flutter_engines ./build_engine.sh <sha>

# Throttle ninja jobs (default: nproc):
JOBS=8 ./build_engine.sh <sha>
```

Re-running with the same SHA is incremental: gclient sync is a no-op,
ninja rebuilds only what changed, and already-packaged tarballs are
skipped (delete them from `${SCRATCH_DIR}/artifacts/` to force a
rebuild).

### Publish a release

After the build finishes, three tarballs and a `SHA256SUMS` file are
in `${SCRATCH_DIR}/artifacts/`. Push them to a GitHub release tagged
`engine_<sha>` (matching ardera's tag convention so the download URL
is deterministic).

Fish syntax (for bash, swap `set X Y` for `X=Y`):

```fish
set sha 425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb
set artifacts ~/.cache/flutter_engine_build/$sha/artifacts

gh release create engine_$sha \
    --repo dunv/flutter_engines \
    --title "Flutter engine $sha" \
    --notes-file $artifacts/SHA256SUMS \
    $artifacts/flutter_engine_*.tar.gz \
    $artifacts/SHA256SUMS
```

Resulting download URLs:

```
https://github.com/dunv/flutter_engines/releases/download/engine_<sha>/flutter_engine_linux_<arch>_<mode>-<sha>.tar.gz
```

…which is exactly what a Bazel `http_archive(urls = [...])` expects.

## Building a new engine SHA

1. Look up the new SHA in your target Flutter SDK's
   `bin/internal/engine.version`.
2. `./build_engine.sh <new_sha>` — a fresh scratch dir will be
   created, gclient will re-fetch deps for the new SHA, and the three
   tarballs will land in `~/.cache/flutter_engine_build/<new_sha>/artifacts/`.
3. Publish via `gh release create engine_<new_sha> ...` (see above).
4. Update the consuming project's `MODULE.bazel` `http_archive(urls = ..., sha256 = ...)` entries.

## Layout

```
.
├── Dockerfile         # ubuntu 22.04 + depot_tools + non-root build user
├── build.sh           # in-container driver: gclient sync → gn → ninja → tar
├── build_engine.sh    # host wrapper: docker build + docker run
├── LICENSE            # MIT, covers this repo's scripts only
└── README.md
```

## Known gotchas

- **gclient is chatty.** First sync downloads ~25GB and prints a lot.
  Be patient. If it stalls, network is usually the culprit — we run
  with `--network=host` to avoid docker DNS issues.
- **arm64 build is a cross-build from x64.** `gn` does this out of the
  box; engine ships its own arm64 sysroot via gclient. No qemu or
  docker-buildx required.
- **`--embedder-for-target` is mandatory for cross builds.** Without
  it, the embedder group target is empty on the arm64 toolchain
  (`//flutter/shell/platform/embedder:BUILD.gn` gates it on
  `current_toolchain == host_toolchain || embedder_for_target`).
- **`--no-enable-unittests`** sidesteps a `wayland_dir`-not-in-scope
  gn error coming from `//flutter/third_party/angle/BUILD.gn:1204`,
  which is only reachable through the unittests target. We don't ship
  unit tests anyway.
- **DWARF5 readelf warnings.** Ubuntu 22.04's binutils 2.38 doesn't
  understand `DW_FORM_loclistx`/`rnglistx` that the engine's clang
  emits — cosmetic only, build succeeds.
- **depot_tools floats.** We don't pin its revision because engine
  builds at our SHA work with any recent depot_tools. To pin: pass
  `--build-arg DEPOT_TOOLS_REF=<commit>` to the docker build line.

## Engine source

Since late 2024, the Flutter engine source lives at `engine/src/flutter/`
inside [`flutter/flutter`](https://github.com/flutter/flutter); the
old `flutter/engine` repo is archived. SHAs after the merge only
resolve in `flutter/flutter`. The build script's gclient bootstrap
uses `engine/scripts/standard.gclient` from the new monorepo layout.

## License & disclaimers

The scripts in this repo (`Dockerfile`, `build.sh`, `build_engine.sh`,
`README.md`) are licensed under the **MIT License** — see [`LICENSE`](LICENSE).

The **Flutter engine binaries** published to this repo's GitHub
Releases are derivative works of upstream [Flutter](https://github.com/flutter/flutter)
(BSD-3-Clause), [Dart](https://github.com/dart-lang/sdk) (BSD-3-Clause),
[Skia](https://skia.googlesource.com/skia) (BSD-3-Clause), [ICU](https://icu.unicode.org/)
(Unicode license), and many other components with their own
permissive licenses. Each release tarball bundles the upstream Flutter
`LICENSE` file alongside the binaries. Consumers redistributing these
binaries are responsible for upstream license compliance.

This is a **convenience tool** maintained on a best-effort basis. It
is **not affiliated with, endorsed by, or supported by** Google, the
Flutter project, Dart, Skia, or any other upstream. The build process
fetches dependencies from public mirrors at build time and is not
guaranteed to be reproducible if those mirrors change.

The binaries and scripts are provided **AS IS, WITHOUT WARRANTY OF
ANY KIND**, as stated in the MIT license text. Use at your own risk.
