# M0 spike notes

Findings from the de-risking spikes in [PLAN.md](../PLAN.md) §M0. Spike code lives in
`spikes/` and is throwaway — it exists to answer questions, not to be built on.

**Reference machine:** MacBook Pro, Apple M3 Pro (6P + 6E), 36 GB RAM, macOS 26.6.2,
120 Hz ProMotion display. Flutter 3.47.0 / Dart 3.13, Xcode 26.6, FFmpeg 9.0.1 (Homebrew).
Every number below is from this machine only — it is a *ceiling*, not a floor.

---

## S1 — Preview pipeline · **GO**

### What was built

`spikes/s1_preview/` — a Flutter macOS app plus a `vdodtor_engine` plugin implementing
the full architecture from PLAN.md, end to end:

```
FFmpeg demux → VideoToolbox hw decode (NV12 CVPixelBuffer)
  → Metal composite pass (BT.709 YUV→RGB, N alpha-blended layers)
    → BGRA CVPixelBuffer (IOSurface-backed)
      → Flutter external texture (FlutterTexture / copyPixelBuffer)
```

Transport control (`play` / `pause` / `seek` / `stats`) goes to the engine over `dart:ffi`.
The method channel is used exactly once per clip, to register the texture, because only
the plugin registrar can mint a Flutter texture id. Two engine threads: `vd.decode`
(demux + decode into a bounded queue) and `vd.present` (pulls by media clock, composites,
publishes). Media time is integer nanoseconds anchored to `mach_absolute_time`.

### Results — release build, window frontmost, repaint ticker on

| case | eng fps | dropped | gpu ms | ui fps | raster p95 | cpu% | seek p50 | seek max |
|---|---|---|---|---|---|---|---|---|
| 4K60 H.264 → 1080p, 1 layer | 60.0 | 0 | 0.69 | 120.3 | 0.8 | 28 | 14 | 14 |
| 4K60 H.264 → 1080p, 3 layers | 60.0 | 0 | 0.77 | 120.5 | 0.9 | 28 | 13 | 15 |
| 4K60 HEVC → 1080p, 1 layer | 60.0 | 0 | 0.22 | 117.2 | 1.0 | 25 | 13 | 15 |
| 4K60 H.264 → 4K, 1 layer | 58.5 | 9 | 1.11 | 21.8 | 0.8 | 23 | 13 | 14 |
| 4K60 H.264 → 4K, 3 layers | 60.0 | 0 | 1.48 | 121.0 | 0.9 | 26 | 12 | 15 |
| 1080p60 → 1080p, 1 layer | 60.0 | 0 | 0.29 | 121.0 | 1.0 | 27 | 9 | 10 |

*`eng fps`* = frames composited per second of media time. *`ui fps`* = frames Flutter
actually presented (120 Hz display, so 120 is the ceiling, not 60). *`raster p95`* =
Flutter raster thread time per frame.

The one soft row (4K→4K, 1 layer: 58.5 fps / 21.8 ui fps) is measurement noise — the
focus-holding script stole the window mid-window. The same case ran 60.0 / 0 drops in
three other runs.

**Concurrent decoders** — the question behind parallel video tracks:

| streams | worst-stream fps | dropped | cpu% |
|---|---|---|---|
| 1 × 4K60 → 1080p | 60.0 | 0 | 22 |
| 2 × 4K60 → 1080p | 60.0 | 0 | 30 |
| 3 × 4K60 → 1080p | 60.0 | 0 | 33 |
| 4 × 4K60 → 1080p | 60.0 | 0 | 34 |

### Exit criteria

- **Sustained 4K60** — met. 60.0 fps, zero drops, on every configuration including
  4K-out with three composite layers.
- **Scrub < 100 ms** — met with an order of magnitude to spare: p50 9–15 ms, worst
  observed 17 ms (seek → composited frame published).
- **Correct output** — verified, not just timed. `vd_engine_dump_png` writes the
  composited frame; the dumps show correct BT.709 primaries and correctly alpha-blended
  PiP layers (`spikes/out_*.png`).

### What this buys us

- **Headroom is enormous.** GPU composite costs 0.2–1.5 ms against a 16.6 ms budget at
  60 fps. Flutter's raster thread adds ~1 ms. The pipeline is nowhere near saturated —
  effects, transitions, and text in M3 have room.
- **Four simultaneous 4K60 decoders cost ~34% CPU.** The mobile-era assumption that only
  two concurrent decodes are safe does not apply here. 1 main + 3 overlay video tracks
  is comfortable on this class of machine, and proxies are an optimization for weaker
  hardware rather than a prerequisite.
- **HEVC decodes cheaper than H.264** (0.22 vs 0.69 ms GPU, lower CPU) — worth
  preferring for proxies and intermediates.

### Findings that change M1

1. **`textureFrameAvailable:` does not schedule a Flutter frame on macOS + Impeller.**
   Isolated cleanly: window frontmost with no repaint ticker → **0 ui fps** on every case;
   same build with a ticker → 120 fps. The app must pump its own repaints while playing.
   M1 should scope this to a `RepaintBoundary` around the `Texture`, driven by a ticker
   that runs only during playback — not a whole-page rebuild per vsync as the spike does.
2. **Flutter stops rendering entirely when its window is occluded.** Expected macOS
   behavior, but it silently zeroes any display-side measurement — pin the window
   frontmost when benchmarking, and don't trust `ui fps` from a background run.
3. **GPU work must be drained before tearing down the engine.** The spike's first
   `vd_engine_destroy` freed the engine while Metal completion handlers still captured it.
   The use-after-free showed up as progressive degradation across benchmark cases
   (by case 6: 31 fps, 8 drops, a 907 ms seek) rather than a clean crash — worth
   remembering, because that failure signature reads like a performance problem.
   Fixed by committing a fence command buffer and waiting on it before teardown.
