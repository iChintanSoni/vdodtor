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

M1 is under way: the document model, the engine (decode, audio, compositor, transport),
the project chooser and import are in; the timeline is not. See PLAN.md.

```
app/       Flutter app (`lib/model`, `lib/commands`, `lib/persistence`, `lib/engine`,
           `lib/media` — import, thumbnails, waveforms, sandbox file access — and
           `lib/ui`)
  packages/vdodtor_engine/   FFI plugin — ffigen bindings, the macOS podspec that drives
                             CMake, the preview texture and the open panel / drop target
engine/    C engine (CMake): vd_time (tick math), vd_probe, vd_decoder, vd_compositor
           (Metal), vd_audio_*, vd_engine (transport), vd_thumbnail, vd_peaks
tools/     build_ffmpeg.sh — vendors universal LGPL FFmpeg into third_party/ffmpeg
```

### Commands

```sh
brew install cmake nasm          # once
tools/build_ffmpeg.sh            # once, ~10 min; required before any engine build

cmake -S engine -B build/engine -DCMAKE_BUILD_TYPE=Release
cmake --build build/engine
ctest --test-dir build/engine --output-on-failure

# after an intentional change to how the compositor draws, re-approve the
# golden frames — then read `git diff` on the PNGs, which is the actual approval:
VD_UPDATE_GOLDENS=1 ctest --test-dir build/engine -R vd_golden_test

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
- **The audio envelopes are written twice and tested once.** `vd_audio_fade_gain` /
  `ClipAudio.fadeShapeAt` and `vd_audio_automation_gain` / `ClipAudio.automationAt` are
  each one function in two languages, and each has one table asserted in both test suites
  — like `vd_time` and `time.dart`. Change one and you must change the other.
- **A volume point is measured in the source, not in the clip.** `VolumePoint.sourceTime`
  is the coordinate `Clip.sourceIn` is in, so a trim slides the clip's window over the
  curve instead of dragging the curve with it, a split needs no dividing, and points
  outside a clip's window are kept rather than swept up. Anything that changes a clip's
  length or window must leave `ClipAudio.points` alone.
- **A frame is on screen until the next frame starts.** Not for the duration the
  container gave it: muxers write per-frame durations in *decode* order, so with B-frames
  they land on the wrong frames, and on a variable-rate source believing them puts frames
  from the future on screen. `vd_decoder_frame_at` therefore decodes one frame past the
  one it wants — that frame is what ends the previous one's interval — and a cached
  duration is only trusted once `confirmed` says the next frame set it.
- **A source's shape comes from its metadata, and the same metadata everywhere.**
  `VdLayer` carries both `rotation_degrees` and `pixel_aspect`, applied in that order
  (widen, then turn — a quarter turn puts the stretch on the other axis). Preview,
  thumbnail and `MediaProbe.displayWidth` all derive the display size the same way, and
  they have to: the bin drawing one shape while the preview draws another is the failure
  `vd_thumbnail.h` exists to prevent.
- **The lane decides which half of a file a clip contributes.** A clip on an audio lane is
  sound even when its source has a picture — that is what a detached clip is — so
  `timeline_sync` sets `hasVideo` from the track kind, not from the probe alone.
- **The compositor is pinned by golden frames.** `engine/tests/golden/*.png` are whole
  composited frames compared pixel for pixel, so any change to how the picture is drawn
  turns `vd_golden_test` red — including changes that are correct. That is the point:
  re-approve with the command above and look at the image diff. A failing run leaves the
  actual frame and an amplified difference in `build/engine/tests/golden-failures/`.
- **The engine analyses peaks; the app owns the peak file.** `vd_peaks_analyze` returns
  a pyramid in memory and knows nothing about where it is kept.
  `app/lib/media/peaks.dart` is the only definition of the on-disk format, so there is
  one parser rather than a C writer and a Dart reader to keep in step. Bump
  `PeakFile.version` for any change to the layout and every cached file is thrown away
  unread, which is the whole migration story a cache needs. Peaks are a property of the
  **file**: volume, fades and mute scale the drawn envelope at paint time, so nothing
  about a clip can invalidate one.
- **`spikes/` is throwaway M0 code.** Read it for reference; do not build on it.

Remote: `https://github.com/iChintanSoni/vdodtor.git` (branch `master`, also the main branch).
