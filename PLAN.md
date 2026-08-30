# vdodtor — Implementation Plan

**This file is the source of truth for progress.** Product decisions live in
[docs/product-brief.md](docs/product-brief.md); this file tracks *how* the product gets
built and *how far* along it is. Update it in the same commit as the work it describes.

**Conventions**
- `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked (append a note)
- A milestone is complete only when all its **exit criteria** pass — checkboxes alone don't count.
- Keep the status line below current whenever a milestone starts or finishes.

> **Status: M1 all but done — engine, app shell, import and the timeline are in;
> the exit criteria need one run by hand.**
>
> Done: real repo tree, vendored universal **LGPL** FFmpeg 9.0.1, CMake engine wired into the
> Flutter build, the whole **document model** (rational time, scene graph, undo, autosave,
> crash recovery, import — 268 Dart tests), and the **media probe** through the full
> Dart → FFI → engine → FFmpeg chain, verified running under the App Sandbox.
>
> Preview plays with sound, and someone has now watched it do it. Measured in the running
> app at 1920x1080/30, audio-driven: **30.0 fps exactly, 0 late frames, 0 underruns**,
> ~0.9 ms GPU composite, media time accurate to 0.1% of wall time over three seconds.
> Measure with the screen awake: a locked display throttles the compositor to ~5 ms and
> makes the numbers look four times worse than they are. Scrub is ~28 ms on the committed
> fixtures and **100–380 ms on real long-GOP footage** — see the risk register.
>
> The app launches into a **project chooser**: make a project (aspect + frame rate), reopen
> one, or take back the one the app died with. Projects live in `~/Movies/vdodtor` and save
> themselves on every edit — there is no Save command and never will be.
>
> **Footage gets in now**, and stays in. The file panel and a drop target over the whole
> window both land in one importer, which probes off the UI isolate, appends to the main or
> audio track, and is one undo entry however many files arrived. Every imported file is
> bookmarked at the moment access is granted, so reopening a project reopens its media —
> verified against the real sandbox: minted, resolved, granted, and a folder renamed behind
> the app's back was relinked on open and played at 30.0 fps with 0 late frames. The media
> bin draws each asset through the *same compositor* as the preview, so a portrait clip
> looks portrait in the bin.
>
> **The timeline is real.** S2's canvas, rebuilt against the actual document: lanes, clips
> with names and lengths, a ruler that labels frames when it is zoomed in and minutes when
> it is not, and a playhead that *is* the engine's position rather than a copy kept in step
> with it. Scrubbing the ruler seeks the engine on every pointer move, frame-snapped —
> confirmed on screen, and playback drags the playhead along at 30 fps with **0 late
> frames**, so repainting it once a vsync costs the preview nothing.
>
> Editing clips — trim, split, move, ripple-delete — is deliberately **not** here. That is
> M2's first bullet, and this milestone only ever needed to show the document and scrub it.
>
> Next: M2, starting with the edits the timeline is now the surface for.
>
> **Owner checks outstanding**, both needing hands rather than a script: dropping files on
> the window (everything around the drop is verified — panel, bookmarks, relink, and that
> the transparent drop view does not eat mouse input), and whether the timeline feels good
> to scrub, which is the S2 question that was never a performance question.
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
- [ ] **Owner check outstanding:** does it feel good in the hand? No longer a question for
      the spike — the real timeline is in the app as of M1, so scrub *that*

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
- [x] Re-enable the App Sandbox; security-scoped bookmarks for user media
      — sandbox is on and verified (it blocks arbitrary paths; the app reads its own bundle).
      Project files need no bookmark and no panel: they live in `~/Movies/vdodtor` under
      `com.apple.security.assets.movies.read-write`, which grants the whole tree, so the
      atomic write's `.tmp` and `.bak` siblings are legal and a project always reopens.
      Imported media does need one, and gets it at the only moment it can be had: the
      instant the panel or the drop grants access. Opening a project resolves every
      bookmark and holds the scope until the project closes, which is also why closing
      releases them — the sandbox counts open scopes per process. A bookmark that comes
      back **stale** is relinked: the asset takes the path it actually resolved to and the
      refreshed bookmark is written straight through, outside the undo stack, because
      where a file lives is a fact about the disk rather than an edit anyone made.
      One thing learned the hard way and worth not relearning: a file **inside the app
      bundle cannot be bookmarked at all** (`Could not open() the item`) — the sandbox
      grants it for being the app's own, not through a scope there is anything to remember
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
- [x] Audio: decode → resample to 48 kHz stereo → device output (single-track mix)
      — the shape is dictated by one fact: the device calls back on a real-time thread
      that may not lock, allocate or touch a file. So decoding happens on an ordinary
      thread and reaches the device through a lock-free SPSC ring. Seeks land 200 ms
      early and decode into the target, because a cold AAC decoder and a warm one
      produce different samples for the same packet, and scrubbing has to be repeatable
- [x] A/V sync clock — audio is the master whenever there is audio being consumed.
      A video frame a millisecond late is invisible; audio cannot be stretched or
      skipped without the listener hearing it. The clock is the device's own frame
      counter, so drift is impossible by construction rather than corrected for
- [x] Thumbnails: one frame, small, for the media bin — and pointedly *not* a second
      imaging path. `vd_thumbnail_render` opens an ordinary decoder, asks for one frame and
      runs it through the ordinary compositor at a small size, so the YCbCr matrix, the
      rotation and the sample aspect are right for the same reason they are right on
      screen. It returns the source's **display** shape rather than a fixed box, never
      upscales, and answers `VD_ERR_UNSUPPORTED` for a file with no picture — which is a
      fact about an audio asset, not a failure to report. Checked on pixels against the
      same constants the compositor test uses
- [x] **GPU compositor** (pulled forward from M2 — preview needs it) — one compositor for
      preview and export, precompiled `.metallib` embedded in the binary, N alpha-blended
      layers, contain/cover/stretch fit, rotation. The YCbCr matrix is read from the
      source rather than assumed: BT.601, BT.709 and BT.2020, with the SD/HD fallback for
      untagged files. Checked on pixels against ffmpeg's own conversion

### App
- [x] Project create (aspect: 9:16/16:9/1:1/4:5 + fps: 24/25/30/60) / open / recents
      — a chooser window, a New Project dialog that draws the shape it is about to make,
      and one list that is the library and the recents merged, newest-opened first. Creating
      a project asks nothing but the name: no file panel, no location, no "where did it go".
      A project that has been moved or deleted stays on the list, greyed out, because
      "where did my project go" deserves an answer rather than a shorter list. A run that
      ended in a crash is offered back by name at the next launch — every edit was already
      written. The whole lifecycle lives in `Workspace`, outside the widget tree, so the part
      where losing someone's work is possible is the part that has tests
- [x] Import via drag-drop + file picker; media bin with thumbnails
      — one importer behind both doors. It probes the whole batch on a single background
      isolate (one hop, not one per file), skips what is already in the bin by path,
      expands a dropped folder one level, sends anything with a picture to the main track
      and audio-only files to the audio track, and commits the lot as **one gesture** — so
      dropping eight clips is one undo. A file that will not open fails on its own and the
      other seven still land. The drop target is a transparent AppKit view over the whole
      Flutter view whose `hitTest:` returns nil, so a drag anywhere in the window is a drop
      anywhere in the window and ordinary mouse input passes straight through — verified by
      posting a real click through it. The panel is a sheet, never `runModal`, which would
      spin its own run loop on the thread Flutter draws on.
      The bin keeps an asset whose file has gone missing, greyed and labelled, because an
      asset the user can point at again is worth more than a shorter list
- [x] Timeline (from S2) bound to the real document; scrubbing drives the engine
      — one `CustomPainter` for the whole thing, not a widget per clip, which is what S2
      was run to find out; offscreen clips are culled, so the cost stays flat in clip
      count. The split is deliberate: `TimelineGeometry` is a pure value type holding all
      the arithmetic (ticks to pixels, zoom pinned to the cursor, lane hit-testing, ruler
      steps that always land on a real frame), so the part that can be subtly wrong is the
      part that needs no window to test. The controller holds *view* state only — the
      document stays in the store and the playhead stays in the engine, so there is one
      copy of each and no way for them to disagree. A seek is frame-snapped, because a
      playhead resting between two frames names a picture that does not exist.
      Playback moves the playhead from a ticker that runs only while playing, dirtying one
      `RepaintBoundary` — the same discipline `EnginePreview` needed, for the same reason.
      The transport slider is gone: it scrubbed the same playhead over the same range as
      the ruler now does, and two controls for one value is one of them always wrong
- [x] **Preview repaint pump**: `textureFrameAvailable:` does not schedule a Flutter frame
      on macOS + Impeller (measured: 0 ui fps without a ticker). `EnginePreview` drives
      repaints from a ticker that runs only during playback and dirties a single
      `RepaintBoundary` containing only the `Texture` — no rebuilds, nothing else in the
      tree repaints. **Confirmed on screen**, on an unlocked display: playback advances
      frame by frame and across a clip boundary at 30.1 fps with 0 late frames, and the
      paused case — where the ticker is stopped by design and the frame arrives on the
      engine's own notification — leaves the correct, *different* frame on screen at each
      seek position. The rotated sample is visibly upright and pillarboxed inside the 16:9
      project, so rotation and contain-fit are right on screen and not just in the PNG dump.

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
| **Scrub latency on long-GOP media** | **Open, and now measured.** A seek decodes forward from the preceding keyframe, so its cost is set by keyframe spacing, not resolution. A real 1080p25 stock clip with keyframes only at 0 s and 10 s seeks in 91–380 ms (mean 215) where the committed fixtures take 36 ms — and M0's 13 ms p50 came from denser media. Ordinary exported footage looks like this, so scrubbing needs a strategy of its own (proxies are already in the brief's fast-follow) before it can be called good. Bin thumbnails pay the same toll — they are decodes — which is why they run off the UI isolate, two at a time |
| FFmpeg LGPL compliance in a sold, notarized app | **Half retired in M1** — a universal LGPL 2.1 build is vendored and dynamically linked, and the build script fails rather than emit a GPL or non-free configuration. Still open: the written source offer and signing the nested dylibs, both in M4 packaging |
| Preview/export parity drift | One compositor + golden-frame CI from M2, parity tests in M4 |
| Solo-dev scope creep | Milestone exit criteria are the guardrails; anything not in the brief goes to Post-v1 |
