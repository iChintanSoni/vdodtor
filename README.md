# vdodtor

An easy-to-use desktop video editor — full multi-track capability without the clutter.
No watermark, no account, no ads, fully offline. *"The Affinity of video editors."*

- **[docs/product-brief.md](docs/product-brief.md)** — what the product is and why.
- **[PLAN.md](PLAN.md)** — how it gets built, and how far along it is. Source of truth for progress.
- **[docs/spike-notes.md](docs/spike-notes.md)** — M0 findings that shaped the architecture.

## Layout

```
app/       Flutter desktop app — document model, commands/undo, UI
  packages/vdodtor_engine/   FFI plugin: Dart bindings + the macOS build glue
engine/    Native engine (C, CMake) — FFmpeg demux/decode + Metal compositor
site/      vdodtor.app — static pages serving the addresses the app opens
tools/     Build scripts, including the vendored FFmpeg build
docs/      Product brief, spike notes, design docs
spikes/    M0 throwaway code. Do not build on it.
```

## Building

Requires Flutter 3.47+, Xcode 26+, CMake, and nasm.

```sh
brew install cmake nasm

# One-off: build the vendored universal LGPL FFmpeg (~10 min, two architectures).
tools/build_ffmpeg.sh

# Engine, with its unit tests.
cmake -S engine -B build/engine -DCMAKE_BUILD_TYPE=Release
cmake --build build/engine
ctest --test-dir build/engine --output-on-failure

# App. The Flutter build drives the engine's CMake build as an Xcode phase.
cd app
flutter pub get
flutter test
flutter run --debug
```

Regenerate the FFI bindings after changing any engine header:

```sh
cd app/packages/vdodtor_engine && dart run ffigen --config ffigen.yaml
```

## Third-party

FFmpeg is used under the **LGPL v2.1**, dynamically linked, built from unmodified
upstream sources with no GPL or non-free components. `tools/build_ffmpeg.sh` records the
exact version, checksum and configure flags in `third_party/ffmpeg/BUILD_INFO.txt`, and
refuses to produce a build with `CONFIG_GPL`, `CONFIG_NONFREE` or `CONFIG_VERSION3` set.
