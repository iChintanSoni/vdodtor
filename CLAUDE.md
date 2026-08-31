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
           `lib/media` — import, thumbnails, waveforms, bundled fonts, sandbox file
           access — and `lib/ui`); `assets/fonts` holds the five OFL faces a caption
           can be set in
  packages/vdodtor_engine/   FFI plugin — ffigen bindings, the macOS podspec that drives
                             CMake, the preview texture and the open panel / drop target
engine/    C engine (CMake): vd_time (tick math), vd_anim (in/out presets), vd_probe,
           vd_decoder, vd_sticker (GIF/APNG/WebP overlays), vd_compositor (Metal),
           vd_raster (the frame a drawn source draws into), vd_text (Core Text
           captions), vd_shape (rect/ellipse/line/arrow), vd_audio_*,
           vd_engine (transport), vd_thumbnail, vd_peaks
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
- **A sticker is a file the decoder cannot open.** A GIF, an animated WebP or an
  APNG goes through `vd_sticker`, not `vd_decoder`, and not as a preference:
  `vd_decoder` exports VideoToolbox or YUV420P and refuses everything else, so a
  sticker through it produces no frame at all. It also has no keyframes to seek to
  (every frame is a patch on the one before), and its alpha is the point of it. So
  it is decoded **whole** at open into one flat allocation of premultiplied BGRA
  and costs nothing per frame afterwards.
- **A sticker is retimed by being asked the time, not by resampling.** Each frame
  carries the interval it is on screen for in ticks, and a lookup finds the interval
  containing the instant — so nothing in `vd_sticker` knows the project's frame rate,
  and a 4 fps sticker is right at 24, 30 and 60. `VdEngineStats::sticker_frames` is
  how that is asserted: it ticks at the *sticker's* rate, so thirty renders across a
  four-frame loop cost four. `engine/tests/media/sticker_uneven.gif` exists to pin it
  — read at its nominal rate 0.4 s is the second frame, and read by time it is still
  the first.
- **A sticker loops, so nothing bounds how long it may be.** `MediaKind.isEndless`
  covers it and stills together: its own length is the length of one loop, not a
  limit, so it lands at the still-image length and `maxDurationFor` returns zero.
  One frame is held in one IOSurface and rewritten when it changes — a hundred-frame
  GIF must not spend a hundred of them to show one — and the memory budget **scales
  rather than truncates**: too big means decoded smaller, never shorter.
- **What makes a file a sticker is its codec, and that list is written twice.**
  `vd_sticker_is_sticker_codec` and `MediaProbe.stickerCodecs`, with one table
  asserted in `vd_sticker_test.c` and `app/test/model/media_sticker_test.dart` — the
  `vd_time.c`/`time.dart` arrangement, and necessary for the same reason in both
  directions: the engine classifies with no Dart, and the app classifies a project
  read back from disk with no engine. `MediaProbe.kindFor` is the one rule, applied
  by the probe *and* by the project decoder, so a GIF written down as video by an
  older version opens as a sticker with no migration step.
- **A sticker lands on an overlay lane, contained.** The main lane is magnetic, so a
  sticker there would repack the footage and then composite underneath it; and the
  default fit every other clip gets is blur-fill, which paints a blurred copy of the
  overlay across the whole shot and hides the picture it is an overlay on. Both are
  set in `MediaImporter.place`, not in the engine.
- **A shape is a caption with different ink.** `vd_shape_render` draws a rectangle,
  an ellipse, a line or an arrow into the same output-sized premultiplied BGRA buffer
  `vd_text_render` produces, and the engine hands it to the compositor as the same
  ordinary `VdLayer` — same transform, same opacity, same z-order, same in/out
  animation, same "keep the raster until the spec changes" cache. Adding it cost one
  field on `VdTimelineClip`, which is the return on the decision the entry below
  describes. `vd_raster` is the pixel buffer, the context and the colour both of them
  need, written once; `engine/tests/vd_ink.h` is how both test files read one back.
- **A shape's every length is a fraction of the output *height*.** Both of them —
  measured half against the width and half against the height, a shape changes shape
  when the project's aspect does, and a circle is only round at 16:9. This is one rule
  where `VdTextSpec` has two (a size against the output, the rest against the font
  size), because a caption has one size to hang things off and a shape has two.
  One box holds all four kinds: a rectangle fills it, an ellipse is inscribed in it, a
  line runs across its middle — so a line's box height changes nothing, and the
  inspector says so by not offering it.
- **A line has no interior, so the stroke *is* the shape.** `ClipShape.withKind`, not
  `copyWith(kind:)`: a filled rectangle turned into a line has its colour in the wrong
  field and no width, so it would vanish. Changing the kind carries the colour across
  and gives the stroke a width when there is none. A shape's shadow is cast from inside
  a transparency layer for the matching reason — one silhouette, one shadow, where a
  fill and a stroke shadowed separately show through each other.