4. **`avcodec_receive_frame` latency is not decode time.** It measured ~0.00 ms because
   VideoToolbox decodes asynchronously; the column was removed rather than reported as a
   fake zero. Sustained fps plus zero drops is the honest measure that the decoder keeps up.

### Spike-only shortcuts that must not survive into M1

| Shortcut | Why | Real fix |
|---|---|---|
| Links Homebrew FFmpeg from `/opt/homebrew/opt/ffmpeg` | Fast to set up | Vendor a **universal LGPL** FFmpeg build; Homebrew's is **GPL** (`--enable-gpl`) and arm64-only |
| Release build forced to `arm64` | Homebrew FFmpeg has no x86_64 slice | Falls away once FFmpeg is vendored universal |
| App Sandbox disabled, library validation disabled | Read test clips from an arbitrary path | Re-enable sandbox; use security-scoped bookmarks for user media |
| Shaders compiled from a source string at runtime | Avoids `.metal` build plumbing in the pod | Precompile to a `.metallib` |
| Explicit `-framework FlutterMacOS` in the podspec | Obj-C++ sources don't get Clang module autolinking | Keep it — it is the correct fix, not a hack |
| No audio, single video source per engine | Out of S1 scope | M1/M2 |

---

## S2 — Timeline UI · **GO**

### What was built

`spikes/s2_timeline/` — a pure-Flutter canvas timeline, no engine involved:

- Five tracks: one **magnetic** main video track plus parallel overlay and audio tracks.
- Drag a clip body to move; drag either end to trim. Trim handles appear on selection.
- **Snapping** to every clip edge and the playhead, with an amber guide line; toggleable.
- **Ripple**: the magnetic track repacks end-to-end on commit, so deletes close the gap
  and dragging a clip past a neighbour becomes a reorder.
- Split at playhead, ripple-delete, zoom (⌘-scroll, pinned to the cursor), pan.
- Everything is drawn by **one `CustomPainter`** with offscreen culling — not a widget
  per clip, which is what usually makes editor timelines feel heavy.

Time is integer ticks on a **120000/s timebase**, validated in the model: 120000 divides
exactly by 24, 25, 30, 60 *and* the NTSC rates (23.976 → 5005, 29.97 → 4004, 59.94 → 2002).
That exactness is the reason for the tick rule in PLAN.md, so the spike uses it for real.

### Results — release build, continuous drag repainting every vsync

| timeline | fps | build p95 | raster p95 | raster max | drag events |
|---|---|---|---|---|---|
| 20 clips | 121.0 | 0.78 | 1.65 | 9.70 | 481 |
| 98 clips | 120.8 | 0.79 | 1.60 | 4.29 | 480 |
| 500 clips | 121.0 | 1.19 | 1.98 | 2.19 | 481 |
| 1002 clips | 121.0 | 1.10 | 2.02 | 3.64 | 480 |

All four cases were zoomed out so **every clip was on screen** — culling gave no relief.

### Exit criteria

- **60 fps with 100 clips** — exceeded by a wide margin: 121 fps (the 120 Hz display
  ceiling) with **1002 clips**, at ~2 ms raster per frame.
- **Cost is flat in clip count.** 20 clips and 1002 clips cost the same per frame; the
  work is dominated by the drag repaint, not the number of clips. Timeline scale is a
  non-issue for realistic projects.
- **Correct rendering** — verified by rendering the painter straight to a PNG
  (`spikes/s2_timeline_render.png`), which needs no screen-capture permission.
- **"Feels good in the hand"** — still open. That judgement is the owner's, and the
  interactive app exists to make it: `spikes/s2_timeline` (see `spikes/README.md`).

### Findings that change M1

1. **The `CustomPainter` approach is validated** — keep it. Widget-per-clip would have
   been the obvious Flutter idiom and would have cost far more.
2. **Cache text layouts, but bound the cache.** Clip labels include a live duration that
   changes every frame while trimming, so an unbounded `TextPainter` cache grows without
   limit during a drag. The spike caps it; M1 should key static and dynamic label parts
   separately.
3. **Label clipping is rough on narrow clips** — text is cut mid-word. Cosmetic, but it
   is exactly the kind of detail the "easy to use" positioning is judged on. M2 polish.
4. **Repack-on-commit is the right magnetic model.** Letting the dragged clip move freely
   during the gesture and repacking on release gives reorder semantics for free, with no
   special-case insertion logic.

---

## M0 verdict — **GO on the PLAN.md stack**

Both bets cleared with room to spare on this machine:

- The **preview architecture works end to end** and is nowhere near saturated — 4K60 with
  three composite layers costs ~1.5 ms of GPU against a 16.6 ms budget, and four
  simultaneous 4K60 decoders cost ~34% CPU.
- The **timeline is not a performance problem** at any realistic scale.
- The riskiest assumption in PLAN.md — Flutter external-texture throughput at 4K60 — is
  **retired**. The Flutter raster thread adds ~1 ms per frame.

Two caveats that belong on the record:

1. **These are M3 Pro numbers.** They set a ceiling, not a floor. PLAN.md's performance
   claims need a low-end reference machine (an Intel Mac or base M1 Air) before they can
   be stated as product guarantees, and Windows/NVENC is entirely unmeasured.
2. **Nothing here is shippable code.** The spikes take deliberate shortcuts (GPL FFmpeg
   from Homebrew, sandbox disabled, arm64-only, no audio, no document model). M1 starts
   the real tree; the tables above are what M1 is expected to preserve, not code to build on.
