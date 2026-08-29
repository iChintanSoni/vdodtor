# vdodtor — Implementation Plan

**This file is the source of truth for progress.** Product decisions live in
[docs/product-brief.md](docs/product-brief.md); this file tracks *how* the product gets
built and *how far* along it is. Update it in the same commit as the work it describes.

**Conventions**
- `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked (append a note)
- A milestone is complete only when all its **exit criteria** pass — checkboxes alone don't count.
- Keep the status line below current whenever a milestone starts or finishes.

> **Status: M1 in progress — foundation landed, engine and UI next.**
>
> Done: real repo tree, vendored universal **LGPL** FFmpeg 9.0.1, CMake engine wired into the
> Flutter build, the whole **document model** (rational time, scene graph, undo, autosave,
> crash recovery — 128 Dart tests), and the **media probe** through the full
> Dart → FFI → engine → FFmpeg chain, verified running under the App Sandbox.
>
> The preview pipeline is closed end to end: document → render list → decode → Metal
> composite → Flutter texture. Measured in the running app: 30 fps with 0 late frames,
> 1.0 ms GPU composite, 13 ms scrub.
>
> Next: audio out and the A/V sync clock, then bind the S2 timeline to the real document.
>
> M0 (complete) measured on Apple M3 Pro: 4K60 preview at 60 fps with 3 composite layers
> (~1.5 ms GPU), 4 concurrent 4K60 decoders at ~34% CPU, scrub p50 13 ms, timeline at
> 121 fps with 1002 clips. Findings: [docs/spike-notes.md](docs/spike-notes.md).

---

## Architecture at a glance

```
vdodtor/
├── app/         Flutter desktop app — UI, document model, commands/undo
│   └── packages/vdodtor_engine/   FFI plugin: ffigen bindings + the macOS build glue
├── engine/      Native library (C/C++, CMake) — FFmpeg demux/decode/encode + Metal compositor
├── tools/       Build scripts, including the vendored LGPL FFmpeg build
├── third_party/ Vendored FFmpeg (generated, not committed)
└── docs/        Product brief, spike notes, design docs
```

- **Bridge:** `dart:ffi` with ffigen-generated bindings; preview frames reach Flutter as an
  IOSurface-backed **external texture**.
- **Document model:** immutable scene graph of tracks/clips/properties. A rendered frame is a
  pure function of `(document, time)`. Time is integer ticks on a project timebase —
  float seconds are prohibited.
- **Engine interface:** engine-agnostic contract (document sync + transport + render commands),
  so a WebCodecs backend can slot in later for web-lite.
- **One compositor** serves both preview and export; they differ only in clock source
  (wall time vs frame counter) and output target (screen texture vs encoder surface).

---

## M0 — De-risking spikes

*Goal: prove the two riskiest pieces before committing to repo structure. Both are throwaway
code; findings land in `docs/spike-notes.md`.*

### S1 — Preview pipeline (the architecture bet) — **PASS**
- [x] Flutter macOS scaffold with an FFI plugin; C ABI engine callable from Dart
- [x] FFmpeg linked; 4K H.264 and HEVC demuxed and decoded via VideoToolbox hwaccel
- [x] Decoded frames → Metal composite pass → Flutter external texture
- [x] Play/pause/seek on a media clock; sustained 4K60 playback, zero drops
- [x] Measurements recorded (CPU, GPU ms, drops, scrub latency, Flutter raster time)
- [x] Output correctness verified by PNG dump, not just timings
- [x] Bonus: 4 concurrent 4K60 decoders sustain 60 fps at ~34% CPU

### S2 — Timeline UI (the product bet) — **PASS**
- [x] Pure-Flutter canvas timeline: 5 tracks, clips as blocks with drag / trim handles
- [x] Zoom pinned to cursor, snapping to clip edges + playhead, ripple-close on main track
- [x] 121 fps (display ceiling) with 1002 clips during a continuous drag — flat in clip count
- [ ] **Owner check outstanding:** does it feel good in the hand? Run `spikes/s2_timeline`

**Exit criteria:** met. S1 hits 4K60 with ~1.5 ms GPU cost and 13 ms median scrub;
S2 is not a performance problem at any realistic scale. **GO on the PLAN.md stack.**
Caveat on record: these are M3 Pro numbers — a ceiling, not a floor. A low-end reference
machine is still needed before any of this becomes a product guarantee (see PERF-06 below).

---

## M1 — "It plays" (walking skeleton)

*Goal: real repo structure; import a clip, see it on a timeline, scrub and play with audio.*

### Repo & tooling
- [x] Monorepo layout (`app/`, `engine/`, `docs/`); CMake build for engine wired into the Flutter build
      — the macOS podspec runs CMake as an Xcode phase and force-loads the archive, so
      there is one definition of what the engine is and the Windows port can reuse it
- [x] **Vendor a universal LGPL FFmpeg build** — `tools/build_ffmpeg.sh` builds 9.0.1 for
      arm64 + x86_64, pins the source checksum, and *refuses to finish* if `CONFIG_GPL`,
      `CONFIG_NONFREE` or `CONFIG_VERSION3` is set. The dylibs ride inside
      `vdodtor_engine.framework/Versions/A/Frameworks`, resolved by `@loader_path`
- [~] Re-enable the App Sandbox; security-scoped bookmarks for user media
      — sandbox is on and verified (it blocks arbitrary paths; the app reads its own bundle);
      `files.user-selected.read-write` and `files.bookmarks.app-scope` are granted, and
      `MediaAsset.bookmark` is modelled and persisted. **Minting and resolving the bookmark
      still needs native code** — nothing calls it yet
- [~] CI (**self-hosted** macOS runner): engine unit tests, `dart analyze`, `dart test`, app builds
      — `.github/workflows/ci.yml` runs on `[self-hosted, macOS, ARM64]`, so a green build
      means what a local build means: same Xcode, same Flutter, same signing identity.
      FFmpeg is cached in `~/.cache/vdodtor` — outside the workspace, keyed on the build
      script — so the checkout can clean normally without paying 10 minutes for it. The job
      refuses to install anything on the machine; `tools/setup_ci_runner.sh` registers the
      runner as a launchd service. **Runner not yet registered, so the workflow has not run**

### Document model (Dart)
- [x] Rational-time type + project timebase, with arithmetic tests — exact `Rational`,
      `Tick` as a zero-cost extension type, `TimeSpan`; the engine mirrors the same
      conversions in C and both sides test the same table
- [x] Scene graph: `Project`, `Track` (main / overlay / audio / text), `Clip`, properties
- [x] Immutable updates with structural sharing; command log; undo/redo — snapshot undo
      with gesture coalescing, so a 40-event drag is one undo entry
- [x] Project file save/load (JSON); autosave on every committed edit; crash recovery on launch
      — atomic write with one backup generation, debounced autosave, session marker

### Engine core (native)
- [x] Engine interface v1: document sync, transport (play/pause/seek), texture handle
      — `vd_engine` owns a clock, a render thread and a copy of the timeline. What
      crosses the boundary is a *render list*: flat clips with paths and times, never the
      scene graph, so a WebCodecs backend has one contract to implement. The Flutter
      texture is registered over the one method channel hop that FFI cannot do
- [x] **Drain in-flight GPU work before engine teardown** — solved by construction rather
      than by ordering: `vd_compositor_render` waits on the GPU before it returns, so
      nothing is ever in flight to outlive the engine. It costs about a millisecond of a
      16.6 ms budget and removes the whole class of bug. Teardown joins the render thread
      first; tested by destroying mid-playback at twelve different points
- [x] Media probe: streams, duration, fps, rotation, VFR detection — with committed
      fixtures covering constant-rate, rotated, VFR and audio-only sources
- [x] Decode session management, frame cache, keyframe seek index — `vd_decoder`
      is a *pull* API (`frame_at(tick)`), which is what makes "a frame is a pure
      function of (document, time)" true for one source, and what makes seek and cache
      behaviour testable exactly rather than approximately. VideoToolbox zero-copy with a
      software fallback that agrees with it frame for frame; bounded LRU cache; keyframe
      index from the container. Clamps at both ends, because a clip trimmed a tick past
      its source should show the last frame, not fail.
      Sessions are pooled per clip (not per path — two clips from one file need separate
      decode positions), capped at 8 open, LRU-evicted, and carried across timeline edits
      so nudging a clip does not reopen every decoder
- [ ] Audio: decode → resample to 48 kHz stereo → device output (single-track mix)
- [ ] A/V sync clock
- [x] **GPU compositor** (pulled forward from M2 — preview needs it) — one compositor for
      preview and export, precompiled `.metallib` embedded in the binary, N alpha-blended
      layers, contain/cover/stretch fit, rotation. The YCbCr matrix is read from the
      source rather than assumed: BT.601, BT.709 and BT.2020, with the SD/HD fallback for
      untagged files. Checked on pixels against ffmpeg's own conversion

### App
- [ ] Project create (aspect: 9:16/16:9/1:1/4:5 + fps: 24/25/30/60) / open / recents
      — the model and the recents store are done; there is no UI
- [ ] Import via drag-drop + file picker; media bin with thumbnails
- [ ] Timeline (from S2) bound to the real document; scrubbing drives the engine
- [~] **Preview repaint pump**: `textureFrameAvailable:` does not schedule a Flutter frame
      on macOS + Impeller (measured: 0 ui fps without a ticker). `EnginePreview` drives
      repaints from a ticker that runs only during playback and dirties a single
      `RepaintBoundary` containing only the `Texture` — no rebuilds, nothing else in the
      tree repaints. **Built but not yet confirmed on screen**: the engine's own output is
      verified by PNG dump, and the on-screen half still needs an eyeball on an unlocked
      display.

**Exit criteria:** create a project, drop 3 clips onto the main track, play end-to-end with
audio, scrub anywhere, quit and reopen with everything restored.

---

## M2 — "It cuts" (editing core)

- [ ] Trim in/out, split at playhead, move, delete-with-ripple (magnetic main track), duplicate
- [ ] Multi-select, copy/paste
- [ ] Parallel overlay video tracks (up to 3) with per-clip transform:
      position, scale, rotation, crop, opacity, flip
- [ ] GPU compositor: multi-layer render graph, alpha blend, fit modes
      (blur-fill default / fit / fill / stretch)
- [ ] Golden-frame tests for the compositor in CI (fixed scenes, fixed timestamps, strict tolerance)
- [ ] Audio: 6 tracks; per-clip volume, mute, fade in/out; detach audio from video
- [ ] Waveforms rendered from multi-resolution peak files at every zoom level
- [ ] Keyframed volume (manual ducking)
- [ ] Rotation metadata honored; VFR sources normalized to project timebase
- [ ] Keyboard shortcuts v1: space, split, delete, undo/redo, zoom, nudge

**Exit criteria:** cut a real 2-minute multi-track video (picture-in-picture + music bed)
start to finish without touching another editor; undo works through the whole session.

---

## M3 — "It's an editor" (text, overlays, effects)

### Text & shapes
- [ ] Text rendering with bundled fonts: fill, stroke, shadow, background box, spacing, alignment
- [ ] ~8 in/out animation presets (fade, slide, pop, scale, typewriter, …)
- [ ] Shape primitives: rect, rounded rect, circle, line/arrow — fill/stroke, same transforms
      and animation presets as text

### Stickers & GIFs
- [ ] GIF / animated WebP / APNG decode → cached RGBA sequences, retimed to project fps

### Transitions
- [ ] Cross-dissolve, slide/push, wipe, fade-to-black, fade-to-white; adjustable duration;
      overlap model (never fails for lack of media)

### Effects
- [ ] Color adjust on GPU: brightness, contrast, saturation, temperature, tint
- [ ] LUT filter presets (`.cube` loading, applied in linear working space)

### Speed
- [ ] Constant 0.1×–10× per clip; frame duplication for slow-mo
- [ ] Pitch-preserved audio time-stretch, with per-clip pitch-shift toggle

### Audio effects
- [ ] EQ presets and fade curves

**Exit criteria:** recreate a typical CapCut-style edit (text callouts, transitions, a filtered
look, one slow-mo moment) entirely in vdodtor.

---

## M4 — "It ships" (export, gating, packaging)

### Export
- [ ] Export path through the same compositor, frame-counter clock → VideoToolbox encode
- [ ] MP4 faststart; H.264 + HEVC (muxed as `hvc1`, not `hev1`); AAC-LC 48 kHz stereo
- [ ] Presets with estimated output size; disk-space preflight; cancel leaves no partial files
- [ ] Background export with progress
- [ ] Preview/export parity: golden-frame tests through both drivers in CI

### Free / Pro
- [ ] Resolution gate: 1080p free, 4K+ Pro — no watermark anywhere, ever
- [ ] Licensing: Paddle or Lemon Squeezy checkout; offline-friendly license validation;
      restore/deactivate flow
- [ ] Pro content packs plumbing (LUTs, transitions, templates, fonts)

### Packaging
- [ ] Signed + notarized DMG; auto-update channel
- [ ] Opt-in crash reporting; analytics none-or-anonymous (positioning demands restraint)

**Exit criteria:** a stranger can download the DMG, edit a video, hit the 4K gate,
buy Pro, and export 4K — with no help.

---

## M5 — Launch

- [ ] Resolve OQ-4: name/branding final; icon; website with direct download
- [ ] First-run experience: bundled sample project + 60-second tour
- [ ] Private beta; fix the top reported issues
- [ ] Launch: Product Hunt, r/videoediting, YouTube reviewer outreach,
      "no watermark video editor" SEO page (resolves OQ-5)

**Exit criteria:** v1.0 public; first-1,000-users plan in motion.

---

## Post-v1 (priority order)

1. **Fast-follow features:** chroma key · on-device auto-captions (stays free) · voiceover
   recording · keyframes on all transforms · 120 fps export · premium pack drops
2. **Windows port:** engine already FFmpeg; compositor backend decision (Vulkan/D3D or ANGLE);
   NVENC/QSV/AMF encode paths; installer + updater
3. **Web-lite funnel:** WebCodecs/WebGPU backend behind the engine interface;
   trim + captions + 720p export → desktop download
4. **Mobile:** Flutter UI and document model carry over; engine adapts per platform

---

## Risk register

| Risk | Mitigation / where it's retired |
|---|---|
| ~~Flutter external-texture throughput at 4K60~~ | **Retired in M0** — 60 fps sustained, ~1 ms Flutter raster cost |
| ~~Timeline performance at scale~~ | **Retired in M0** — 121 fps with 1002 clips, cost flat in clip count |
| Timeline interaction doesn't feel "easy" | Still open — perf is proven, taste is not. Owner runs `spikes/s2_timeline`; M2 exit criteria are the real test |
| Performance on low-end hardware is unknown | M0 measured only an M3 Pro. Name a low-end reference machine (PERF-06) and re-measure before promising anything |
| FFmpeg LGPL compliance in a sold, notarized app | **Half retired in M1** — a universal LGPL 2.1 build is vendored and dynamically linked, and the build script fails rather than emit a GPL or non-free configuration. Still open: the written source offer and signing the nested dylibs, both in M4 packaging |
| Preview/export parity drift | One compositor + golden-frame CI from M2, parity tests in M4 |
| Solo-dev scope creep | Milestone exit criteria are the guardrails; anything not in the brief goes to Post-v1 |