- **A text lane holds anything the app draws.** `MoveClip.accepts` is written against
  `Clip.isGenerated`, not `isText`, so captions and shapes share the eight lanes and
  `VD_MAX_LAYERS` keeps one number to stay in step with. `ShapeKind` is a fourth enum
  crossing the boundary as an index, checked against `VdShapeKind` in
  `app/test/model/clip_shape_test.dart` the way `AnimationPreset` is. Append only.
- **A caption is a source, not a compositing mode.** `vd_text_render` lays a
  `VdTextSpec` out with Core Text into an output-sized premultiplied BGRA buffer, and
  the engine hands that to the compositor as an ordinary `VdLayer` — same transform,
  same opacity, same z-order as a decoded frame. It lives in the engine rather than in
  Flutter so that a frame stays a pure function of `(document, time)` with no UI
  attached: an export driven by a frame counter has to produce the caption the preview
  showed, and rasterising in Dart would make text the one exception. Nothing about a
  caption is measured in pixels — sizes, offsets, padding and spacing are fractions of
  the output height or of the font size — so a project cut at 1080p exports the same at
  4K.
- **A caption's raster is kept until the caption changes.** `vd_engine_set_timeline`
  carries a raster across an edit whose `vd_text_spec_equal` says nothing about that
  caption moved, exactly as it carries a decoder across an unchanged path.
  `VdEngineStats::text_rasters` is how that is asserted: it should tick once per edit
  that touched a caption and never during playback.
- **Text is checked on where the ink is, not on which pixels it covers.**
  `vd_text_test.c` measures ink bounds and coverage rather than comparing a golden
  frame, because glyph rasterisation is the part of Core Text most likely to be tuned in
  a macOS release — a reference PNG of a sentence would go red on an OS upgrade while
  the renderer was still correct. The compositor's goldens stay; text does not join them.
- **A face's family name is written down three times.** Inside the font file, in
  `BundledFonts.faces` (so the picker can list faces with no engine alive — a widget
  test has none), and in `app/pubspec.yaml` (so Flutter can preview one). `vd_text_test.c`
  checks the first against the second's claim and `app/test/media/fonts_test.dart`
  checks the second against the third. A mismatch is silent: the caption falls back to
  the system face and looks like somebody's decision.
- **Lane counts and `VD_MAX_LAYERS` move together.** `Project.maxTracksOfKind` allows one
  main, three overlays and eight text lanes; `VD_MAX_LAYERS` in `vd_engine.c` is their
  sum. A lane the document allows and the compositor drops is a caption that is on the
  timeline and not on the screen.
- **An animation is a pure function of one number, not a keyframe list.**
  `vd_anim_value(preset, t)` maps "how far through the entrance" to an offset, a scale,
  a turn, an opacity and a reveal; the engine evaluates it once per layer per frame and
  **composes** it with the transform the clip already has — offsets add, scale
  multiplies, rotation adds, opacity multiplies. No state crosses frames, so a seek into
  the middle of an animation shows exactly the frame playback would. Watch the compositor's
  "a zeroed scale means as-fitted" convention: resolve the scale to 1 *before* multiplying,
  or the animation is silently discarded by the later normalisation.
- **A preset names the direction the clip travels, not the edge it comes from.**
  `slideUp` rises into place on the way in and carries on upwards on the way out. One
  rule for both halves.
- **`vd_anim` is deliberately *not* mirrored in Dart.** The audio envelopes are written
  twice because the app draws them on a waveform; nothing draws an animation curve, so a
  second copy would be a second thing to keep in step with no reader. It is plain C with
  no platform dependency — the one piece of the picture testable without a GPU or a
  typeface. If the inspector ever previews a curve, that is the moment to port it *and*
  add the shared table, the way `vd_time.c` and `time.dart` have one.
- **The preset list is three enums in one order.** `AnimationPreset` (document),
  `EngineAnimPreset` (plugin) and `VdAnimPreset` (C) cross the boundary as an *index*, so
  a preset inserted in the middle of one renames every animation in every project on
  disk. `app/test/model/clip_animation_test.dart` compares all three, generated bindings
  included. Append only.
- **The typewriter is the one animation that is not a transform.** It reaches into the
  caption raster instead, so the engine's cache is keyed on `(spec, size, revealed
  characters)` — a caption redraws once per *character*, never once per frame, and stops
  entirely when the animation ends. `vd_text_render` lays out the **whole** caption and
  draws only a prefix of it, which is what makes characters arrive where they will
  finally sit instead of the line re-centring on every keystroke.
- **`spikes/` is throwaway M0 code.** Read it for reference; do not build on it.

Remote: `https://github.com/iChintanSoni/vdodtor.git` (branch `master`, also the main branch).
