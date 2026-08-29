# vdodtor — Implementation Plan

**This file is the source of truth for progress.** Product decisions live in
[docs/product-brief.md](docs/product-brief.md); this file tracks *how* the product gets
built and *how far* along it is. Update it in the same commit as the work it describes.

**Conventions**
- `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked (append a note)
- A milestone is complete only when all its **exit criteria** pass — checkboxes alone don't count.
- Keep the status line below current whenever a milestone starts or finishes.

> **Status: M0 complete — GO on this stack. Next action: M1, walking skeleton.**
>
> M0 measured on Apple M3 Pro: 4K60 preview at 60 fps with 3 composite layers (~1.5 ms GPU),
> 4 concurrent 4K60 decoders at ~34% CPU, scrub p50 13 ms, timeline at 121 fps with 1002 clips.
> Findings: [docs/spike-notes.md](docs/spike-notes.md).

---

## Architecture at a glance

```
vdodtor/
├── app/       Flutter desktop app — UI, document model, commands/undo
├── engine/    Native library (C/C++, CMake) — FFmpeg demux/decode/encode + Metal compositor
└── docs/      Product brief, spike notes, design docs
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
- [ ] Monorepo layout (`app/`, `engine/`, `docs/`); CMake build for engine wired into the Flutter build
- [ ] **Vendor a universal LGPL FFmpeg build** — the spike linked Homebrew's, which is GPL
      and arm64-only. Blocks shipping and blocks Intel Macs; do it before the engine grows.
- [ ] Re-enable the App Sandbox; security-scoped bookmarks for user media
- [ ] CI (GitHub Actions, macOS): engine unit tests, `dart analyze`, `dart test`, app builds

### Document model (Dart)
- [ ] Rational-time type + project timebase, with arithmetic tests
- [ ] Scene graph: `Project`, `Track` (main / overlay / audio / text), `Clip`, properties
- [ ] Immutable updates with structural sharing; command log; undo/redo
- [ ] Project file save/load (JSON); autosave on every committed edit; crash recovery on launch

### Engine core (native)
- [ ] Engine interface v1: document sync, transport (play/pause/seek), texture handle
- [ ] **Drain in-flight GPU work before engine teardown** — the spike's completion handlers
      captured the engine and outlived it. The use-after-free presented as gradual
      performance decay, not a crash, so make teardown ordering explicit and tested.
- [ ] Media probe: streams, duration, fps, rotation, VFR detection
- [ ] Decode session management, frame cache, keyframe seek index
- [ ] Audio: decode → resample to 48 kHz stereo → device output (single-track mix)
- [ ] A/V sync clock

### App
- [ ] Project create (aspect: 9:16/16:9/1:1/4:5 + fps: 24/25/30/60) / open / recents
- [ ] Import via drag-drop + file picker; media bin with thumbnails
- [ ] Timeline (from S2) bound to the real document; scrubbing drives the engine
- [ ] **Preview repaint pump**: `textureFrameAvailable:` does not schedule a Flutter frame
      on macOS + Impeller (measured: 0 ui fps without a ticker). Drive repaints from a
      ticker scoped to a `RepaintBoundary` around the `Texture`, running only during playback.

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
| FFmpeg LGPL compliance in a sold, notarized app | Vendor a universal LGPL build in M1 (the spike used Homebrew's GPL build); dynamic linking + source offer verified during M4 packaging |
| Preview/export parity drift | One compositor + golden-frame CI from M2, parity tests in M4 |
| Solo-dev scope creep | Milestone exit criteria are the guardrails; anything not in the brief goes to Post-v1 |
