# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**vdodtor** — an easy-to-use desktop video editor: "the Affinity of video editors."
Full multi-track capability with no watermark, no account, no ads, fully offline.

Two documents govern all work; consult them before starting anything:

- **`docs/product-brief.md`** — authoritative product decisions (features, platforms, monetization).
- **`PLAN.md`** — **the source of truth for progress.** Check it at the start of a task and
  update its checkboxes and status line in the same change as the work itself.

## Key decisions (summary — the brief is authoritative)

- Platform priority: **desktop first** (macOS v1, Windows fast-follow) → web-lite funnel → mobile.
- Stack: **Flutter desktop UI** + native engine (**FFmpeg**, LGPL build, hardware codecs +
  **Metal compositor**) over `dart:ffi`; preview via external texture.
- Document model: immutable scene graph; a rendered frame is a pure function of
  `(document, time)`; time is integer ticks on a project timebase — **never float seconds**.
- **One compositor** for preview and export; they differ only in clock and output target.
- Monetization: free full editor at 1080p (no watermark/account/ads);
  Pro = 4K export + premium packs, subscription or lifetime, sold direct.

## Repository state

M1 is under way: the document model, the vendored FFmpeg, the CMake engine and the
FFI bridge are in; the decode/audio engine and the editor UI are not. See PLAN.md.

```
app/       Flutter app (`lib/model`, `lib/commands`, `lib/persistence`, `lib/engine`)
  packages/vdodtor_engine/   FFI plugin — ffigen bindings + macOS podspec that drives CMake
engine/    C engine (CMake): `vd_time` (tick math), `vd_probe` (media probe)
tools/     build_ffmpeg.sh — vendors universal LGPL FFmpeg into third_party/ffmpeg
```

### Commands

```sh
brew install cmake nasm          # once
tools/build_ffmpeg.sh            # once, ~10 min; required before any engine build

cmake -S engine -B build/engine -DCMAKE_BUILD_TYPE=Release
cmake --build build/engine
ctest --test-dir build/engine --output-on-failure

cd app
flutter pub get && flutter test
dart analyze --fatal-infos lib test
flutter run -d macos

# after changing any engine header:
cd app/packages/vdodtor_engine && dart run ffigen --config ffigen.yaml
```

### Invariants worth knowing before editing

- **Time is `Tick`, never seconds.** `app/lib/model/time.dart` and
  `engine/include/vdodtor/vd_time.h` implement the same conversions and test the same
  table; change one and you must change the other.
- **`Project` is immutable with structural sharing.** Mutators return a new `Project`
  reusing untouched `Track` instances, so `identical()` is a valid O(1) "did this
  change?" test. Edits go through `EditCommand` + `DocumentStore`, never in place.
- **The vendored FFmpeg must stay LGPL.** `tools/build_ffmpeg.sh` fails the build rather
  than emit one with `CONFIG_GPL`, `CONFIG_NONFREE` or `CONFIG_VERSION3` set.
- **`spikes/` is throwaway M0 code.** Read it for reference; do not build on it.

Remote: `https://github.com/iChintanSoni/vdodtor.git` (branch `master`, also the main branch).
