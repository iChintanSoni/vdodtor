# vdodtor — Implementation Plan

**This file is the source of truth for progress.** Product decisions live in
[docs/product-brief.md](docs/product-brief.md); this file tracks *how* the product gets
built and *how far* along it is. Update it in the same commit as the work it describes.

**Conventions**
- `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked (append a note)
- A milestone is complete only when all its **exit criteria** pass — checkboxes alone don't count.
- Keep the status line below current whenever a milestone starts or finishes.

> **Status: M1's build items are all done and its exit criteria need one run by hand.
> M2's build items are all done too, and its exit criteria are one edit by hand:
> the timeline cuts, the compositor is pinned by golden frames, the audio lanes make a
> sound, the clips on them show what that sound looks like, a volume line on a clip can
> duck it, a clip is drawn the shape and the way up its own file asks for, and the
> keyboard reaches all of it.**
>
> **M4 has started, and its Export section is complete: the editor writes MP4s, and
> the file agrees with the preview on pixels.** ⌘E, four sizes, H.264 or HEVC, a bar
> that moves, and a Stop that leaves nothing behind — and one timeline rendered through
> both clocks against one committed picture each, so "preview and export differ in the
> clock and in nothing else" is a test rather than a sentence. **The resolution gate is
> in too**: above 1080p needs Pro, the sheet says so in the one place in the app that
> says no, and the tier changes what may be written and never what is written. **And
> licensing is in**: a licence key is a signed sentence, checked on this machine with no
> network, no account and nothing to sign into, so the whole purchase flow works on a
> plane. **And content packs are in**: a `.vdpack` is a signed bundle of looks and faces,
> the Cinema pack ships inside the app, and a locked item changes what may be *chosen*
> and never what is *drawn*. **And the editor now comes out as a disk image**:
> `tools/package_mac.sh` builds it, checks that what got embedded is what the licence
> notice says got embedded, signs it inside out under the hardened runtime, and stamps
> out a DMG with the app, an `/Applications` symlink and the licences beside them —
> everything but the two calls to Apple, which need a Developer ID this machine has not
> got. Doing it turned up that `flutter build macos --release` had **never** succeeded:
> `lipo` was producing universal FFmpeg dylibs with an unsigned x86_64 half, which
> `codesign` refuses and every debug run was blind to. And it closes the LGPL: the
> notice is generated from the files actually vendored — version, checksum, configure
> line, the written source offer, how to build a replacement and drop it in — and shows
> on the chooser's About sheet, because a disk image is a thing people throw away the
> day they mount it. **And the update question is settled**: there is no updater, on
> purpose — vdodtor has no network entitlement, so it cannot open a socket at all, and
> "Check for updates…" opens the download page in the browser. A promise anybody can
> verify with `codesign -d --entitlements` is worth more than telling people about a
> point release. **And crash reporting is settled the same way**: a Dart fault is
> written to a file on the user's own disk with every absolute path scrubbed out of it,
> the chooser offers it at the next launch, and it reaches us only if somebody reads it
> and pastes it — which is what opt-in means for an app that cannot open a socket, and
> the end of the analytics question too: none, not even a count. Its first catch in the
> running app was itself. What is left in M4 is the signing key and two calls to Apple.
>
> **And M6 has opened with the brief's first fast-follow feature: green
> screens.** A clip carries a colour to remove, the compositor turns everything
> near it into transparency, and the lane underneath shows through — in the
> preview and in the exported file, compared by a parity golden rather than by
> eye. The arithmetic is `vd_key.c` on `vd_color.c`'s terms, and it keys on
> chroma **divided by brightness**: Cb and Cr are differences and shrink with
> the picture, so the usual answer only works on a perfectly lit screen, and
> the fixture's own gradient caught that before anything else did. Two things
> that are about *looking* rather than about the edit came with it — an
> eyedropper that renders one frame with every grade, look and key suppressed,
> and a matte view — and both live on the engine beside the clock and the
> position rather than in the render list, so no project file can record one
> and `vd_export` never sees them.
>
> **And M5 has started: the app has its own name and its own face, and the
> first window is no longer an empty one.** OQ-4's name half is settled —
> vdodtor ships — and the icon is no longer the one `flutter create` wrote:
> it is the app's own timeline, three clip bars cut under the playhead, drawn
> from the numbers in `tools/make_icon.dart` rather than exported from a design
> tool, in three levels of detail so that 16 px is a drawing rather than a
> scaled-down one. `app/test/app/icon_test.dart` draws it again and compares,
> which is the licence notice's rule pointed at a picture. **And the site is in
> the repository** — `site/`, six plain static pages, there because the app
> hard-codes six `vdodtor.app` addresses into a build that can never update
> itself, so a renamed page is a dead buy button in every copy ever installed.
> `site_test.dart` reads `lib/` for every one of those addresses and fails if
> the site has no page for it. **And it is now published rather than merely
> written**: `.github/workflows/site.yml` puts `site/` on GitHub Pages on every
> push that touches it, from a GitHub-hosted runner rather than the self-hosted
> Mac, because a buy button that stays dead until somebody registers a CI runner
> is the wrong dependency. `site/CNAME` is where the domain is written down for
> the host, and `site_test.dart` makes it the same domain the app opens — the
> app-and-site boundary applied to the address itself, since publishing under
> the wrong name breaks every button in every copy installed exactly as renaming
> a page would. OQ-4 is closed; what is left is a domain and a DNS record,
> which are not code. And the
> chooser offers a sample project beside New Project — a fifteen-second edit,
> cut from three gradient shots this repository generates rather than licenses,
> with a title, a rule, a strapline, a dissolve, a wipe, a look on the middle
> shot and a chord bed faded under the lot — and the first editor window this
> machine ever opens runs a six-stop tour over the real panels. The sample is
> **code rather than a shipped `.vdo`**, so it is exactly as current as the
> document model is, and its footage is **copied into the library** rather than
> referred to inside the bundle, because a bundle resource is readable and
> cannot be bookmarked. Measured in the running app: 30.0 fps, 1.7 ms GPU, no
> underruns, zero text rasters and zero LUT uploads across three seconds of
> playback, and the whole thing exports at 6.0x realtime with the preview still
> alive.
>
> **M3's build items are all done, and its exit criteria are one edit by hand: the editor
> can put words on the picture, draw shapes beside them, drop animated stickers over them,
> make them all arrive, join one shot to the next, grade the colour of any of them, put a
> look on top, play any of it faster or slower, and shape the sound of it.** A caption is a clip with no
> file — the first thing on the timeline that is drawn rather than decoded — laid out by
> Core Text in the engine and composited as an ordinary layer, so preview and export can
> never disagree about it. Five bundled OFL faces, fill, outline, shadow, background box,
> letter and line spacing and alignment, all measured in fractions so a project cut at
> 1080p exports the same at 4K. ⌘T at the playhead. Measured in the running app: the
> caption composites over the picture in the same frame as the clip under it, and eight
> seeks across it lay it out **zero** further times — the raster is kept until the caption
> itself changes, so scrubbing costs nothing and retyping costs one layout.
>
> Clips now **arrive and leave**: nine in/out presets — fade, four slides, pop, zoom, spin
> and a typewriter — evaluated in the engine as a pure function of how far through the
> entrance the playhead is, and folded into the transform the clip already had. Every
> preset but the typewriter is the same pixels moved about, so an animated caption is laid
> out **once** however much it moves; the typewriter redraws once per *character*, never
> once per frame, because the caption cache is keyed on how much of it has been typed.
>
> Cuts can now be **joins**: dissolve, slide, push, wipe and a dip to black or white,
> adjustable, on any cut on any lane. The decision worth knowing is that the overlap a
> transition needs is made by the *engine*, not the document — clips stay butt-joined and
> non-overlapping, nothing on the timeline moves, and "never fails for lack of media" falls
> out of the decoder's existing clamp past the end of a source. Five of the six presets
> were things the compositor could already do; the wipe needed a hard reveal edge, and
> adding it turned up a blur-fill bug that had been making every wipe in the real app erase
> the clip it was wiping away from.
>
> **Stickers** are the third kind of layer and the first that comes out of a file the
> engine does not decode like video: a GIF, an animated WebP or an APNG is decoded whole
> at open and then costs nothing per frame, because it has no keyframes to seek to, its
> alpha is the point of it, and it is small enough to hold. Retiming to the project's rate
> falls out of asking by *time* rather than by frame number — nothing in `vd_sticker`
> knows what rate the project runs at. It loops, so like a still image nothing bounds how
> long it may be, and it lands on an overlay lane rather than in the magnetic main one.
> Measured in the running app: opened once, and **thirty renders across one loop cost four
> frame changes**.
>
> Shots can now be **graded**: brightness, contrast, saturation, temperature and
> tint, per clip, on the GPU. All five are affine, so they compose into one 3x3
> matrix and an offset on the CPU and cost the shader a single multiply-add —
> which puts the whole of what a grade *means* in plain C that is tested against
> numbers rather than pixels, and leaves Metal holding a matrix multiply. Every
> slider is −1..1 with 0 neutral, so a zeroed struct is the ungraded shot and an
> ungraded fragment takes the path it took before the feature existed, bit for
> bit. Brightness is a gain rather than a lift so black stays black, and the
> white balance is normalised against BT.709 luma so warming a shot does not
> also brighten it. Measured in the running app: eleven grades, layers and
> decoders both flat, and a fully desaturated shot reads 151 where the luma of
> its own colour is 151.1 — with the sticker on the lane above it untouched.
>
> And on top of the sliders, a **look**: a `.cube` LUT, five of them bundled and any
> other loadable from a file. This is the grade that *cannot* be a matrix — a split-tone
> pushes the shadows one way and the highlights the other, which no 3x3 can express — so
> it arrives as a lattice and is sampled on the GPU as a 3D texture. It runs in the
> signal rather than in linear light, because that is what the `.cube` files anybody will
> actually load were authored against; and it runs *after* the five sliders, because that
> is the order a colourist works in and the order a look expects its input to have been
> corrected in. The picker sits under the sliders for the same reason. Measured in the
> running app at 1920x1080: five looks at two strengths each, layers flat at 2 and
> decoders flat at 5, and **five cube uploads for eleven grade changes** — one per look,
> nothing for the strength drag. Noir comes back **100% grey**, and half strength lands
> exactly halfway between the ungraded shot and the full look on every channel.
>
> And it can now draw **shapes**: a rectangle, an ellipse, a line and an arrow, with a
> fill, a stroke, a corner and a shadow — ⌘R at the playhead, on the lanes the captions
> already use. This is the change that shows what "a caption is a source, not a
> compositing mode" was worth: a shape inherited the compositor, the transform, the
> z-order, the animation presets and the raster cache unchanged, and cost one field on the
> render list plus 230 lines of Core Graphics. Every length is a fraction of the output
> **height** — both of them, so a circle is round in a 16:9 project and in a 9:16 one.
> Measured in the running app: three layers, one draw per shape, and **zero** further
> draws across eight seeks.
>
> A clip's sound now has a **shape and a character**: four fade curves — linear,
> smooth, equal power and exponential — and five EQ presets, from a voice correction
> to a telephone. The two land on opposite sides of one rule. A fade is *drawn* on the
> timeline, so its shape is written twice and the table that pins it grew a column per
> curve; an EQ is not drawn by anything, so the document carries only the preset's name
> and `vd_eq.c` owns what it means — the arrangement a look already has. Presets rather
> than a parametric equaliser, because nine numbers is a panel nobody can read and a way
> to make a recording worse with great precision. Measured in the running app: four
> envelopes that all start at 0 and reach 1 differently, and three seconds of playback
> through a three-section biquad cascade with **0 underruns and 0 late frames**.
>
> And any clip can now be **retimed**, 0.1x to 10x. A speed is a *rate*, not a length:
> `Clip.duration` stays the clip's length on the timeline, so nothing about packing,
> hit testing or splitting changes, and the source window it implies is derived — which
> is what makes 4x and back to 1x the clip you started with. Frame duplication for slow
> motion turned out not to be a feature at all: a frame is on screen until the next frame
> starts, so a source time that has not left the current interval comes back out of the
> decoder's cache, and four project frames at a quarter speed are byte-identical PNGs.
> The whole cost of the feature is the sound, which cannot be sampled at an instant —
> `vd_stretch.c` is a WSOLA time-stretch that keeps the pitch and a box-filtered
> resample for the clips that should sound like a tape, with a per-clip toggle because
> both are right and no engine can tell which one this is. Measured in the running app:
> a half-speed clip played for three seconds with **0 underruns and 0 late frames**, the
> source window flat at 2.00s across every rate, and decoders flat at 5.
>
> And it can now **export**. The whole feature is one sentence: preview and export differ
> in the clock and in nothing else. Playback works out what time it is and renders that;
> an export counts frames and asks for those, through the same two functions — the same
> clip list, the same decoders, the same compositor, the same envelopes and filters, with
> a position handed in instead of read off a clock. That is what "one compositor" was
> buying since M0, and `vd_export` spending 500 lines on AVFoundation and none on drawing
> anything is where it got spent. The output size is the *timeline's*, so a 4K export of a
> 1080p edit is one number changing and no re-layout of anything — which is what every
> caption measured in fractions was for. MP4 with the index at the front, HEVC tagged
> `hvc1` rather than `hev1`, AAC-LC at 48 kHz, and a cancelled export that leaves no file,
> because half a video plays and looks finished and is missing the ending nobody checks.
> Measured in the running app, on the self-test project with a caption, a shape, a sticker
> and a transition on it: **257 frames of 1920x1080 in 2.55s — 3.4x real time in a debug
> build** — and the preview still rendering afterwards, which is the part no offline test
> can reach.
>
> Done: real repo tree, vendored universal **LGPL** FFmpeg 9.0.1, CMake engine wired into the
> Flutter build, the whole **document model** (rational time, scene graph, undo, autosave,
> crash recovery, import — 416 Dart tests), and the **media probe** through the full
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
> **M2 is under way.** Clips move, trim, split, duplicate and delete on the timeline, each
> drag a single undo entry, each edge stopping where it should — at a frame of length, at
> the end of the source, at the neighbour. Snapping lands edges on cuts and on the playhead.
> A selection is a *set*: ⌘-click to add, ⌘A for everything, and cut, copy and paste move
> clips around with their source windows and their spacing intact. Overlay lanes take clips
> dragged onto them, and every clip carries a transform — offset, scale, rotation, crop,
> opacity, flip — so a picture-in-picture is a thing the editor can now make. A clip whose
> shape does not match the project gets **blur fill** by default rather than black bars.
> Sound works: six audio lanes that actually reach the mixer, per-clip volume, mute and
> fades, and ⌘⇧D to lift a clip's audio onto a lane of its own. A music bed on an audio
> lane was silent until this — the render list was built from visual tracks only — which
> is the half of M2's exit criteria that was missing. A source's own metadata is believed
> now too: a clip shot upright plays upright, non-square pixels are the shape the file
> asks for rather than the shape it is stored in, and a variable-rate source shows the
> frame it says is on screen instead of one from half a second later. And the keyboard
> reaches all of it — 26 shortcuts from one table, with ⌘/ to see them, ⌥← and ⌥→ to
> step cut to cut, and zoom anchored on the playhead rather than on the left edge.
>
> **Owner checks outstanding**, both needing hands rather than a script: dropping files on
> the window (everything around the drop is verified — panel, bookmarks, relink, and that
> the transparent drop view does not eat mouse input), and whether the timeline feels good
> to scrub, which is the S2 question that was never a performance question.
>
> M0 (complete) measured on Apple M3 Pro: 4K60 preview at 60 fps with 3 composite layers
> (~1.5 ms GPU), 4 concurrent 4K60 decoders at ~34% CPU, scrub p50 13 ms, timeline at
> 121 fps with 1002 clips. Findings: [docs/spike-notes.md](docs/spike-notes.md).

## What is left

**Every remaining item needs something only the owner can supply** — a
certificate, a key, a token, a domain, or a judgment. The code is not the
blocker on any of them, which is why they are listed here together rather than
found one at a time. Roughly in the order they unblock each other:

| # | Step | Needs | Where |
|---|---|---|---|
| 1 | Publish `site/` at `vdodtor.app` | The domain, and a DNS record pointing it at GitHub Pages. The host and the deploy are in: `.github/workflows/site.yml`. | M5 |
| 2 | Replace the development licence signing key | A `keygen` run, and somewhere that is not this repository to keep the private half. Re-sign the shipped packs in the same change. | Packaging |
| 3 | Developer ID certificate + `notarytool` profile | An Apple Developer account. | Packaging |
| 4 | Run `tools/package_mac.sh` for real | 2 and 3. Everything else in it has been run. | Packaging |
| 5 | Cut the first release | 4, then a GitHub release tagged `v<version>` carrying the DMG, so `/download`'s button resolves. | M5 |
| 6 | Wire a checkout behind `/pro` | OQ-2 (pricing) and a merchant account; then `/pro` becomes a redirect and the webhook mints keys. | M5 |
| 7 | Register the CI runner | A GitHub runner registration token. `tools/setup_ci_runner.sh` does the rest. **The workflow has never run**, so expect to fix it once. | M1 |
| 8 | The two owner checks | Hands: drop files on the window, and scrub the timeline to decide whether it feels good. | M0 / M2 |
| 9 | Private beta, then launch | 1–6. | M5 |

Nothing above is waiting on a decision that has been deferred; the deferrals
that remain are recorded where they belong — parameterised transitions before a
pack can carry one, "new from template" before it can carry that.

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
      the ruler now does, and two controls for one value is one of them always wrong.
      **Navigating it was then found broken by driving the real app**, in three ways one
      after another, none of which any existing test could see. macOS does not report a
      trackpad as a wheel: a two-finger swipe carries an `NSEvent` phase, so the embedder
      sends `PointerPanZoom*` and a `Listener` handling only `onPointerSignal` hears
      nothing — the timeline could be panned with a mouse and not with the trackpad of the
      machine it was written on, and the test that covered it synthesised the one device
      that worked. Then the embedder **drops the inertia events** after the fingers lift,
      on the grounds that the framework generates momentum, which `Scrollable` does and a
      bare `Listener` does not: it stopped dead where every other window on the machine
      coasts. And scrolling was **unbounded**, so the film could be taken off the left
      edge into empty space with every gesture that would bring it back looking like the
      one that had not worked. It now pans with momentum on a friction simulation, locks
      the axis once per gesture rather than picking the larger one per event, stops with
      the last frame against the right edge, and **carries a scrollbar** — which is what
      says the project continues past the window at all. A vertical swipe deliberately
      does nothing: time runs across, and the wheel maps its one axis onto that only
      because it has no other to offer
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

- [x] Trim in/out, split at playhead, move, delete-with-ripple (magnetic main track), duplicate
      — `TrimClip`, `SplitClip` and `DuplicateClip` join the move and ripple-delete the
      model already had. A trim is not a resize: the head edge takes `sourceIn` with it, so
      the frames stay where they are and fewer of them show. Every edge **clamps rather
      than refuses** — a drag that stops at the limit is right where one that snaps back is
      not — and the limits are one frame of length, the source's own extent, and, on a
      free-form lane, the neighbours. A split snaps its cut to a frame before making it,
      because a cut between two frames is a cut at neither and every length downstream
      inherits the rounding.
      Dragging a clip body moves it, dragging within 9 px of an edge trims it, and a clip
      too narrow to hold handles is all body — an edit you cannot start is worse than one
      you have to zoom in for. Edges snap to any cut on any lane and to the playhead, and a
      moved clip snaps by whichever of *its own* edges lands closer.
      **`DocumentStore.run(fromGestureStart:)`** came out of this, and is the part worth
      remembering: a drag is one edit that keeps changing its mind, not a run of edits that
      accumulate, so each move re-applies to the document as it stood when the gesture
      began. Without it a magnetic lane is a trap — committing a move repacks the
      *neighbours*, so the next move compares the clip against positions the drag itself
      created, and dragging back the way you came does not undo the reorder.
      Split, duplicate and delete are on ⌘B, ⌘D and Delete for now; the full shortcut pass
      is still its own item below.
      Driven on screen, not only in tests: dragging a trim handle took a clip from
      `00:02:00` to `00:01:15` — the half-second asked for, to the frame — and the lane
      rippled closed behind it; one ⌘Z put it back whole; ⌘B cut at the playhead and left
      the total length untouched; and dragging a clip past two neighbours reordered the
      lane. The saved file then shows what matters most about a split: the tail's
      `sourceIn` is exactly where the head's window ended, and the lane is still packed
      end to end at the same total duration
- [x] Multi-select, copy/paste
      — the selection became a set, and everything that acts on it takes the whole set in
      one edit: deleting four clips is one undo entry, not four presses to reverse one
      decision. ⌘-click and ⇧-click toggle membership and deliberately start **no drag**,
      because choosing what to act on and moving it are different intentions and one should
      not smuggle in the other. A plain press on a clip narrows the selection to it, since
      a drag moves one clip and leaving four outlined would say otherwise. Trim handles
      appear only when the selection is exactly one clip — trimming is a single-clip idea.
      Undo can take a clip out from under a selection, so the selection prunes itself
      against the document rather than keeping ids that name nothing.
      The clipboard is rebased on **copy**, not on paste: the shape of a multi-clip copy —
      the gaps, the lane each came from — is fixed at the moment it is taken and cannot be
      changed by editing afterwards. Paste lands the earliest clip on the playhead, puts
      each clip back on the lane it came from (or the first of the same kind), and on a
      magnetic lane inserts *after* the clip the playhead is over. It skips anything whose
      media the project no longer has, because a paste that plays black is worse than no
      paste. Cut is a copy and a delete, so it undoes like the delete it is.
      **`InsertClips`** replaced `DuplicateClip`: one incurious command behind both paste
      and duplicate, taking clips that are already decided along with the lane and the slot
      each goes in. That is what keeps paste-at-the-playhead and duplicate-in-place from
      drifting apart, and `DeleteClips` is its opposite number.
      Not included, and worth saying: dragging does not move a whole selection. Group drag
      on a magnetic lane is a different problem — non-contiguous clips reflowing around each
      other — and belongs with a bullet of its own rather than smuggled into this one
- [x] Parallel overlay video tracks (up to 3) with per-clip transform:
      position, scale, rotation, crop, opacity, flip
      — **the lanes are in; the per-clip transform is not.** A project may hold three
      overlay lanes, capped in the model rather than in the UI, and a new one is inserted
      *above* the visual lanes already there. That placement is not cosmetic: list order in
      the document is compositing order, so where a lane is inserted decides what it renders
      on top of.
      The timeline shows lanes in the reverse of that order, because an editor shows what is
      on top at the top. Those two orders being opposites is the thing most likely to be got
      quietly wrong, so the tests are mostly about which is which.
      `MoveClip` gained a destination lane — one command for both axes, because a drag moves
      in both at once and two commands would make one gesture two undo entries. A lane
      refuses clips it cannot play: sound goes on audio lanes, pictures on visual ones, and
      a video clip dragged over the audio lane slides along its own instead of landing
      somewhere it would be silent. Removing a lane takes its clips with it, one undo away,
      and the main track cannot go at all.
      Confirmed on screen: an overlay lane appears above Video with Audio below it, a clip
      dragged up lands on the overlay while the magnetic lane ripples closed behind it, and
      the engine then reports **`layers 2`** with the overlay composited over the main track
      in the preview. Nothing was needed in the engine — `timeline_sync` already used
      document order as z-order, and this is the first time anything exercised it.
      **The per-clip transform is now in too.** `ClipTransform` on every clip — offset,
      scale, rotation, crop insets, opacity, flip — and every field of it is *relative*:
      offsets are fractions of the output, scale multiplies whatever the fit produced, crop
      is a fraction of the source. A project cut at 1080p and exported at 4K has to look the
      same, and it only can if nothing in there is measured in pixels.
      In the engine, `VdTransform` is defined so that **a zeroed struct is the identity** —
      a caller that does not care can `memset` its layers and never learn the field exists,
      which is worth the two lines it costs to read a zero scale as one. Order is crop, fit,
      scale, rotation, offset: crop first because cropping changes the aspect ratio and a
      fit computed before it would letterbox the part being thrown away. Rotation is the
      only part the vertex shader has to do, and it happens in a square space and comes back
      out again — rotating in normalised space, where x and y measure different distances,
      turns a square clip into a rhombus on any output that is not square.
      Eight new pixel tests cover it, including that one.
      The inspector shows it for a single selection only: averaging four clips' rotations
      into one slider is a lie that is hard to notice and harder to undo. A slider drag is
      one undo entry, and a run across *different* properties still folds into one, because
      that is one decision to the person making it.
      Verified headlessly rather than by hand: a project with an overlay clip at 35% scale
      offset into the corner renders as a **picture-in-picture** over the main track — which
      is the shape this milestone's exit criteria asks for
- [x] GPU compositor: multi-layer render graph, alpha blend, fit modes
      (blur-fill default / fit / fill / stretch)
      — the multi-layer pass and premultiplied alpha have been there since M1; what this
      bullet was really missing was **blur fill**, and it is the default because black bars
      make a clip look like a mistake where a blurred backdrop makes it look deliberate.
      It is the first thing here that needs more than one pass: the clip is drawn
      cover-fitted into a small offscreen texture, blurred across and then down — separable,
      because two cheap passes beat one dear one — and drawn under the contained picture.
      The blur runs at an eighth of the output: a background about to become a wash does not
      need four million pixels, and every one of them costs a tap in each direction.
      Two things keep it honest. A clip that already reaches every edge takes the ordinary
      path, so the common case — a 16:9 clip in a 16:9 project — pays one comparison and
      nothing else. And the backdrop ignores the clip's own scale and offset, because moving
      a clip should not drag its backdrop around with it.
      Five pixel tests: something in the bars, contain still leaving them black (the
      contrast that makes the first one mean anything), the picture inside the frame
      unchanged to the pixel, no extra work when there are no bars, and the background
      actually being *blurred* — measured as the biggest step between neighbouring samples,
      which a sharp test pattern would fail by a mile.
      Confirmed on a real render: a portrait clip in a 16:9 project comes out with its
      pillars filled
- [x] Golden-frame tests for the compositor in CI (fixed scenes, fixed timestamps, strict tolerance)
      — five whole frames, committed as PNGs and compared pixel for pixel on every run.
      The compositor already had twenty-six tests, and they all sample *points*: the centre
      of the picture, a spot in the bar, the corner that should be orange. That catches the
      failures someone thought of in advance and cannot catch the ones nobody sampled. The
      goldens were checked against exactly that: changing the blur's downsample from an
      eighth to a sixth leaves **all twenty-six point tests green** and turns the golden
      suite red, on the one scene affected, naming the worst pixel.
      The scenes are chosen to cover what a point cannot — a full-colour pattern contained
      with its pillars, the same frame blur-filled (only a whole frame can say it is the
      *same* blur rather than merely a blurry one), picture-in-picture, crop and scale and
      rotation and flip stacked so the *order* is pinned, and three layers where the top one
      blends over a translucent middle rather than over the background. Every one decodes at
      a **fixed tick** rather than taking whatever frame arrives first: the fixture animates,
      and a golden of "some frame" is a golden of nothing. The frame counter burnt into the
      reference reads 10, which is how you can see that it worked.
      The tolerance is two numbers, not one. Four counts on any single channel, because
      texture filtering and a floating-point blur are not promised the same last bit on two
      GPU generations — and far below the 25 counts a wrong YCbCr matrix moves green by. Then
      a mean of one count across the frame, because the per-pixel bound has a blind spot: a
      change that darkens *every* pixel by three passes it while being obviously wrong.
      Two things make the suite trustworthy rather than merely green. A **missing** reference
      fails — a golden suite with nothing to compare against reports coverage it does not
      have. And the harness checks itself first: it renders something asymmetric in both
      axes, writes it, reads it back and demands an *exact* match, because if the PNG pair
      flipped the picture or swapped red for blue then every golden below would be written
      wrong, read wrong, compared equal, and the whole suite would test nothing.
      `VD_UPDATE_GOLDENS=1` rewrites the references and says loudly that the run proved
      nothing; approving one means reading the diff of the picture. On a red CI the actual
      frame and an amplified difference come back as an artifact, so the first question —
      what changed, and where — is answered without reproducing anything
- [x] Audio: 6 tracks; per-clip volume, mute, fade in/out; detach audio from video
      — the six lanes were already in the model, and finding that out was the least
      interesting thing here. **Nothing on them made a sound.** The render list was built
      from visual tracks only and then handed to both the compositor and the mixer, so a
      music bed on an audio lane was dropped before it reached either — the one shape this
      milestone exits on, silent, with no test anywhere that would have said so.
      What fixes it is a rule rather than a special case: **the lane decides which half of a
      file a clip contributes.** A clip on an audio lane is sound even when its file has a
      picture, which is exactly what a detached clip is, and the picture must not come back
      with it. `VdTimelineClip` grew `has_video` so the compositor can skip a music file
      instead of opening a decoder to discover there is nothing in it, and the document says
      so rather than the engine probing — a music bed should not cost a file open on every
      edit to establish what the document already knows.
      `ClipAudio` on every clip: volume, fade in, fade out, mute. Volume is a linear
      multiplier and *not* decibels, because 0 is a legitimate volume and has no logarithm —
      a dB document would need a magic value for silence. The fader shows dB, since the ear
      is logarithmic and a fader marked 0.50 tells nobody anything; the conversion lives at
      the fader. Mute is its own flag rather than `volume = 0`, because unmuting has to give
      the level back, and the inspector test that matters is the one asserting the fader
      does **not** move when you mute.
      The fade envelope is computed in two languages and tested against **one table** —
      `vd_audio_fade_gain` in C and `ClipAudio.fadeShapeAt` in Dart, the same ten rows
      asserted in both files, the way `vd_time` and `time.dart` already do it. A fade the
      timeline draws and a fade the speakers play being the same shape is not something to
      leave to two people reading the same prose. The mixer evaluates it **per audio frame**,
      not per chunk: a chunk is 1024 frames, and a fade that stepped once a chunk would be a
      staircase of about fifty steps — not a fade but a series of small clicks.
      Two things fell out that are worth keeping. A muted clip is **not decoded** — reading
      it and multiplying by zero sounds identical and costs a seek and a decode per chunk,
      and mute is a state a clip sits in for a long time. And a muted clip is still *sent*,
      because it is still part of how long the project is; dropping it would make playback
      stop short of the end the moment someone muted the last clip.
      Detach is one edit that does two things — the sound appears on a lane and the clip it
      came from goes quiet — because apart, the middle state plays everything twice and undo
      takes two presses to come back from something that felt like one press. It makes the
      lanes it needs, so detaching four clips that overlap is still a single undo entry
      rather than an `AddTrack` to press ⌘Z through on the way out. The video clip is muted
      rather than stripped, since there is nothing to strip: a clip is a window onto a file
      and the file still has the sound in it, which is also what makes the edit reversible
      by hand.
      That forced the one rule that had to bend. An audio lane used to accept only files
      with *no* picture, which would have stranded every detached clip on the lane it landed
      on, one of six. It now takes anything that makes a sound — but only from another audio
      lane or from a file with no picture, so dragging a video clip down onto an audio lane
      still refuses rather than throwing its picture away without saying so.
      Adding `gain` and `has_video` to the struct made a zeroed `VdTimelineClip` mean
      "silent and invisible", which is a bug that looks like nothing happening at all — so
      `vd_timeline_clip_default()` exists to say the boring thing out loud. The engine tests
      that memset caught it immediately and loudly, which is how it should be found.
      44 new Dart tests and 5 new engine ones, including the one that would have caught the
      original hole: a clip with no picture, through the whole engine, still makes a sound
      and still costs exactly one composited layer
- [x] Waveforms rendered from multi-resolution peak files at every zoom level
      — a waveform is not one array. At 1200 px/s a pixel is under a millisecond of
      audio and at 2 px/s it is half a second, so drawing a half-hour interview from the
      finest data would scan five million values to paint a thousand pixels, on every
      repaint, on every lane. What is stored instead is a **pyramid**: level 0 holds a
      minimum and a maximum per 128 audio frames — 2.7 ms, finer than a pixel at the
      deepest zoom the timeline offers — and each level above folds pairs of the one
      below. Whatever the zoom, the reader picks the level whose bucket is closest to a
      pixel and reads two or three buckets for each one, so drawing costs the same at
      every zoom rather than the same per second of audio.
      **The fold keeps the extremes, never an average**, and that is the whole reason it
      works. An average of averages smooths a drum hit away until zooming out turns it
      into a flat line — which reads as a calmer recording, not as a bug. A minimum of
      minima keeps it, because the coarse bucket still spans the sample that made it. The
      test that pins it takes one loud bucket in four thousand and asserts it is exactly
      as tall at 2 px/s as at 1200; the engine side asserts the same thing structurally,
      that every coarse bucket is the extremes of the two beneath it, on every bucket of
      every level rather than on a sample.
      A pixel **folds every bucket it touches** rather than sampling one. Point-sampling
      is the obvious implementation and it makes transients flicker in and out as the
      view scrolls, because whether a peak shows then depends on where the pixel grid
      happens to land.
      Peaks are signed and kept at both ends: a rectified envelope mirrored about its
      centre looks tidier and is a picture of a file nobody has. They are taken **across
      the channels, not over a downmix** — summing lets two out-of-phase channels cancel
      into a flat line for audio that is plainly audible, and averaging draws a
      hard-panned track at half its height. `audio_steps.m4a` exists to catch exactly
      that: three seconds of silence, then a quarter on both channels, then nine tenths
      on the *left alone*, so the last second reads 0.90 or the rule was not followed.
      Where the split falls is the part worth remembering. **The engine analyses into
      memory and the app owns the file.** `vd_peaks_analyze` opens the same
      `VdAudioSource` the mixer uses — so the waveform on screen is the sound that will
      come out of the speakers rather than a second opinion about the file — and hands
      back a pyramid. Everything about *keeping* it is Dart's: the format, the directory,
      the staleness rule, the sweep. The engine has no idea where this machine puts its
      caches and should not learn, and the format ends up with **one parser** rather than
      the two that a C writer and a Dart reader would have needed to keep in step.
      What is cached is a property of the **file**, never of the clip. Volume, fades and
      mute scale the drawn envelope at paint time, which is what makes a fader instant —
      pulling one repaints, where anything baked per clip would have to be rebuilt — and
      what lets one analysis serve every clip cut from the same file. A muted clip
      therefore draws as a flat line rather than as nothing, because a lane that went
      blank where a clip was muted would read as missing media.
      A peak file is stamped with the length and modification time of the media it came
      from, and a mismatch deletes it rather than drawing a waveform of a file that has
      been re-exported underneath. A version number at the front means a format change
      throws every old file away unread, which is the whole migration story a cache
      needs. The bytes are in **host order on purpose**: these sit beside the machine
      that wrote them and are never shared, and reading a few million samples one at a
      time to be portable about it would cost more than the analysis the cache exists to
      skip. Anything unreadable — a truncated write, a foreign file — costs one
      re-analysis and nothing else.
      On screen it is one vertical line per pixel column, drawn in a single call. An
      audio lane gives its whole clip to the waveform; a picture lane gives it a strip
      along the bottom, because what identifies a video clip is its name and its sound is
      the thing you look for underneath. Only the visible part of a clip is drawn, so a
      ten-minute clip scrolled mostly off screen costs what its sliver costs. Silence is
      a line through the middle rather than a gap.
      27 new Dart tests and a new engine suite, including the two that would have caught
      the ways this goes quietly wrong: the spike that has to survive every zoom, and a
      pixel-level check that a quarter-volume clip is drawn less than half as tall as a
      full one. Those are pixel tests in the literal sense — the timeline is painted onto
      a canvas and the assertions read rows of it, because *where* ink lands inside a
      clip is the whole question and no amount of inspecting the painter's arguments
      would answer it. One subtlety fell out worth writing down: below one cycle per
      bucket the envelope legitimately traces the wave itself, zero crossings and all, so
      a test demanding a flat reading from a steady tone at *every* level would be
      demanding the analyser lie.
      Confirmed through the real engine rather than only in tests: `VD_SELFTEST=1`
      analyses `audio_steps.m4a` and prints the envelope a tenth of a second at a time,
      which reads **0.00 nine times, 0.25 ten times, then 0.90** — the fixture's own
      shape, out of FFmpeg, through FFI, at 8 KB for three seconds and 5 ms warm. It then
      draws the timeline with that file on an audio lane and writes the frame out, so the
      three steps are visible as a hairline, a half-height band and a full one. Reading
      it back from the peak file instead of analysing takes 2 ms.
      And then in the editor itself, which is where the last thing was found: the import
      self test only ever staged `.mp4`, so nothing unattended had ever walked the branch
      of `place` that puts a file with no picture on an audio lane. It stages the audio
      fixtures now, and the timeline that comes up shows all four cases at once —
      `audio_steps.m4a` stepping from a hairline to a half band to a full one,
      `audio_only.m4a` a steady line the length of the clip, `cfr_30fps_stereo.mp4`
      wearing a quiet strip along its bottom, and the two silent files wearing nothing
- [x] Keyframed volume (manual ducking)
      — a volume line on the clip, and one decision decides everything else:
      **where a point is measured from.** Not from the head of the clip, from
      the *source* — the coordinate `sourceIn` is already in. A duck is drawn
      against a word, and the head of a clip is a thing a trim moves; anchored
      there, trimming two seconds off the front would slide the whole curve two
      seconds along the audio it was drawn for and leave the dip somewhere
      nobody chose.
      Everything awkward then disappears rather than needing code. A **trim**
      is non-destructive: points outside the window are kept rather than swept
      up, so trimming in and back out brings the duck back. A **split** copies
      the line whole to both halves and divides nothing, because each half's
      window already reads the part of the curve it lands on — the level is
      continuous across the cut, and the test that says so compares the head's
      last tick with the tail's first. A **copy** carries the curve because the
      curve is part of the clip.
      Fixing the split turned up something next door: `SplitClip` built its
      tail with a fresh `Clip` and had never carried `transform` or `audio`
      across at all, so cutting a picture-in-picture put the tail back at full
      frame and cutting a quiet clip put it back at full volume. Both halves
      keep everything now, with the fades the one thing divided rather than
      copied — the head keeps its fade in and the tail its fade out, because a
      fade in on the tail is a ramp out of the middle of a continuous sound.
      The curve is **linear in amplitude**, like the fades and for the same
      reason, and **held flat outside its outermost points** rather than ramped
      back to unity — the first thing anyone does is drop one point and expect
      everything before it to stay put. It **multiplies** the fader instead of
      replacing it, so pulling the fader after drawing a duck moves the whole
      curve rather than flattening it, and mute still wins over both. Two
      points at the same tick are a step, not a division by zero.
      `vd_audio_automation_gain` joins `vd_audio_fade_gain` as a function
      written in two languages and asserted against one table, and the mixer
      evaluates it **per audio frame** for the reason the fade is: a curve
      stepped once per 1024-frame chunk is fifty small clicks. It walks the
      points with a cursor rather than searching per frame, and the arithmetic
      is one static function the cursor and the one-off lookup both call, so
      the *search* exists twice and the *maths* does not. This is the first
      thing on `VdTimelineClip` that is not a scalar; the array is copied on
      `set_timeline` like `path` is, and a test frees the caller's array before
      a single frame is decoded to prove it.
      On screen the line is amber over the waveform, hidden until the clip
      either carries a curve or is the one clip selected — a line across every
      clip is a lot of ink for a control almost nobody is using. Level maps
      linearly down the same band the waveform occupies, so unity is halfway
      up; a scale that gave ducking more room would have to bend somewhere, and
      a bent scale is one nobody can read a number off. **⌥-click** puts a
      point down, ⌥-click on one takes it away, and a plain drag on one moves
      it in time and level at once — points are a third kind of handle
      alongside the trim ones, checked before them and told apart by height, so
      a press at the same time but a different height still trims. Placing a
      point and pulling it down is **one** undo entry, and a drag measures from
      where the gesture began, so dragging back the way you came puts the point
      back. The inspector counts the points, clears them, and adds one at the
      playhead — ⌥-click on a waveform is not a gesture anyone guesses, so
      there is a way in that does not need to be.
      One rectangle moved to make this honest: the clip body and the strip its
      sound is drawn in now come from `TimelineGeometry`, so what the eye grabs
      and what the controller grabs cannot drift apart. A handle you can see
      and cannot hit is worse than no handle.
      39 new Dart tests and 5 new engine ones, including pixel tests that read
      the drawn line's height column by column and confirm the waveform under
      it shrinks where it dips.
      Confirmed in the running editor, not only in tests: `VD_SELFTEST=1` puts
      a duck on a real imported clip through the real command and prints the
      envelope a tenth of a second at a time — **1.00 eight times, 0.84, 0.52,
      0.20 for eleven, then 0.52, 0.84, 1.00** — reports what crossed to the
      engine as four points at their source ticks rather than as a number, and
      draws the timeline so the amber line and its four handles are something
      to look at. The duck is left on the clip, so the play pass that follows
      is playing it: **30.0 fps, 0 late frames, 0 underruns**
- [x] Rotation metadata honored; VFR sources normalized to project timebase
      — both halves were half-built, and both were wrong in the same way: the
      *file's* opinion about itself was being read and then not believed.
      Rotation had a path from the display matrix all the way to the vertex
      shader and nothing anywhere proved it went the right way round. Every
      rotation test used a flat colour, and a flat colour cannot tell a quarter
      turn clockwise from a quarter turn the other way — both move the bars to
      the sides and leave the centre alone. `quadrants_cw90.mp4` fixes that: it
      is the **same bitstream** as `quadrants.mp4` with a display matrix bolted
      on by `-c copy`, so the pair isolates the metadata rather than the
      encoder. Turned clockwise, the bottom left arrives at the top left, and
      reversing the shader's two odd cases now fails four assertions and
      nothing else.
      **VFR was the real bug, and it was not subtle.** The decoder read each
      frame's presentation interval as `[pts, pts + duration)` with the
      duration the container supplied, and on a source whose timestamps are
      genuinely irregular that put frames from the *future* on screen: on the
      new `vfr_bursts.mp4`, asking for 0.07 s returned the frame that belongs
      at 0.5 s, and held it for fourteen project frames. Then it swallowed two
      frames whose time a neighbour's duration had claimed. The claims are not
      wrong by accident — a muxer writes per-frame durations in **decode**
      order, so with B-frames they simply land on the wrong frames.
      The rule that replaces them is the one that is always true: **a frame is
      on screen until the next frame starts.** So the walk decodes until a
      frame lands *after* the time asked for; that frame is not the answer, it
      is what proves the one before it is, by ending its interval. It costs one
      decode past the frame wanted and never more than one, because it goes in
      the cache and becomes the next answer rather than being thrown away —
      the total decode count over a playthrough is unchanged. Cached durations
      carry a `confirmed` flag, since an unconfirmed one can be too long as
      easily as too short and a long one hides the frames it swallows.
      Two things fell out. A source already walked to EOF now answers from the
      cache instead of seeking back and decoding the whole tail to rediscover
      that there is nothing after the last frame. And `position` stopped
      meaning "where the next frame will be" and started meaning "where the
      last one was", which is the exact test for whether walking forward can
      still reach a given moment — the old value was a guess built from the
      same durations that were the bug.
      The fixture that used to stand for this, `vfr.mp4`, is **not** variable
      rate: selecting every third frame of 60 fps makes `r_frame_rate` and
      `avg_frame_rate` diverge, which is what the detection heuristic reads,
      but the timestamps that come out are a perfectly regular 20 fps. It is
      kept, for the heuristic. `vfr_bursts.mp4` is the one with irregular
      timestamps — bursts a sixtieth apart separated by holds of half a second,
      the shape adaptive-rate phone capture produces in changing light — and
      the test against it asserts the whole mapping rather than a property of
      it: for every project tick, the frame the file says is on screen.
      **Sample aspect came with it**, because it is the same defect and it was
      live: the thumbnail sized its box from the display aspect and the
      compositor fitted the coded size, so an anamorphic clip was one shape in
      the bin and another in the preview — against the one thing
      `vd_thumbnail.h` promises. `VdLayer` carries `pixel_aspect` now, applied
      *before* the rotation because a quarter turn puts the stretch on the
      other axis, and the app's `MediaProbe` carries it too so the bin's label
      agrees with the bin's picture. The five existing goldens came back byte
      for byte, which is the proof it is a no-op on square pixels.
      A sixth golden is the case this bullet is really about: a clip shot
      upright, in a 16:9 project, blur-filled. Rotation and blur fill meet
      there and nothing else checks that they do — a blur pass that sampled the
      source in its coded orientation would fill the pillars with a sideways
      wash and look convincing doing it.
      13 new engine tests across probe, decoder, compositor, thumbnail and
      transport, including one that plays a turned clip through the whole
      engine and reads the four quarters of the output.
      Confirmed in the running editor: `VD_SELFTEST=1` imports all six picture
      fixtures through the real probe and prints, per file, the coded size, the
      metadata and the display size that has to follow from them —
      `anamorphic_sar2.mp4 coded 160x240 par 2 rot 0 -> display 320x240`,
      `quadrants_cw90.mp4 coded 320x240 par 1 rot 90 -> display 240x320` — and
      then dumps a composited frame of each turned clip. That frame reads blue,
      red, yellow, green clockwise from the top left: the file's own quarter
      turn, on screen, through the real preview. The play pass that follows is
      **30.0 fps, 0 late frames, 0 underruns**
- [x] Keyboard shortcuts v1: space, split, delete, undo/redo, zoom, nudge
      — most of the list was already bound, one at a time, as each command
      arrived and needed *some* way to be reached. What was missing was
      **zoom**, which had no key at all, and the thing that makes a set of
      shortcuts different from a pile of them: somewhere they are all written
      down, and a way to find out what they are.
      The bindings are now **one const table** in `lib/ui/shortcuts.dart` —
      action, keys, label, group — with no callbacks in it. The screen supplies
      one handler per action and `shortcutBindings` puts the two together,
      *refusing* if any action is unhandled: a shortcut wired to nothing is a
      key that does nothing when pressed, which reads as a broken editor rather
      than as a missing case, and failing to build the screen is the louder
      outcome. The map used to be assembled inside `build()`, where it could be
      checked for none of this.
      The mistake that table prevents is the quiet one. `CallbackShortcuts`
      takes a *map*, so two actions on one chord do not conflict — the second
      one written wins, for ever, and nothing says so. A test now owns that,
      and a second test presses **every chord in the table** and asserts it
      reaches its own action, because an activator can be well-formed, unique
      and still never match.
      **The arrow keys became a family**, which is the part worth remembering:
      unmodified is a frame, which is the unit the playhead moves in; ⇧ is a
      second, for covering ground; and **⌥ is the next edit point**, which is
      what anyone scrubbing is actually aiming at and the only one of the three
      a pointer cannot hit exactly. Cuts come from the same set of edges a drag
      snaps to, so what the keyboard lands on and what a drag sticks to are one
      idea rather than two. It stops at the ends rather than wrapping: a key
      pressed expecting nothing to happen should not move the playhead a long
      way.
      **Zoom needed an anchor.** A pointer zoom holds still whatever is under
      the pointer, because that is what the person is looking at; a key has no
      pointer, and the toolbar buttons had been zooming around the **left edge
      of the view** — which walks the thing being worked on off the screen
      every second press, and is exactly what `timeline_geometry.dart`'s own
      comment says not to do. The answer is the **playhead**, and then a scroll
      to make sure it is still visible, which matters when it was already off
      screen. Buttons and keys now make the same call, so a button and its
      shortcut cannot move the timeline to two different places.
      That needed the controller to know how wide it is being drawn, which it
      did not. `Fit` was guessing at `MediaQuery.width - 240` — right until
      somebody changes the layout and quietly wrong afterwards — and `pump`
      took the width as an argument from the one caller that had it. The view
      sets `viewportWidth` at layout now, so there is one answer and it is
      never the caller's guess. Fitting before the first frame does nothing
      rather than collapsing the zoom to its floor.
      **⌘/ opens a list of all of it**, generated from the table. That is the
      whole reason the table is data: a hand-kept list is wrong the first time
      somebody changes a key, and the only thing that reads it is a person who
      already believed it. Its test walks every row of the table and finds it
      in the sheet, scrolling to it — the list is longer than the sheet and
      builds lazily, so merely searching would pass or fail on where a row
      happened to land.
      **Not included, deliberately:** nudging a *clip* with the arrow keys. On
      the main track it is not a coherent idea — the lane is magnetic, so a
      clip pushed a frame is repacked straight back, and a clip pushed far
      enough reorders instead. A shortcut that silently does nothing on the
      lane most editing happens on is worse than no shortcut, and moving clips
      by keyboard belongs with group drag, which is already a bullet of its
      own.
      26 shortcuts, 17 new tests. What none of them can say is which *physical*
      key produces which logical one — the events a widget test sends are
      synthetic — so whether `⌘+` arrives as shift-and-equal on a real keyboard
      is the owner's to press

**Exit criteria:** cut a real 2-minute multi-track video (picture-in-picture + music bed)
start to finish without touching another editor; undo works through the whole session.

---

## M3 — "It's an editor" (text, overlays, effects)

### Text & shapes
- [x] Text rendering with bundled fonts: fill, stroke, shadow, background box, spacing, alignment
      — the first clip on the timeline that is **drawn rather than decoded**, and the
      decision worth remembering is where it is drawn. A caption is laid out by
      **Core Text inside the engine** (`vd_text.mm`) into an output-sized
      premultiplied BGRA buffer, and handed to the compositor as an ordinary
      `VdLayer` — same transform, same opacity, same z-order as a decoded frame.
      Rasterising it in Dart would have been less code and would have made text
      the one thing preview and export can disagree about: a frame has to stay a
      pure function of `(document, time)` with no UI attached, because an export
      driven by a frame counter has no widget tree to ask. It is also what lets
      the engine's own tests see the words at all.
      The compositor grew one branch for it — `VD_PIXEL_BGRA`, which reuses the
      pass that already draws the blur-fill background, because a premultiplied
      RGBA texture is a premultiplied RGBA texture.
      **Nothing about a caption is measured in pixels.** Size is a fraction of the
      output height and everything else — outline width, shadow offset and blur,
      box padding and corner, letter spacing — is a fraction of the font size, for
      the same reason `ClipTransform` has none: a project cut at 1080p and
      exported at 4K has to put the same words in the same place at the same size,
      and a point size stored in the file is right at exactly one resolution.
      **The layout box is as wide as wrapping allows, and the background box hugs
      the words.** They are different rectangles on purpose. A block that hugged
      its own text would leave "align left" doing nothing at all to a single line,
      which is the case alignment is asked for most; a background box as wide as
      the wrap would be a bar across the frame. So alignment moves lines inside
      the wrap width, and the box is measured back off the lines that actually got
      drawn.
      Line spacing is applied **between** lines rather than above every one of
      them. A line-height multiple adds its extra space above the first line too,
      so the block sinks below the middle of the frame — a caption that moves when
      its leading changes is a caption nobody can place.
      **The raster is kept until the caption changes**, on exactly the terms a
      decoder is kept across an unchanged path: `vd_text_spec_equal` decides, and
      `VdEngineStats::text_rasters` is how a test can tell. Measured in the running
      app, eight seeks across a caption lay it out **zero** further times.
      **Five bundled OFL faces** — Inter, Anton, Playfair Display, Caveat, Space
      Mono — one for each job a caption has, with their licences beside them. They
      are registered into the engine's *own* catalogue rather than with
      `CTFontManager`, which only offers session or machine scope for a font that
      came from memory: a video editor has no business changing which fonts the
      computer it is running on has. Each family name is written down three times —
      in the file, in `BundledFonts.faces` so the picker works with no engine
      alive, and in `pubspec.yaml` so Flutter can preview it — and two tests hold
      the three together, because the failure is silent: a family nothing is
      registered under draws perfectly well in the wrong face.
      **Text is checked on where the ink is, not on which pixels it covers.** The
      compositor is pinned by golden frames; text deliberately is not. Hinting and
      subpixel positioning are the parts of Core Text most likely to be tuned in a
      macOS release, and a reference PNG of a sentence would go red on an OS
      upgrade while the renderer was still perfectly correct. `vd_text_test.c`
      asserts the properties that survive any amount of rasteriser drift and break
      the moment the layout is wrong: alignment moves the block, letter spacing
      widens it, line spacing heightens it without moving it, the box sits behind
      it, the shadow falls below and to the right of it, and no pixel has more
      colour than alpha.
      ⌘T puts one at the playhead, on the first text lane with room and on a new
      one when there is none — stacking two on a lane is impossible and refusing
      would be a button that stops working exactly when somebody wants a title and
      a subtitle at once. Lane and caption are **one undo entry**, which is what
      `InsertClips.newTracks` exists for.
      Text lanes are capped at **8**, which the brief does not state; that number
      and `VD_MAX_LAYERS` are the same decision written twice and have to move
      together, or a lane the document allows is a caption the compositor drops.
- [x] ~8 in/out animation presets (fade, slide, pop, scale, typewriter, …)
      — nine of them, and the thing worth remembering is what an animation
      *is* here: a **pure function of one number**, evaluated by the engine
      once per layer per frame and folded into the transform the clip already
      had. There is no keyframe list to walk and no state carried between
      frames, so a seek into the middle of an entrance shows exactly the frame
      playback would — a rendered frame stays a pure function of
      `(document, time)`, which is the invariant the whole engine is shaped
      around.
      It also means an animation costs **nothing**. Every preset but one is
      the same pixels moved about, so an animated caption is laid out once for
      its whole life however much it slides, turns and fades. Measured in the
      running app: forty frames across a spin and a slide, **one** layout.
      **Composed with the clip's transform, never replacing it.** Offsets add,
      scale multiplies, rotation adds, opacity multiplies. A caption parked at
      the bottom of the frame that slides up has to slide up from below *its
      own* position, and a clip placed at 40% that zooms in has to end at 40%.
      The one trap was the compositor's "a zeroed scale means as-fitted"
      convention: multiplying that zero and letting the normalisation happen
      afterwards throws the animation away silently, so the scale is resolved
      before it is multiplied.
      **A preset names the direction the clip travels, not the edge it comes
      from.** `slideUp` rises into place on the way in and carries on upwards
      on the way out — one rule for both halves, where "in from the left, out
      to the left" would be two and the second one is the one nobody predicts.
      **The typewriter is the exception, and it is the interesting one.** It
      is the only preset a transform cannot express, so it reaches into the
      raster instead: the engine's caption cache is keyed on `(spec, size,
      revealed characters)`, which means a caption is redrawn **once per
      character rather than once per frame**. Thirty frames across a
      six-character typewriter cost six layouts, and the moment it finishes it
      stops entirely.
      What makes it read as typing rather than as sliding is that **the layout
      is computed from the whole caption and only the drawing is cut short**.
      A line that re-centred itself on every keystroke would be unreadable and
      one that will wrap would reflow underneath its own animation, so
      `vd_text_render` lays out everything and draws a prefix — line by line,
      run by run, and glyph by glyph in the run the reveal lands inside.
      Characters are **composed** characters, so an accent or a flag arrives
      whole.
      **This one is not written twice.** The audio envelopes live in C and in
      Dart because the app has to *draw* them on a waveform; nothing draws an
      animation curve, so a second copy would be a second thing to keep in
      step with no reader. `vd_anim.c` is plain C with no platform dependency
      — the one piece of the picture testable without a GPU or a typeface —
      and 412 checks in `vd_anim_test.c` pin every preset's two ends, the
      properties that make each one itself, and what happens on a clip too
      short to hold both halves. The easing *between* the ends is deliberately
      not asserted: a curve is a design decision, and pinning its midpoint
      would make every future adjustment a red test with nothing wrong behind
      it.
      Animation applies to **any** clip rather than only to a caption, which
      is a small widening of the bullet and the honest one: it is the
      transform the clip already has, over time, so restricting it would have
      cost an extra check and surprised anyone who wanted a photo to pop in.
      The typewriter is offered only where there is text for it to reveal.
      Three enums — the document's, the plugin's and the C header's — carry
      the same list in the same order, because the *index* is what crosses the
      boundary; one test compares all three, including the generated bindings,
      so a preset inserted in the middle of the header renames every animation
      on disk loudly rather than quietly.
- [x] Shape primitives: rect, rounded rect, circle, line/arrow — fill/stroke, same transforms
      and animation presets as text
      — four kinds rather than six, because a rounded rectangle is a rectangle
      with a corner and a circle is an ellipse with equal sides: both are one
      slider away from the entry beside them, and a picker with two rows that
      draw the same thing makes the reader look for a difference that is not
      there.
      A shape is the **second** source the engine draws rather than decodes,
      and the interesting thing is how little it cost. Everything a caption
      already had, it inherited: the same `VdLayer` into the same compositor,
      the same transform, the same z-order, the same in/out presets, the same
      "keep the raster until the spec changes" bargain. `vd_shape.c` is 230
      lines of Core Graphics and the wiring was one field on `VdTimelineClip`.
      That is what "a caption is a source, not a compositing mode" was worth —
      the decision paid for itself the first time a second drawn thing arrived.
      **Every length is a fraction of the output height.** Not of the width,
      and not one of each: measured half against the width and half against the
      height, a shape changes shape when the project's aspect does, and then a
      circle is only round at 16:9. One unit for all four numbers also makes
      them comparable by eye. This is one rule where a caption has two — a size
      against the output and everything else against the font size — because a
      caption has a single size to hang the rest off and a shape has two, so
      picking either would make the other axis surprising.
      **One box, four shapes.** A rectangle fills it, an ellipse is inscribed
      in it, a line runs across it from the middle of the left edge to the
      middle of the right. That is what makes the two size numbers mean the
      same thing in all of them — and it has an honest consequence, which is
      that a line's box has a height that changes nothing. The inspector says
      so by calling the width "Length" and not offering the height at all: a
      slider that moves nothing teaches people not to trust the panel.
      **A line has no interior, so the stroke *is* the shape** — which is the
      one place the model needed a decision rather than a field. A filled
      rectangle turned into a line has its colour in the wrong field and no
      thickness at all, so it would vanish, and a picker whose third entry
      blanks the clip is a picker nobody presses twice. `ClipShape.withKind`
      carries the colour across and gives the stroke a width, once, and only
      when there is nothing there already. Changing the kind is not only
      changing the kind.
      **One shadow for the whole silhouette**, cast from inside a Core Graphics
      transparency layer. Without the layer a stroked shape casts two — the
      fill's and the stroke's — and they show through each other wherever the
      shape is not opaque, which looks like a rendering bug because it is one.
      The test is one byte: a shape at half opacity casts a shadow at half
      opacity, where two would compound to 1-(1-0.5)², and 0x80 is not 0xBF.
      **Shapes share the text lanes** rather than getting lanes of their own.
      A shape is the same kind of thing — no file, drawn by the engine, wants
      to sit over the picture — and a second family of lanes would be a second
      cap to keep in step with `VD_MAX_LAYERS` for no difference anybody could
      see. So `MoveClip.accepts` is written against `isGenerated` rather than
      `isText`, and ⌘R puts one at the playhead the way ⌘T puts a caption.
      Two things were **written once** rather than twice on the way through.
      `vd_raster` is the pixel buffer, the context and the colour that both
      drawn sources need — the alternative was thirty-five duplicated lines and
      the copy that drifts is always the one nobody is looking at. `vd_ink.h`
      is how both engine test files read a raster back, and text and shapes are
      checked the same way for the same reason: what Core Graphics puts along
      the edge of a circle is no more a contract than what Core Text puts along
      the edge of a glyph, so a golden PNG of either would go red on an OS
      upgrade with nothing wrong behind it. The compositor keeps its goldens;
      neither drawn source joins them.
      Measured in the running app: three layers — a decoded frame, a caption
      and a shape over it — one draw per shape, and **zero** further draws
      across eight seeks. The typewriter, offered on a shape because the menu
      does not change shape with the selection, quietly does nothing to it and
      costs nothing per frame doing so.

### Stickers & GIFs
- [x] GIF / animated WebP / APNG decode → cached RGBA sequences, retimed to project fps
      — the third kind of layer, and the first one that is a *file* the engine
      does not decode like video. `vd_sticker` is the opposite trade from
      `vd_decoder`: all the work at open, none of it per frame. Three reasons,
      and each one rules the decoder out rather than merely preferring not to
      use it.
      **It has no keyframes to seek to.** Every frame of a GIF is a patch on
      the one before it, disposal method and all, so "seek to 3.4 s" means
      decoding from the beginning whatever happens — and a decoder built around
      seeking would do that on every scrub.
      **The alpha is the point.** `vd_decoder` hands the compositor YCbCr and
      refuses anything that is not VideoToolbox or YUV420P, so a GIF does not
      merely look wrong through it, it produces no frame at all. A sticker
      arrives as premultiplied BGRA — the same thing a caption and a shape
      arrive as, through the same `VdLayer` — which is why an overlay
      composites over the shot instead of being a rectangle with a picture
      painted on it.
      **It is small enough to hold.** A whole animation is a few megabytes of
      RGBA, less than the frame cache a decoder would need to scrub it.
      **Retiming to the project's rate falls out of asking by time**, which is
      the part worth remembering. Each frame carries the interval it is on
      screen for, in ticks, and a lookup finds the interval containing the
      instant — so a 4 fps sticker shows each frame for fifteen frames at 60 fps
      and for six at 24, and nothing resamples anything. Nothing in `vd_sticker`
      knows the project's frame rate. `sticker_uneven.gif` is the fixture that
      pins it: read at its nominal rate 0.4 s would be the second frame, and
      read by time it is still the first, because the first frame's delay is
      half a second.
      **A sticker loops**, which is what makes a one-second GIF usable on a
      ten-second clip — and therefore what makes it *endless* on the timeline,
      like a still image: its own length is not a limit on it, so it lands at
      the still-image length rather than at one loop and `maxDurationFor`
      returns nothing at all.
      **One buffer, not one per frame.** The frames live as one flat
      allocation of premultiplied BGRA and the current one is copied into a
      single IOSurface when it changes — a hundred-frame GIF would otherwise
      spend a hundred IOSurfaces to show one. That copy is also the
      measurement: `VdEngineStats::sticker_frames` ticks at the *sticker's*
      rate, and thirty renders across a four-frame loop cost four.
      **The budget scales rather than truncates.** An animation too big for its
      64 MB is decoded *smaller*, never *shorter*: losing resolution on an
      overlay is a compromise somebody might not notice, and losing the second
      half of the animation is a bug they certainly would. The engine's own cap
      is in bytes rather than in files, because a sticker's cost is memory and
      not a file handle — a cap on the count would let one big one through
      while turning a dozen small ones away.
      **A sticker is decided by its codec**, and that list is written twice —
      `vd_sticker_is_sticker_codec` and `MediaProbe.stickerCodecs` — with one
      table asserted in both test suites, exactly as `vd_time.c` and `time.dart`
      are. It has to be: the engine classifies a file with no Dart, and the app
      classifies one with no engine, because a project is read back before
      anything native is alive. The codec rather than the extension, because a
      `.webp` may be either and the container is the thing that knows — and
      because it means a GIF in a project written *before* this milestone opens
      as a sticker with no migration step for anybody to forget to run.
      **A sticker is an overlay, and lands like one.** On the magnetic main lane
      it would repack the footage around it and then composite underneath it,
      which is two surprises for one drop. It goes on an overlay lane, made in
      the same command as the clip so undo cannot leave an empty one behind —
      and *contained at two fifths*, because the default every other clip gets
      is blur-fill, which would paint a blurred copy of the sticker across the
      whole shot and hide the very picture it is an overlay on. That one was
      found by looking at the frame rather than at the test.
      Thumbnails needed a head of their own for the same reason the compositor
      did: `vd_decoder` cannot open one of these at all, so without it every
      sticker in the bin is a blank rectangle — a silent failure that looks
      like a slow import.
      Measured in the running app: a GIF imported through the real importer
      lands on a lane made for it, opens **once**, holds 4 KiB, and **thirty
      renders across one loop cost four frame changes**. Two seconds into a
      one-second animation it is showing its first frame again, over the shot.

### Transitions
- [x] Cross-dissolve, slide/push, wipe, fade-to-black, fade-to-white; adjustable duration;
      overlap model (never fails for lack of media)
      — six presets, and the decision that matters is **where the overlap
      lives**. A cross-dissolve needs both clips on screen at once, and that
      overlap has to come from somewhere.
      Most editors take it out of the timeline: the incoming clip is pulled
      earlier, the sequence gets shorter, and the cut consumes handles. Here it
      is made by the **engine** instead. The document keeps its clips
      butt-joined and non-overlapping, because `Track`'s no-overlap invariant is
      not decoration — `Track.clipAt` binary-searches on it, and so do hit
      testing, split and insert. Breaking it for one feature would have poisoned
      all of them, and shortening the sequence would repack the magnetic lane
      and move every clip downstream of a cut nobody dragged.
      So a transition **straddles the cut and moves nothing**: half the window
      each side, and the engine widens the two clips' drawing windows across it.
      Through its half each clip is asked for a source time outside its own
      trim — and `vd_decoder_frame_at` already clamps, which is the whole of
      "never fails for lack of media". A cut between two clips trimmed to their
      very ends still dissolves, with a held frame on the side that ran out.
      That behaviour was written for scrubbing and paid for itself here.
      **It is recorded on the incoming clip and names only its own head.** A cut
      has two sides and a transition is one decision, so writing it on both
      would be two places to keep in step and one of them eventually wrong. The
      engine pairs it with whatever ends exactly at that start — once per edit,
      not once per frame.
      Five of the six are things the compositor could already do: a dissolve is
      the incoming clip's opacity (and the outgoing one stays at *full*, because
      with premultiplied over-blending B at alpha t over A already gives
      B·t + A·(1−t) — turning A down as well would let the black behind them
      show through the middle of every dissolve). Slide and push are offsets.
      The two fades are a solid layer dipped over both clips and under anything
      on a higher lane, so a caption over a fade to black stays legible — and it
      has to be a *layer*, because turning the clips' own opacity down dips to
      whatever is behind them, which on an overlay lane is the main track and
      for white is nothing at all.
      **The wipe needed one new thing**: `VdLayer::reveal`, a hard edge in the
      layer's own space. A crop would shrink the picture and a scale would move
      it; a wipe is an edge crossing a picture that is standing still. Zeroed
      hides nothing, so every caller that has never heard of it is unaffected —
      the golden frames did not move.
      **And it found a real bug, by looking at a frame rather than at a test.**
      A blur-filled clip is drawn twice: its backdrop is rendered into an
      offscreen texture and then composited full-width. Cutting the *first* of
      those left the hidden part of the offscreen as opaque black, which was
      then painted over everything underneath — so a wipe erased the clip it was
      wiping away from. The cut belongs at the composite, where discarding
      leaves what is beneath showing. Every engine test used contain or stretch,
      which have no second pass; blur fill is the document's default, so every
      wipe in the actual app was broken and nothing red said so.
      Measured in the running app: four presets across a real cut, one extra
      layer inside the window and two inside a fade, and the frame at the middle
      of a fade-to-white is white — with the sticker from a higher lane still
      over it.

### Effects
- [x] Color adjust on GPU: brightness, contrast, saturation, temperature, tint
      — five sliders, and the decision that matters is that **all five are one
      matrix**. Every one of them is an affine operation on RGB: a gain, a
      scale about a pivot, a lean towards grey, a lean towards one end of the
      spectrum. So they compose into a single 3x3 and an offset, worked out
      once per layer per frame on the CPU, and the shader does one
      multiply-add and knows nothing about sliders.
      That is what makes the part worth testing testable. `vd_color.c` is
      plain C with no platform dependency — like `vd_anim.c` and
      `vd_transition.c` — so what a grade *means* is asserted against numbers
      with no GPU in the room, and what is left in Metal is a matrix multiply
      a test could tell you nothing about. It also draws the line the LUT will
      need: a LUT is precisely the grade that is **not** affine, which is why
      it arrives as a lookup table and not as five numbers.
      **Every slider runs −1..1 with 0 the shot you shot.** One range for all
      five rather than a natural range each, so the panel is readable at a
      glance — and so a zeroed struct is the neutral grade, which is what lets
      a caller memset its layers and never learn the field exists. The
      compositor asks `vd_color_is_neutral` before it does anything, so an
      ungraded fragment takes the arithmetic it took before this existed, bit
      for bit; the golden frames did not move.
      Two decisions inside the maths are worth the ink. **Brightness is a gain,
      not a lift** — adding a constant raises the blacks to grey, which is the
      faded look and not what anybody means by "brighter". And **warming a shot
      must not also brighten it**: raising red and lowering blue by the same
      amount raises the picture's luma, because red weighs three times what
      blue does, so the channel gains are divided through by the luma of the
      white they produce. Without that, a temperature slider is an exposure
      slider wearing a hat and the user fights it with the brightness one.
      They compose in the order anybody grades in — fix the light, set the
      level, set the contrast, judge the colour last — and the inspector offers
      them in that order, because a panel in another order teaches the wrong
      habit.
      **A grade is per layer, not per frame.** A grade on the frame would be an
      effect on the *project*: a shot that needed warming would warm the
      caption over it and the clip on the lane beneath it too. Here it travels
      with the clip the way its opacity does. It reaches the premultiplied
      layers as well — a sticker can be tinted — undone and redone around the
      alpha rather than applied through it, and a blur-filled clip's backdrop
      is graded with it *once*, because grading the offscreen and then grading
      it again on the way out would leave the bars twice as far from neutral
      as the picture in them.
      Measured in the running app at 1920x1080: eleven grades on one shot,
      **layers flat at 2 and decoders flat at 5** through all of them — a
      slider that reopened the file on every value would stutter the preview
      for the whole drag. Fully desaturated, **91% of the frame is exactly
      grey** and the corner reads 151 where BT.709 luma of the source's
      (0,201,101) is 151.1; the other 9% is a single 432x432 square in the
      middle, which is the sticker on the overlay lane, ungraded.
- [x] LUT filter presets: `.cube` loading, five bundled looks, per-clip
      strength — **the grade that cannot be a matrix**. The five sliders above
      are every affine operation on RGB there is, which is exactly why they
      fold into one 3x3; a look is the arbitrary map that is left over. A
      split-tone sends the shadows towards teal while sending the highlights
      towards orange, and no matrix applies two directions to one axis, so it
      arrives as a lattice: `vd_lut.c` reads the file, samples it trilinearly,
      and bakes the cube the shader fetches from. Plain C with no platform
      dependency, like `vd_color.c` beside it — what a look *means* is asserted
      against numbers, and what is left in Metal is a texture fetch a test
      could tell you nothing about.
      **It runs in the signal, not in linear light**, and that is a correction
      to what this plan said before the work started. A `.cube` declares a
      lattice and a domain and says *nothing* about the colour space of its
      input, so the only thing that decides is convention — and the convention
      for every creative look a user will download is Rec.709 as it comes off
      the wire, which is exactly what `ycbcr_to_rgb` produces and exactly where
      `vd_color_transform` already works. Sampling one of those after a
      linearising transfer gives a crushed picture that is nobody's look. A LUT
      authored for linear input exists, in ACES pipelines, and is not what
      arrives through a file panel.
      **The sliders run first and the look runs last**, which is the order a
      colourist works in — correct the shot, then style it — and the order the
      look was authored expecting. The inspector offers them that way round for
      the reason it already puts temperature above saturation: a panel in some
      other order teaches the wrong habit.
      **A look is a name, and the name is what the project file records.** The
      arrangement fonts already have, for the same two reasons: the bundled
      cubes have no path inside a signed bundle, and a file naming one
      machine's `~/Downloads` is a file that only opens on that machine. A
      project naming a look this installation does not have draws ungraded,
      exactly as a caption in a missing face falls back to the system's. A
      `.cube` the user loads is *copied* into their own library rather than
      linked to — no bookmark to mint, nothing to break when they tidy up, and
      a look is a tool they will want on the next project too.
      The five bundled looks are **generated** by `tools/make_luts.dart`, not
      vendored: a look that ships in a product sold without an account has to
      be one we may sell, and the `.cube` files people share are almost never
      licensed for that. Each is thirty lines of arithmetic somebody can argue
      with rather than a quarter of a million numbers nobody can review.
      Two details worth the ink. The cube goes to the GPU as **RGBA16Unorm**,
      because RGBA32Float is not filterable on Apple GPUs and the hardware
      trilinear the whole design rests on would silently stop happening —
      showing up as banding rather than as an error. And `vd_lut.c` parses its
      own decimals rather than calling `strtof`, which reads the *locale's*
      separator: under a locale where that is a comma, every value in the file
      would be read as its integer part and every look would load without
      error and render as garbage. That is a bug that only happens on other
      people's computers.
      Measured in the running app at 1920x1080: five looks at two strengths
      each, **layers flat at 2 and decoders flat at 5**, and **five cube
      uploads across eleven grade changes** — one per look, and nothing at all
      for the drag on the strength slider. Noir returns **100% grey** away from
      the sticker, at 157 where the BT.709 luma of the source's (0,201,101) is
      151 before its own curve lifts it; half strength lands on (78,179,129),
      exactly halfway between the ungraded shot and the full look on every
      channel.

### Speed
- [x] Constant 0.1×–10× per clip; frame duplication for slow-mo — and the
      decision that makes the picture side cost nothing is that **a speed is a
      rate, not a length**. `Clip.duration` stays what it has always been, the
      clip's length on the timeline, so `Track.clipAt`'s binary search, the
      magnetic packer, hit testing and split all keep exactly one way of asking
      how long a clip is. What a rate says is how fast the window travels over
      the source while the clip is on screen, and the window it implies —
      `duration × rate` — is derived and never stored. That is what makes a
      retime reversible: what it holds still is the *window*, so a clip taken
      to 4× and back to 1× is the clip it started as rather than a sixteenth of
      it. The alternative — storing the source window and deriving the length —
      is the same information and a worse trade, because then every question
      about the timeline has to divide first.
      Because it *is* a change of length, it is bounded like a trim: no more
      source than the file has, and on a free-form lane no further than the
      next clip. On the magnetic lane there is no ceiling to hit — the
      neighbours move — which is what makes slowing a shot down on the main
      track the obvious thing rather than a fight. The floor of one frame is
      the exception and bends the other way: growing the length back up at the
      rate asked for would widen the window, so the **rate** gives way instead
      and a clip with a frame of source in it has nothing left to play faster.
      A sticker is the other exception — its own length is one loop rather than
      a limit, so there is no window to hold still and retiming one changes how
      fast the loop runs and nothing about how long it is on for.
      **Frame duplication is not a feature here; it is what asking already
      does.** A frame is on screen until the next frame starts, so a source
      time that has not left the current frame's interval comes straight back
      out of the decoder's cache. There is no duplication step anywhere in the
      engine because there is nothing to duplicate — the whole of it is one
      multiply in `source_time_at`, written twice because the sound has to
      agree with the picture about where in the file it is.
      Measured in the running app at 1920x1080, four consecutive project frames
      from the head of the clip at each rate: at a **quarter speed all four
      PNGs are byte-identical** — 0.000, 0.008, 0.017 and 0.025 seconds into a
      source whose frames are 0.033 apart — at half speed they are two pairs,
      and at 4× all four differ, landing 0.133 seconds apart. The source window
      reads **2.00s at every rate** while the timeline length goes 8.00, 4.00,
      1.00, 0.50; back at 1× the clip is 2.000s against the 2.000s it started
      at. Layers flat at 2 and decoders flat at 5 throughout.
- [x] Pitch-preserved audio time-stretch, with per-clip pitch-shift toggle —
      the whole cost of the feature, and the reason it is a module of its own.
      A frame can be sampled at an instant and sound cannot: twice as many
      samples have to become half as many, and there are exactly two honest
      ways to do it. `vd_stretch.c` is both. **Pitch preserved** is WSOLA —
      overlapping windows of the source laid down at the output's rate, each
      slid within a 15 ms search to wherever it best continues the last one —
      and it is the default, because a slowed shot almost always wants the
      voice in it to still be that voice. **Pitch shifted** is the tape: the
      samples played faster, everything rising together. A per-clip toggle
      rather than a rule, because a comedy speed-up wants the chipmunk and no
      engine can tell which one this is.
      Plain C with no platform dependency, on `vd_color.c`'s and `vd_anim.c`'s
      terms and for their reason: what a stretch *means* is asserted against a
      sine in an array, with no file, no device and no clock in the room, and
      it is **not** mirrored in Dart because nothing in the app draws one.
      Two details inside it are worth the ink. The analysis position advances
      by a fixed `nominal_skip` whatever the overlap search picks, so the
      offset is a perturbation and never an accumulating drift — the output
      stays exactly `rate` times shorter than the input however hard the search
      argues with itself. And speeding up *decimates*: taking the nearest input
      frame folds everything above the new Nyquist back into the audible band
      as a whistle, so the resampler averages over the whole span each output
      frame stands for, a box whose first null sits exactly where that whistle
      would have come from. Asserted both ways: **12 kHz at 4× comes back at
      0.000 RMS** — the box's first null sits exactly there, where taking the
      nearest frame would have folded it down to an audible 4 kHz tone — and
      1 kHz at the same rate comes back at 0.70, which is a full-scale sine
      untouched.
      The mixer needed one change to carry it: a clip's `expected_position` is
      now a *timeline* position rather than a source one. A stretcher buffers
      its own input, so the source position after a chunk sits a window ahead
      of where the arithmetic says, and comparing the two would re-seek — and
      reset the stretcher — on every chunk of every retimed clip. A clip at 1×
      keeps no stretcher at all, so the common path is the path it always was.
      Measured in C: a 440 Hz tone through the real mixer reads 440 Hz at both
      half and double speed with the pitch kept, and 220 and 880 with the
      toggle on. Measured in the running app, which is the part no offline test
      can reach: three seconds of playback of a half-speed clip with the pitch
      kept gave **0 underruns and 0 late frames**, 90 frames in 3.04s.

### Audio effects
- [x] EQ presets and fade curves — two features that share a panel and land on
      opposite sides of the same rule.
      **A fade has a shape.** Four ramps, each with a job rather than a taste:
      **linear** (a straight line in amplitude — the handle position means what
      it looks like it means, and it is what every fade was before there was a
      choice, so it stays the default and every existing project sounds bit for
      bit as it did), **smooth** (a raised cosine, no corner at either end,
      which is what a fade over music wants), **equal power** (a quarter of a
      sine, which holds *power* constant so two clips overlapping on two lanes
      cross without the 3 dB dip a pair of straight lines leaves in the middle
      — the one shape here that is about a crossfade), and **exponential**
      (t squared: starts almost silent and arrives late, the shape a long
      musical fade-in wants). One curve per clip and not one per fade: two
      shapes on one clip is a distinction nobody makes, and it would double the
      field, the picker, the file format and the shared table for nothing.
      Because the timeline *draws* a fade — the waveform is scaled through
      `Clip.gainAt` — the curve is written twice, and the table that pins it
      grew a column per curve rather than a second table. A curve inserted in
      the middle of one of the three enums therefore reads the wrong column and
      the table says so, which is a second reason for it beyond the numbers.
      **An EQ is a name.** Presets rather than a parametric equaliser, and that
      is the whole design: three bands with frequency, gain and Q each is nine
      numbers, a panel nobody can read at a glance, and — for the people this
      product is for — a way to make a recording worse with great precision.
      What they want is "make this voice sound like a voice". Five of them,
      each built for a job: **voice** (high-pass at 90 Hz, 3 dB out of the room
      boxiness at 300, 4 dB of presence at 3k — cut first and lift second, so
      the presence is not amplifying the mud), **music** (a gentle smile),
      **bass**, **bright**, and **telephone**, which is the one effect. Every
      one is a cascade of biquads with RBJ coefficients, and the document
      carries only the *name* — `vd_eq.c` owns the meaning, the arrangement a
      look and a transition preset already have. So the curve is mirrored in
      Dart and the EQ is **not**, which is `vd_anim`'s rule applied twice and
      landing on opposite sides.
      One ordering decision in the mixer is worth the ink: the filter runs
      **before** the envelope. A filter is linear so a gain and an EQ commute,
      but the envelope is a gain that *changes*, and running a fade into a
      biquad has the filter chasing the ramp instead of the sound.
      Measured in C: every preset asserted in decibels by pushing sine waves
      through it — voice is 22 dB down at 25 Hz and +4 at 3 kHz, telephone is
      24 down at 100 Hz and 28 down at 12 kHz, and bass and bright each move
      one end and leave the other inside half a decibel. The coefficients and
      the filter are checked against each other, the two channels are checked
      for not leaking into one another, and filtering in blocks of 1, 7, 64,
      1000, 333 and 2691 frames gives the same samples as filtering in one go.
      Measured in the running app, a tenth of a second per column and read
      straight out of `Clip.gainAt` — the function the waveform painter calls,
      so this is the envelope the timeline actually draws:

      | curve | 0.0s to 0.9s of a one-second fade in |
      |---|---|
      | Linear | 0.00 0.10 0.20 0.30 0.40 0.50 0.60 0.70 0.80 0.90 |
      | Smooth | 0.00 0.02 0.10 0.21 0.35 0.50 0.65 0.79 0.90 0.98 |
      | Equal power | 0.00 0.16 0.31 0.45 0.59 0.71 0.81 0.89 0.95 0.99 |
      | Exponential | 0.00 0.01 0.04 0.09 0.16 0.25 0.36 0.49 0.64 0.81 |

      Four rows that all start at 0 and end at 1 and get there differently is a
      check anybody can make at a glance. And the part no offline test can
      reach, since they all pull the renderer with no device and no deadline:
      three seconds of playback of a clip running an equal-power fade through
      the three-section voice cascade gave **0 underruns and 0 late frames**,
      90 frames in 3.03s.

**Exit criteria:** recreate a typical CapCut-style edit (text callouts, transitions, a filtered
look, one slow-mo moment) entirely in vdodtor.

---

## M4 — "It ships" (export, gating, packaging)

### Export
- [x] Export path through the same compositor, frame-counter clock → VideoToolbox encode
- [x] MP4 faststart; H.264 + HEVC (muxed as `hvc1`, not `hev1`); AAC-LC 48 kHz stereo
- [x] Presets with estimated output size; disk-space preflight; cancel leaves no partial files
- [x] Background export with progress
      **The whole feature is one sentence: preview and export differ in the clock
      and in nothing else.** Playback works out what time it is — from the audio
      device, or from the wall when there is no sound — and renders that; an
      export counts frames and asks for those. Both arrive at the same two
      functions, `vd_engine_render_at` and `vd_audio_renderer_render_at`, which
      are the clip list, the decoders, the compositor, the envelopes and the
      filters that were already there, with a position handed in instead of
      read off a clock. Nothing below them can tell which called it. That is
      what the M0 note about "one compositor" was buying, and this is where it
      gets spent: **`vd_export.mm` is 520 lines of encoder and clock, and not
      one of them draws a pixel.**
      Two *instances*, though, not two implementations. The export makes its own
      headless `VdEngine` — no audio device, its own decoders — because it
      renders at its own size and must not drag the playhead around under
      somebody who is still editing. And the output size is the **timeline's**
      own `width`/`height` rather than a field beside it: nothing in a render
      list is measured in pixels, so exporting a 1080p edit at 4K is one number
      changing and no re-layout of anything. There is deliberately no second
      place to write a resolution down.
      The encoder is AVFoundation, which is VideoToolbox's hardware H.264 and
      HEVC behind a muxer the rest of the world can open. FFmpeg is on the way
      *in* and Apple's is on the way out, and that is not an inconsistency: the
      vendored FFmpeg is LGPL and must stay that way, and an H.264 encoder is
      exactly the part of it that would not be.
      Three decisions inside it are worth the ink. **The encoder pulls; it is
      not pushed at.** An input that has had enough stops being ready, and what
      makes it ready again is the machinery behind
      `requestMediaDataWhenReadyOnQueue:`. A loop polling
      `isReadyForMoreMediaData` looks like it works — the picture alone writes
      to the end of a film that way — and then wedges permanently the first time
      a second input is added, which is exactly what happened here and cost an
      afternoon. Video and audio get a queue each and the writer interleaves
      them. **Every frame is copied** into one of the encoder's own buffers,
      because the compositor publishes into a single pixel buffer it draws the
      next frame straight over, and an encoder holds what it is handed until it
      has finished with it; appending the compositor's own buffer would have
      VideoToolbox reading frame 41 out of memory frame 42 was being written
      into, which would present as occasional tearing under load and look like a
      driver problem for a week. And **the sound is clipped to 16 bits here**
      rather than handed over as float: summing lanes can leave a sample past
      ±1, and deciding what happens to it in one place means the clipping is the
      same clipping every time and the one a meter would have shown.
      The output is tagged Rec.709 explicitly, because the compositor works in
      709 whatever the sources were coded in and an untagged SD-sized export is
      read back as 601 by half the players in the world. HEVC comes out as
      `hvc1` and not `hev1` — the same bitstream with the parameter sets
      somewhere else, and only the first opens in QuickTime, Safari and most
      hardware players, so a file tagged `hev1` is one that works everywhere the
      developer tested and nowhere the user needs it. The test asserts on the
      bytes of the file for both that and faststart, which is `moov` before
      `mdat`.
      **A cancelled or failed export leaves no file.** Half a video plays, looks
      finished, and is missing its ending, which is the part nobody checks — so
      the partial file is removed rather than left to be found, and destroying a
      running export cancels it first. The sheet in front of it offers four
      sizes (the project's own, 720p, 1080p, 4K — sized by the **short** side, so
      a 9:16 project at "1080p" is 1080 across and not 1080 tall), two codecs,
      and a switch for the sound, and says in one line what the four of them add
      up to: dimensions, bitrate, frame count and about how many bytes. The
      bitrate under that picker is the bitrate the encoder writes at, because
      `vd_export_default_bitrate` and `defaultVideoBitrate` are one function in
      two languages with one table asserted in both suites — the
      `vd_time.c`/`time.dart` arrangement, for the reason the audio envelopes
      have it. The disk is checked *after* the save panel and not before, since
      the free space that matters is on the volume the user picked.
      Measured in `vd_export_test.c`: a two-second timeline comes back out of
      `vd_probe` as 320x240 h264 + aac at 48 kHz stereo, 60 frames, `moov`
      before `mdat`; the HEVC pass finds `hvc1` and no `hev1`; a flat green
      fixture decodes back to the luma level that colour has in Rec.709, which
      is the parity claim made on pixels rather than on prose; a clip at gain 0
      comes back silent and the same clip at gain 1 does not, which is what says
      the *mixer* filled the file rather than a bypass around it; and a cancelled
      export leaves nothing on disk.
      And measured in the running app, on the self-test project with everything
      the M3 passes put on it — footage, a caption with a typewriter on it, a
      shape, a looping sticker on an overlay lane and a transition across a cut:
      **257 frames of 1920x1080 written in 2.55s, 3.4x faster than real time**,
      in a *debug* build where the engine itself is compiled at -O0. The file
      reads back through `vd_probe` as 1920x1080 h264 + aac, 8.57s — the length
      the timeline is. The preview engine was up the whole time and still
      renders afterwards with its five decoders open, which is the part no
      offline test can reach: an export and a preview are two engines, two
      compositors and two sets of decoders over one set of files.
      One number is worth reading carefully. The estimate said 7.0 MB and the
      file is 4.0 MB, because the estimate is a *target* bitrate times a length
      and VideoToolbox's average-bitrate control spends well under target on
      easy content — and the self-test project is flat colours and captions,
      which is about as easy as content gets. That is the direction the number
      should be wrong in: both its readers are a disk check and a warning, and
      both would rather be told 7 and get 4 than the other way round.
- [x] Preview/export parity: golden-frame tests through both drivers in CI
      The sentence above is a claim, and `engine/tests/vd_parity_test.c` is where
      it stops being one. One timeline goes through both clocks — the preview's
      `vd_engine_render_at` and the export's frame counter — and the two are
      compared to **one committed picture each** rather than to each other,
      because two drivers that broke the same way would agree perfectly. A
      reference belongs to the driver that owns it: the preview approves these
      goldens and the export is measured against them, since the preview is what
      the user was looking at when they decided the edit was finished.
      The scene is chosen for what only the *engine* resolves per frame — a
      transition window worked out from a cut, an animation evaluated from an
      offset into a clip's life, a look found by name — because a static picture
      would notice none of it, and those are exactly the places two clocks can
      drift. Three ticks: before the transition opens, halfway through the
      dissolve, and past it with the incoming shot graded and wearing its look.
      The same timeline is also exported at twice the size and compared against
      the preview at that size, which is the assertion the 4K-from-1080p path
      rests on.
      The tolerance is the interesting part. A frame that went through H.264 and
      4:2:0 and back cannot equal one that went to memory, and a bound on the
      worst pixel would have to be enormous to be stable — chroma is stored at
      half resolution, so every hard colour edge is reconstructed over two
      pixels and lands tens of counts out along that seam. So the bound is on
      the *proportion* of pixels past a sensible figure, and on the mean, and
      neither would do alone: measured, the scenes come back at 1.0–2.0% of
      pixels past twenty counts with a mean under 0.92, and the same scenes a
      single frame out of step come back at 2.7–12.0% with a mean of 2.9 to 6.6.
      A frame of drift across a *cut* moves almost every pixel a little and the
      mean notices; a frame of drift inside a dissolve barely moves the outlier
      count, because the blends either side of it are nearly the same picture.
      Both bounds are checked, and the gap between 0.92 and 2.9 is where the
      file lives.
      **Nothing in these goldens draws a glyph or a curve**, which is the same
      exemption `vd_text_test.c` argues for: Core Text and Core Graphics are
      tuned in macOS releases, and a reference PNG of a sentence would go red on
      an upgrade while the renderer was still correct. The caption gets the
      parity check it can actually keep. The typewriter is the one animation
      that is not a transform — it reaches into the raster, so the cache is
      keyed on revealed characters, and the preview arrives at a tick by seeking
      while the export arrives by counting — so the two drivers are compared to
      *each other* on where the ink is, at three points through the reveal, plus
      an assertion that the ink was growing so that agreement could have failed.
      The harness is now `engine/tests/vd_golden.h`, shared by both files: there
      is one reference set and two sets of scenes over it, and the failure output
      says which driver disagreed and leaves its frame and an amplified
      difference in `build/engine/tests/golden-failures/`, which CI already
      uploads. Re-approve with
      `VD_UPDATE_GOLDENS=1 ctest --test-dir build/engine -R 'golden|parity'`.

### Free / Pro
- [x] Resolution gate: 1080p free, 4K+ Pro — no watermark anywhere, ever
      Everything the brief sells is in one predicate — `ExportPlan.isPermitted` — and
      the interesting part is what it is measured on. **The gate is on the pixels
      leaving the machine, not on which chip is lit.** 4K is not the only way to ask
      for 4K: "same as project" on a project that was cut at 4K is the same file, so a
      gate attached to the picker would have exactly one hole in it and that hole would
      be the default selection. It is `outputFormat.isAboveFreeTier`, once, and there
      is no second place to get it wrong.
      **The tier changes what may be written and never what is written.** No watermark,
      no shortened export, no quieter encode, no silent downscale — a file that came
      out smaller than the one that was asked for is worse than a refusal, because
      nobody re-checks the dimensions of a render they watched finish. `timelineFor`
      and `settings` do not mention the tier and the test asserts that the two tiers
      hand the engine the same render list, the same bitrate and the same settings.
      That is the closest a test can get to "no watermark, ever": the free path and the
      paid path are the same path, and the tier is a yes or a no on the way to it.
      The engine never hears about any of this. `vd_export` takes a width and a height
      and writes them; what a person is allowed to ask for is a product decision, and
      it lives in the app where the sheet that asks the question is.
      Two decisions about the sheet. **It opens on the biggest size it can actually
      write** — a free installation with a 4K project opens on 1080p, not on a locked
      button, because the first thing anybody sees being a refusal is the upsell-first
      behaviour this product exists in opposition to. Nothing is hidden and nothing is
      substituted behind their back: the project's own size is one chip away wearing a
      badge, and the line under the picker always says the size that will be written.
      And **a locked chip is still selectable**: pressing 4K shows exactly what 4K
      would produce — 3840 × 2160, 25 Mbps, 60 frames, about 6.4 MB — and the refusal
      is on the button underneath. Somebody deciding whether to buy Pro should be able
      to see what they would be buying. The gate panel says the other half out loud,
      which is the sentence that matters most in a product positioned against the
      watermark-and-account editors: up to 1080p stays free, every track, every effect,
      and no watermark on anything, ever.
      `Entitlement` is a `ChangeNotifier` and not a value read once, because buying Pro
      happens *while the sheet is open* — it is the sheet that told them they needed it
      — so the gate lifts under them, keeping the 4K they had chosen, rather than
      waiting to be closed and reopened. Nothing in the shipping app calls `grant` yet:
      that is the seam the next item plugs into, and until it does every installation
      is free, which is the honest default. An editor that let 4K through because the
      licence check had not been written would be one that had to start refusing later.
- [x] Licensing: Paddle or Lemon Squeezy checkout; offline-friendly license validation;
      restore/deactivate flow
      **A licence key is a signed sentence, and the signature is the whole of the
      check.** `VDO1.<payload>.<signature>`: a few lines of `name value` text
      naming the order, the buyer, the tier and — for a subscription — the date it
      runs out, with an Ed25519 signature over them. Verifying it is arithmetic on
      the bytes in front of it. No server is contacted, no account exists to sign
      into, and the editor works exactly the same on a plane as it does on a
      desk — which is not an optimisation but the product: the brief sells an
      editor with no account, and one that had to ask permission before letting
      somebody export would have an account whatever the sign-up screen said.
      **Why public-key and not a code.** Anything symmetric — a hash of the buyer's
      email, an HMAC, a serial with a checksum — ships the secret that mints keys
      inside the app that checks them, so the first person to look can print their
      own. Public-key signing is the only arrangement in which the thing that
      *verifies* a licence cannot *write* one, and that asymmetry is the entire
      feature. `app/lib/pro/ed25519.dart` is RFC 8032 in 260 lines over `BigInt`,
      with SHA-512 beside it; both are pinned by the RFC's own vectors and by one
      this repository generated with OpenSSL, and the tamper test flips every one
      of a signature's 64 bytes rather than the first. It is written rather than
      depended on because a package in the path between somebody paying and being
      let in is a third party who can break that path, and because a pure-Dart
      check is one `flutter test` can reach — which is what gives the whole flow
      tests at all, and what will give the Windows port the same ones.
      Two decisions inside the format are worth the ink. **The signature covers the
      bytes that arrived, and parsing happens afterwards** — verifying a
      *re-encoding* would mean a licence stopped working the day the writer changed
      how it spaced a field, and it would let a line this build cannot read change
      what was checked. So a key written by a later fulfilment tool, carrying
      something this build has never heard of, still opens it. And **the consequence
      to design around is that a licence cannot be revoked**: whatever is signed is
      true forever on every machine. So it says as little as possible — no device
      count, because a number nobody can check only inconveniences the people who
      paid.
      **Checkout is an address we own, not the shop's.** The button opens
      `vdodtor.app/pro`, which redirects to whichever hosted checkout we are running;
      Paddle and Lemon Squeezy are both merchants of record and either can be behind
      it, or both, or neither in five years. A build from 2026 has to keep working in
      2031, and a provider's checkout URL baked into it is the part most likely to
      have been retired by then. That is the whole of this item's "Paddle or Lemon
      Squeezy": the app has no opinion, and switching never needs a new build.
      **Restore and deactivate are what they can honestly be with no server.** The
      licence is one file in Application Support holding the key exactly as it was
      pasted — not the keychain, because a receipt is a thing people should be able
      to find and copy out for their next machine, and not obfuscated, because
      patching the tier in a hex editor is quicker than any scrambling would be to
      write. Restore is the key itself: the app reads it at launch, and
      `vdodtor.app/licence` finds it again by the email it was bought with. Deactivate
      removes it from *this* Mac and says out loud that doing so does not use it up —
      it is for a machine being sold, and a deactivation that read like a cancellation
      would stop people doing the thing that is actually safe.
      Two smaller ones. A lapsed subscription is **kept, not deleted**: "your
      subscription ended on the 3rd of February" is an answer where "you are on the
      free tier" is a shrug, and there is a fortnight of grace after the date because
      a renewal receipt arriving on Tuesday must not stop an export on Monday night.
      And the tier is settled **once**, at launch — an editor that took Pro away
      mid-export to enforce a date that passed while somebody was working would be
      doing the one thing this product promises not to.
      `app/tool/licence.dart` is the fulfilment side — `keygen`, `sign`, `check` — and
      it shares `lib/pro/licence.dart` with the app rather than reimplementing the
      format, so a key it prints is one the app can read by construction; it refuses
      to print one the verifier rejects, because the first failure would otherwise be
      somebody's receipt. It is why `Tier` moved into its own file: the tool runs
      under plain `dart run`, where `dart:ui` does not exist.
      **The build says out loud that it trusts a key anybody can sign for.** The
      signing key shipped today is a development one whose private half is in
      `app/tool/licence_dev_key.txt`, which is correct while nothing is being sold and
      is what lets the tests mint licences without a secret in the source tree. The
      licence sheet carries a warning for exactly as long as that is true, and it
      disappears by itself when the constant is replaced — see the Packaging item
      below.
- [~] Pro content packs plumbing (LUTs, transitions, templates, fonts)
      The plumbing is in and carries two of the four kinds. **A pack is a signed
      file**, `.vdpack`: a manifest saying what it is, what it costs and what it
      contains, the files themselves, and an Ed25519 signature over the lot.
      `app/lib/media/packs.dart` reads the packs the app ships and the packs
      somebody installed through exactly the same function, so the one built into
      this DMG and the one downloaded in 2031 arrive the same way. The shipped one
      is **Cinema** — five looks generated by `tools/make_luts.dart` from formulae
      in that file, on the same terms as the free five, because a look sold without
      an account has to be one we may sell.
      **The rule the whole feature turns on: a locked item changes what may be
      *chosen*, never what is *drawn*.** Every pack registers with the engine at
      launch whatever the tier says, so a project graded while somebody had Pro
      goes on rendering exactly as it did after a subscription lapses, on a machine
      that never had one, and in an export years later. The gate is in the picker
      and nowhere else. Refusing to register locked content would mean a finished
      film changing when a card expired, which is the same argument as "no
      watermark, ever" and as `ExportPlan.isPermitted`'s "the tier changes what may
      be written and never what is written".
      Locked looks are **listed**, badged, and selectable — pressing one opens the
      Pro sheet instead of grading the clip — which is the export sheet's decision
      about a locked size applied to content: somebody deciding whether to buy Pro
      should be able to see what is in it. And the pack sits on a free machine with
      its name and its summary on the Pro sheet, because hiding it until after the
      purchase would mean asking somebody to buy a list of names.
      **Why a pack is signed when a licence key already is.** These are different
      questions. The tier decides who may *use* content and is about money; the
      signature decides whose bytes reach a *parser* and is not. A `.cube` goes
      through forty lines of our own arithmetic in `vd_lut.c`, but a pack can carry
      a typeface, and a typeface goes to Core Text — "download this file and drop it
      on the editor" is exactly the shape of the trick you would use to reach a font
      parser. The signed container is what is *stored*, too, and re-read at every
      launch, so a pack edited on disk a year after it was installed is caught
      rather than trusted. The user's own single `.cube` route is untouched: one
      file, one format we wrote the reader for, no signature.
      Measured in the running app, on a **free** installation with no licence: ten
      looks offered, five of them from the pack, all ten rendered at two strengths
      each — which is the "never what is drawn" rule as pictures rather than prose.
      Eleven cube uploads for ten looks, and the extra one is worth reading: the
      compositor keeps eight lattices resident, so sweeping the whole catalogue
      evicts the first before the last frame asks for it again. That bound is sized
      for how many looks can be on screen *together*, which is still comfortably
      under it; auditioning more than eight in a row costs one upload each time you
      go back, and an upload is a few hundred kilobytes. Worth knowing before pack
      three.
      **What is not carried, and why.** *Transitions* cannot be, because a
      transition is a `VdTransitionPreset` — an index into code in
      `vd_transition.c`, not a file — so a pack could only name one that already
      exists; carrying a new one means giving transitions parameters first, which is
      engine work rather than plumbing. *Templates* cannot be, because there is
      nothing to carry: a template would be a project file used as a starting point,
      and "new from template" does not exist yet. Both are named in the comment on
      `PackContentKind` so the next person reads why, and both are one appended enum
      value away — it crosses no boundary and is stored nowhere.

### Packaging
- [ ] Replace the development licence signing key before the first signed build
      `dart run tool/licence.dart keygen`, paste the public half into
      `vdodtorSigningKey` in `app/lib/pro/licence.dart`, and put the private half in
      the fulfilment webhook's secret store — never in this repository. Until then
      every build trusts the key in `app/tool/licence_dev_key.txt`, which anybody can
      sign with; the licence sheet says so on screen while that is the case, and stops
      the moment the constant changes. Shipping without doing this gives Pro away to
      anybody who reads GitHub.
      **Every shipped content pack must be re-signed with the same key in the same
      change**, because packs are verified against that one constant: a release build
      with a new key and an old `.vdpack` would refuse its own bundled content and
      quietly show five fewer looks. `dart run tools/make_luts.dart` then
      `dart run tool/pack.dart build --from ../build/packs/cinema --key <seed>
      --out assets/packs/cinema.vdpack`.
      `tools/package_mac.sh` **refuses to run** while this is outstanding, so the
      ordering is mechanical rather than a note: `--allow-development-key` is the
      way to get a DMG for yourself, and it prints a warning when you use it.
- [~] Signed + notarized DMG — **the pipeline is in and everything but the two calls
      to Apple has been run.** `tools/package_mac.sh` builds, checks, signs, verifies
      and stamps out a disk image; what is left is one run with a Developer ID
      Application certificate and a `notarytool` profile, neither of which exists on
      the development machine yet.
      **Signing is a script and not a checklist** because three of its steps are
      things a person forgets exactly once. Sign the nested FFmpeg dylibs *before*
      the framework that contains them — sign them after and the framework's seal is
      already broken. Give the outer app the entitlements and the inner code none —
      a framework carrying its own copy of the sandbox entitlement is how "the app is
      not sandboxed after all" happens. And check that what got embedded is what the
      licence notice says got embedded. All three fail late, at a stranger's
      Gatekeeper prompt or in an obligation nobody re-reads.
      So it **refuses more than it does**: a third-party notice that no longer
      describes the vendored libraries, a dylib in the bundle that is not the one
      `build_ffmpeg.sh` built, a binary linked against `/opt/homebrew`, a build that
      still trusts the development licence key — each stops the run. The embedded
      libraries are compared on **LC_UUID**, one per slice, because a dylib is signed
      three times on its way into a bundle and every signature changes the bytes
      while the code stays identical; the UUID is what the linker stamped in.
      Notarization is **two submissions**, which is not waste. The ticket for the app
      is fetched by the hash of the app, and stapling it changes the app — so the
      image has to be built again around the stapled copy and notarized on its own
      account. What that buys is an app in `/Applications` that verifies with no
      network long after the disk image it arrived in was thrown away.
      **Found by doing this: the release build had never been signable.**
      `flutter build macos --release` failed on `master` with "code object is not
      signed at all", naming the engine framework. The cause was two levels down: on
      Apple Silicon the linker ad-hoc signs the arm64 slice it produces and leaves
      the cross-built x86_64 one bare, so `lipo -create` yields a universal dylib
      that `codesign -dvv` calls signed — it reports the native slice — and that
      `codesign --sign` refuses when it recurses into a framework containing it.
      `tools/build_ffmpeg.sh` now signs each universal file after lipo and verifies
      **both** slices. Every debug run worked throughout, which is why it had gone
      unnoticed.
      `--adhoc` is for a build to look at, and it is signed **without** the hardened
      runtime — the one place it differs from a real one. The hardened runtime turns
      on library validation, which requires every framework a process maps to carry
      the same Team ID, and an ad-hoc signature has no team at all: the app dies in
      `dyld` before it draws a window. A Developer ID gives everything one team and
      the problem does not exist. The alternative would be shipping
      `com.apple.security.cs.disable-library-validation`, which is turning off the
      thing the hardened runtime is for so that a test build launches.
      **The LGPL obligations are discharged here**, and this is the item that closes
      them. `tools/make_notices.dart` writes `app/assets/notices/` — what is in
      vdodtor that we did not write, on what terms, from which tarball, at which
      checksum, with the exact `configure` line, and how to build a replacement
      library and drop it in — from the files actually vendored, in the same
      arrangement `tools/make_luts.dart` has with the looks. It is **generated**
      because a notice hand-edited beside a re-vendored library says 7.1 over a
      9.0.1, and `app/test/app/about_test.dart` compares every number in the shipped
      file against `third_party/ffmpeg/BUILD_INFO.txt` so that staleness is red
      rather than silent. The notice and the licence text ship as **assets**, shown
      by the About sheet on the chooser, because §6 wants the user given prominent
      notice and a disk image is a thing people throw away the day they mount it;
      the same two files go into the image as well, beside the OFL licences, because
      somebody deciding whether to install should not have to install first.
      **And the volume wears the app's icon.** The DMG window is the first thing a
      stranger sees of vdodtor — before the app has ever been launched — and a
      generic white disk beside an `/Applications` alias is the look of a download
      nobody vouched for. `.VolumeIcon.icns` is **copied out of the built bundle**,
      at the name `CFBundleIconFile` gives, rather than made again: there is then one
      place an icon comes from and no way for the two to drift, which is the same
      argument as generating the icon in the first place, one step further along.
      Two things needed and neither enough alone — the file at the volume root and
      `kHasCustomIcon` on the root's Finder info — and the flag is why the image is
      now built read/write, marked and *then* compressed: the flag lives on a volume
      root, which does not exist until there is a volume, and `hdiutil` does not
      carry the staging folder's own attributes across. It is set with `xattr` rather
      than `SetFile -a C`, which is the same 32 bytes: `SetFile` has been deprecated
      for years and comes from Xcode, and a packaging script that stops working on an
      Xcode upgrade fails on release day. Everything survives the compress, which was
      checked rather than assumed.
- [x] Update channel — **decided: there is no updater, and that is the feature**
      Split off the DMG item because it was a different question: an editor whose
      pitch is "no account, fully offline" has to decide what it is willing to ask
      the network for. The answer is nothing. vdodtor ships with **no
      `com.apple.security.network.client` entitlement**, so it cannot open a socket
      at all, and "Check for updates…" in the About sheet opens `vdodtor.app/download`
      in the **browser** — which needs no entitlement, because it is the browser doing
      the asking.
      **Why that is worth more than a notification.** A sandboxed app with no network
      entitlement is *verifiably* incapable of sending anything anywhere: anybody can
      check it in ten seconds with `codesign -d --entitlements`, where a privacy policy
      is a claim they have to take on faith. The positioning table names CapCut's
      "ByteDance baggage" as a weakness to exploit, and the exploit is not a better
      promise — it is a promise somebody else can verify. Telling people about a point
      release is not worth giving that up, and a signed appcast is also a feed we would
      have to keep serving for as long as any build is alive.
      **What it costs, said out loud rather than discovered.** Nobody is ever notified,
      so people stay on the version they installed until they come back to the site. So
      the sheet *says* there is no updater — an app that never mentions a new version is
      unusual enough that silence reads as an updater that is broken — and the version
      line is selectable, because with no updater the version number is a thing people
      have to read out into a bug report.
      Two tests hold it: `app/test/app/about_test.dart` asserts `Release.entitlements`
      grants no network, and scans `lib/` for `HttpClient`, `WebSocket` and friends. The
      second is the useful one — a socket added here fails inside the sandbox, which is
      a user's bug report rather than a red test, and outside it, under `flutter run`, it
      would appear to work perfectly.
- [x] Crash reporting — **opt-in, and the opting in is a person pressing paste**
      Analytics: **none**, which resolves the "none-or-anonymous" this line used to offer
      a choice between. Both answers fall out of the update-channel item above rather
      than being decided again: vdodtor has no `com.apple.security.network.client`
      entitlement, so every design that begins "the app uploads a report" or "the app
      counts a launch" is unavailable before it is evaluated, and even an anonymous
      counter would cost the one claim `codesign -d --entitlements` can settle in ten
      seconds.
      So a Dart fault is written to a text file in Application Support, the chooser
      offers it at the **next** launch, and the About sheet grows a third tab showing it
      verbatim with Copy, Delete, and a button to the bug page in the browser. That is
      opt-in in the strongest form the word has: the usual version is a checkbox beside a
      server, and it asks the user to believe the box does what it says; here the consent
      *is* the paste.
      **The redaction is the part that needed work, and it runs before the write.**
      Absolute paths become `<path>`, keeping the extension — `<path>.mov` — because the
      diagnostic value of a path in a crash is almost always "it was a `.mov`", and
      everything else in it is the user's account name, their folder layout and the names
      of their footage. `package:` and `dart:` URIs survive untouched, which is what
      keeps a stack trace worth reading, and it falls out of a path having to begin at a
      boundary. Scrubbing on the way to the *disk* rather than on the way to the *screen*
      is deliberate: there is then no unscrubbed copy anywhere for anything later to
      find. `app/test/app/crash_test.dart` holds the whole rule as a table, and the rows
      that keep something are as load-bearing as the rows that remove something — a
      redactor that ate the stack trace would be perfectly private and perfectly useless.
      **What it cannot see, said out loud rather than left to be discovered.** A signal in
      the C engine kills the process before Dart gets another turn, and macOS writes that
      one to `~/Library/Logs/DiagnosticReports`, which a sandboxed app is not granted. So
      the sheet says where those live instead of pretending the list is complete — and
      the project half of a hard exit was already covered from the other end by the
      session marker, which offers the project back.
      `about_test.dart` gains the analytics half of the no-network guard: no telemetry
      SDK may be a **dependency**, because a crash-reporting package brings its own
      socket, its own background upload and its own opinion about what counts as
      anonymous, and none of that appears in the existing grep of `lib/` for
      `HttpClient`.
      **Found by doing this — by the reporter itself, on its first run in the real app.**
      Opening the sheet marks the offer seen, the chooser's banner listens to the same
      notifier, and a dialog's `initState` runs inside the build that pushes its route,
      so the first thing the new crash reporter ever recorded was a `setState() called
      during build` caused by the new crash reporter. It is why `record` never notifies
      at all — it runs inside `FlutterError.onError`, in the middle of a frame that is
      already failing — and why `markSeen` from the sheet is deferred to after the frame.
      The regression test lives in `start_screen_test.dart` rather than beside either
      piece, because it only appears when the banner and the sheet are in one tree.

**Exit criteria:** a stranger can download the DMG, edit a video, hit the 4K gate,
buy Pro, and export 4K — with no help.

---

## M5 — Launch

- [x] Resolve OQ-4: name/branding final; icon; website with direct download
      **The name ships, the icon is drawn, and the site is in this repository.**
      The icon is **generated, not vendored**, which is `tools/make_luts.dart`'s
      argument arriving at the last asset that had escaped it. A `.png` exported
      from a design tool cannot be re-rendered at a size Apple adds next year,
      cannot be re-tinted when `VdColors` moves, and has its source on somebody's
      machine rather than in the repository. `tools/make_icon.dart` holds the
      geometry, writes every file `AppIcon.appiconset/Contents.json` names plus
      the two the site wears, and `app/test/app/icon_test.dart` draws it again
      and compares — `about_test.dart`'s rule pointed at a picture.
      **The mark is the app's own timeline**: three clip bars in the colours
      `VdColors` paints tracks with, cut under the playhead, drawn as
      `TimelinePainter._paintPlayhead` draws it. So the icon is a picture of what
      the product *is* — multi-track — rather than a play triangle, which would
      fit every competitor in the brief's positioning table equally well. The
      hues are the timeline's own one step brighter, because `VdColors` is muted
      on purpose to sit beside footage and an icon is seen at 32 px against a
      Finder window where muted reads as grey; the playhead alone is
      `VdColors.playhead` **exactly**, since the one thing in this product
      allowed to be loud should be the same loud everywhere.
      **It is three drawings, not one scaled.** One geometry taken down to 16 px
      is Apple's own "don't" and it is right: the 40-unit cut is a third of a
      pixel there, so the detail is not lost, it is *noise*. Under 64 px the
      overlay lane and the cut go; under 32 px the playhead's head goes too, its
      line roughly doubles, the shape grows to fill nearly the whole canvas and
      the drop shadow is dropped.
      Two things written rather than depended on, both for
      `lib/pro/ed25519.dart`'s reason: a sixty-line **PNG writer**, and a
      **rasteriser** in which a shape is an inside-test and a bounding box,
      area-sampled with the sample count rising as the icon shrinks — so a small
      icon is the exact area-average of the design without ever allocating a
      large one, and every shape is antialiased by construction. The whole set
      renders in 1.6 s.
      **The disk image wears the same icon**, copied out of the built bundle at
      the name `CFBundleIconFile` gives rather than made again. The flag that
      makes a volume use it lives on the *volume root*, which does not exist
      until there is a volume, so `package_mac.sh` builds read/write, marks it
      with `xattr` and compresses afterwards. `SetFile -a C` writes the same 32
      bytes and was not used: it is deprecated and comes from Xcode, and a
      packaging script that breaks on an Xcode upgrade breaks on release day.
      **The site is in `site/`, and it is there for a reason that is not
      marketing.** The app hard-codes six addresses — `/`, `/download`, `/pro`,
      `/licence`, `/bugs`, `/source` — into a build that **can never update
      itself**, on purpose. There is no remote config, no phone-home and no
      socket, so a page renamed on the site is a dead button in every copy ever
      installed, permanently; and `Checkout.buy` is the worst of them, because it
      fails at exactly the moment somebody had decided to pay. That makes the app
      and the site two sides of one boundary that has to agree, which is the
      `vd_time.c`/`time.dart` arrangement pointed at hyperlinks —
      `app/test/app/site_test.dart` reads `lib/` for every `vdodtor.app` address
      and fails if the site has no page for it, so the drift is red rather than
      discovered by a stranger. It also checks the site's internal links, that
      the download page offers the version `pubspec.yaml` would build, and that
      every page has a title, a description, a language and a viewport.
      **Plain static HTML, no build step and no framework** — six pages, one
      stylesheet in the app's own palette, and `<page>/index.html` so every host
      serves `/download` with no rewrite rule. Two files are *not* written by
      hand: `site/source/` carries the **byte-identical** notice and LGPL text
      the app ships, because the shipped notice names `vdodtor.app/source` as
      where the source is kept, and a page restating a licence obligation in its
      own words is the one kind of duplicate worth going to trouble to avoid.
      `tools/make_notices.dart` writes both places and the test compares them.
      The landing page also carries the "no watermark video editor for Mac"
      wording OQ-5 asks for, so that page exists rather than being a launch task.
      What is left of OQ-4 is **nothing in this repository** — a domain and a
      host, which are the first two entries under "What is left" above.
- [x] First-run experience: bundled sample project + 60-second tour
      **An editor's first window is the hardest one.** Nothing is on the
      timeline, so nothing on screen does anything, every control is greyed out,
      and the advice "drop some footage on it" assumes the user already has
      some to hand. So the chooser offers a **sample project** beside New
      Project — a fifteen-second edit that is already cut, already graded and
      already has words on it — and the first editor window this machine ever
      opens runs a **six-stop tour** over the real panels.
      **The footage is generated, not vendored**, which is
      `tools/make_luts.dart`'s argument about the looks applied to media: what
      ships inside a product sold without an account has to be something we may
      sell, and stock footage almost never is. `tools/make_sample.sh` writes
      three gradient shots and a chord bed with the ffmpeg CLI, the way
      `engine/tests/media/generate.sh` already writes the probe fixtures. They
      total under 800 KB — a gradient is the most compressible picture there
      is, which is the other half of why they are gradients, and they are the
      shots a *look* reads most clearly on.
      **The project is code, not a `.vdo` asset.** A shipped project file would
      carry absolute paths that are wrong on every machine but the one that
      wrote it, and would go stale the moment the document format moved —
      silently, because nothing reads a sample project until a stranger opens
      it. Built from the model it is exactly as current as the model is. The
      consequence worth saying out loud: this is **not** a template system. A
      template is a project file used as a starting point, which is the thing
      `PackContentKind` names and defers, and building the mechanism now for one
      template would be a mechanism with no second user.
      The footage is **copied** into `<library>/Sample Media` — the decision
      `BundledLooks.install` already makes for a user's own `.cube`, and here
      for a harder reason: a file inside the app bundle is readable but cannot
      be **bookmarked at all**, so a project pointing into the bundle is one the
      importer could never mint a scope for. In the library it is granted whole
      by entitlement and behaves exactly like the user's own footage, which is
      the point — the sample must not be a special case the rest of the app
      knows about. It is imported through the real importer and the real probe
      for the same reason, and asking again reopens **theirs** rather than
      making "Sample project 2": somebody who spent ten minutes re-cutting it
      wants their version back.
      **The tour points at the real panels rather than at pictures of them**,
      from the top of the editor's own `Stack` rather than from a route: a
      dialog would put a barrier between the card and the thing it is talking
      about, and the editor underneath stays live, so pressing space during the
      first stop plays the film — which is that stop's own instruction working.
      Six stops at about ten seconds each, and every one says something the
      editor cannot say by looking like itself: which lane is magnetic, that
      there is no import dialog to go and find, that 1080p carries no watermark,
      that the app cannot open a socket. The hole is **re-measured after every
      frame**, because the things being pointed at move for reasons the tour
      cannot see — a resized window, an engine that finishes starting and
      replaces a spinner with a preview, a lane that appears — and a highlight
      left behind the thing it highlights is worse than no highlight. Skipping
      and finishing are the **same outcome**: both mean "do not show this
      again", and a product that reads Skip as unfinished business shows the
      tour twice. It is offered once per machine, marked by a file under
      Application Support, and reachable afterwards from the shortcut sheet —
      the surface that is already "how does this work".
      Found by doing this: `CallbackShortcuts` handles keys that *bubble
      through* it, so the focused node has to be one of its descendants. Wrapped
      the other way round the bindings sit above the node the event starts at
      and never see it; Escape and Enter silently did nothing, and only the
      widget test said so.
      Measured in the running app, on the sample as a stranger gets it: 1920x1080
      at 30, three shots, five lanes, four files, 15.00s — **30.0 fps, 1.7 ms
      GPU, four layers, three decoders, no audio underruns, and across three
      seconds of playback zero text rasters and zero LUT uploads.** The five
      frames the arrangement was designed around are all right: the title in
      Anton over a rule with the strapline in Inter under it, the middle of the
      dissolve, the middle shot with Teal & Orange at 0.65 on it and its
      neighbours ungraded, a hard-edged wipe at exactly half, and the closing
      line in Playfair Display. Exported at **6.0x realtime** with the preview
      still alive. `VD_SELFTEST=sample` is the pass that says so, and it is the
      one pass in `lib/dev/self_test.dart` that **edits nothing** — every other
      builds a timeline in order to measure the engine under it, and this one is
      handed the timeline a stranger gets.
- [~] **Publish `site/` at vdodtor.app** — the deploy is in; what is left is the
      domain. **Until it resolves every address in the shipped app is dead**,
      including the buy button, and there is no way to fix that afterwards in a
      copy already installed.
      `.github/workflows/site.yml` uploads `site/` to **GitHub Pages** on every
      push to `master` that touches it, and on demand. It is the one workflow
      here that runs on a **GitHub-hosted** runner: CI needs the self-hosted Mac
      because a green build has to mean what a local build means, but the site
      has no build step at all, and making the buy button wait on a registered
      runner would be inventing a dependency. `configure-pages` is there only for
      `enablement`, which turns Pages on through the API, so the first deploy
      needs nobody to visit a settings screen either.
      **The domain is written down twice and asserted once.** `site/CNAME` is
      where the host reads it; a string compiled into the app is where the app
      reads it; and `site_test.dart` makes them the same, because deploying
      under the wrong name breaks every button in every installed copy exactly
      as renaming a page would. It is also why a `github.io` project page is not
      a fallback worth having: every link, the stylesheet and both icons are
      **absolute**, so the site works at the root of a domain and nowhere else —
      served under `/vdodtor/` it is eight unstyled pages linking to nothing.
      Chosen over Netlify and Cloudflare Pages for one reason: the repository is
      already here, so it adds no account, no vendor and no second place to look
      when a page does not appear.
      Rehearsed locally against `site/` served as a root — all six addresses the
      app opens return their page, `/download` and its four neighbours through
      the trailing-slash redirect every static host issues, and the notices and
      both icons resolve. What is left for the owner: buy `vdodtor.app`, point
      an `ALIAS`/`A` record at GitHub Pages, and check the six live URLs once —
      `site_test.dart` proves the pages exist, and nothing but a request proves
      a host serves them.
- [ ] **Wire the checkout behind `/pro`** — needs OQ-2 (pricing) and a merchant
      account. Then `site/pro/index.html` becomes a redirect to the hosted
      checkout, and the fulfilment webhook mints keys with
      `dart run tool/licence.dart sign`. The app never learns any of this: it
      opens an address we own, which is the whole reason `Checkout.buy` is not
      the provider's URL.
- [ ] **Cut the first release** so the download button resolves — needs the
      signed DMG (Packaging, above), then a GitHub release tagged `v<version>`
      carrying `vdodtor-<version>.dmg`. `site_test.dart` already makes the page
      offer the version `app/pubspec.yaml` would build.
- [ ] Private beta; fix the top reported issues
- [ ] Launch: Product Hunt, r/videoediting, YouTube reviewer outreach
      (the "no watermark video editor" SEO page is `site/index.html`, done above,
      which resolves OQ-5's page half; where the first 1,000 come from is still open)

**Exit criteria:** v1.0 public; first-1,000-users plan in motion.

---

## M6 — fast-follow (post-v1)

The brief's fast-follow list, in the order §4 writes it. Open-ended by design:
v1 has shipped, and what lands here is what the first thousand users ask for.

### Chroma key

- [x] **`vd_key`: what a matte means, as arithmetic** — the third grading
      module, and a different kind of thing from the two beside it. `vd_color`
      is every affine operation on RGB, which is exactly why five sliders fold
      into one matrix; `vd_lut` is the arbitrary map left over, which is why it
      arrives as a lattice. A key changes **whether a pixel is there**, not
      what colour it is, so it is neither — it gets its own module, its own
      document object and its own inspector section rather than four more
      fields on `ClipColor`.
      It takes the same bargain as the two beside it: what a key *means* is
      plain C with no GPU in the room, asserted on numbers, and what is left in
      Metal is a distance and a mix that a test could tell you nothing about.
      Not mirrored in Dart, for `vd_anim`'s reason — nothing in the app draws a
      matte.
      **The key runs on chroma divided by brightness, and the second half of
      that is a correction to what this plan said before the work started.**
      Distance in RGB makes the matte a function of how brightly that corner of
      the screen was lit: the shadow on the cyclorama stays and the subject's
      lit shoulder goes. Converting both the pixel and the key colour to
      (Cb, Cr) with the BT.709 weights `vd_color.h` already declares is the
      usual answer, and it is **only half of one** — Cb and Cr are
      *differences*, so they shrink with the picture. A screen at a third of
      the key light's brightness sits a third of the way in towards grey, which
      is further from the sampled green than most of the subject is. Every
      simple keyer has that failure, and it is why they all want a perfectly
      evenly lit screen. The first version of this file did exactly that and
      its own test caught it: the fixture's screen falls off by half across the
      frame, and only the lit end keyed.
      Dividing the chroma through by the pixel's own luma removes it — in a
      gamma-encoded signal a shadow is still very nearly a uniform scaling of
      all three channels, because a power law takes a scale to a scale. Then
      the distance is divided by the key's own, which is what makes
      **`tolerance` the fraction of the way from the key colour to grey**: 0 at
      the colour, 1 at grey, and the same number on a blue screen as on a green
      one. Without that last division the slider would mean two different
      things, because blue carries a fifth of green's luma and its coordinates
      are an order of magnitude larger.
      The weights are BT.709 and not the source's own `kr`/`kb`, for the reason
      saturation already uses them: by then the picture is RGB, and it is the
      *project's* idea of hue that has to decide, or two cameras key to two
      different greens.
      **Smoothstep and not a linear ramp.** A linear one leaves a corner where
      the matte meets solid, and that corner reads as a bright line drawn
      around the subject — which is the one artefact everybody recognises as
      "badly keyed".
      **The despill runs on the same axis, and holds the level.** Subtracting
      the pixel's projection onto the key's own chroma direction is what makes
      one space pay for both halves of the feature; doing it in chroma with Y
      untouched is `vd_color`'s "a white balance keeps its level" pointed at a
      despill. Pulling green out by taking it off the green *channel* darkens
      every edge pixel it touches, which trades a green halo for a grey one.
      **A zeroed `VdChromaKey` is no key twice over**: tolerance 0 means
      nothing is within 0 of the key colour, and the zeroed colour is black,
      which is grey, which has no hue to be near at all. `vd_key_is_off` short
      circuits the shader on the terms `graded` and `lut_size` already have, so
      an unkeyed fragment takes the arithmetic it took before this existed and
      **no golden frame moves**. That is an assertion, not a hope.
      **And the key is measured on the shot as it was shot**, before the five
      sliders and before the look. The other order makes every control in the
      COLOUR panel above it secretly a keying control — turn up the contrast
      and the matte closes, drag saturation and the fringe comes back. The
      despill runs there too, so what the grade is handed is a corrected plate.
- [x] **The key reaches the compositor, and a keyed layer contains** —
      `VdLayer::key` beside `VdLayer::color` and `VdLayer::look`, per layer for
      the reason a grade is per layer: a key on the *frame* would key the
      caption over the shot as well. It reaches the premultiplied layers too —
      a still, a sticker on a white card — undone and redone around the alpha
      exactly as `vd_grade_premultiplied` does it, with the matte multiplied
      into the alpha that was already there.
      **The one interaction that has to be decided is blur fill.**
      `ClipTransform.fit` defaults to `blurFill`, so a green-screen clip
      dropped into a project of a different aspect fills its own bars with a
      blurred copy of the green — the exact opposite of the ask — and worse,
      the backdrop offscreen is cleared *opaque*, so the holes in it would then
      be painted black over the lane underneath, which is the failure
      `draw_full_frame`'s `hide` comment already describes once. Filling a bar
      with a blurred copy of a picture you have just declared is not there is a
      contradiction, so **the compositor reads `VD_FIT_BLUR` as
      `VD_FIT_CONTAIN` for a keyed layer**. A rendering rule and not a document
      change: nothing rewrites the fit the user chose.
      One detail the test found that the plan had not. The substitution has to
      happen **before `compute_fit`**, not only at the `wants_blur` check —
      `VD_FIT_BLUR` is not `VD_FIT_CONTAIN` to that function, so a keyed layer
      that merely skipped the three blur passes was still laid out as *cover*.
      The plate covered the pillars it was supposed to leave alone, and the
      lane beneath showed nowhere.
- [x] **`ClipKey`, and no toggle** — colour, tolerance, softness and spill on
      the document, and `tolerance` *is* the on switch: nothing is within 0 of
      the key colour, so a key at 0 keys nothing and there is no second flag
      that can disagree with it. `ClipKey.withColor` brings the tolerance back
      up when a colour is picked, which is `ClipColor.withLook`'s rule verbatim
      — a colour chosen after the slider was dragged to nothing would appear to
      do nothing. `ClipKey.none` writes nothing at all to the file, so every
      project written before this existed round-trips byte for byte.
      The section is offered on `showsPicture && !clip.isGenerated`, which is
      exactly where COLOUR is offered and for the same reason: a key on a
      rectangle somebody just chose the colour of is a control fighting the one
      above it. It sits **under** the grade, because that is the order the
      engine runs them in, and a panel in the other order teaches the wrong
      habit — the argument that already puts the look under the five sliders.
      Two decisions the sliders themselves make. `softness` and `spill` open at
      15% and 100% rather than at zero, because a key with no softness is cut
      out with scissors and one with no despill leaves the green on the
      subject's shoulder: a key opening on zeros would be wrong in the two ways
      somebody would then have to go and find the controls for. And the three
      sliders appear only once there is a colour, on the look strength's rule —
      a tolerance under no colour is a control that does nothing.
- [x] **The eyedropper, and what it picks** — the control that decides whether
      the feature is usable at all. Finding a screen's exact green by dragging
      a colour field is the part of chroma key everybody gives up on.
      `vd_engine_pick_color(engine, u, v)` renders the current position once
      with **the grade, the look and the key all suppressed**, and that
      suppression is the whole point: the green has to be picked as the camera
      recorded it, or a grade applied afterwards moves the key out from under
      itself — and with a key already on, there is no green left to point at.
      It **averages a small patch rather than reading one pixel**, because one
      pixel of a 4:2:0-compressed screen is noise and a key built on a noisy
      sample needs a wider tolerance than the screen deserves. And it
      **renders normally again before returning**: the pick render publishes
      into the preview texture, and a paused editor would otherwise sit showing
      an ungraded frame until the next edit.
      The Flutter half turned out smaller than it looked. The preview already
      lives inside an `AspectRatio` of the project's own format with the
      texture filling it, so a tap maps to normalised output coordinates by one
      division and no fit arithmetic at all, and the `Stack` the tour hangs off
      is where the picking overlay goes. **Escape cancels a pick before it
      clears the selection** — the eyedropper is the more recent thing the user
      started, and clearing the selection would take away the panel they
      started it from.
      It picks what is *visible*, which is deliberate and worth writing down:
      somebody points at the screen they can see, so a colour belonging to an
      overlay on a lane above is what comes back when that is what is under the
      cursor. The self-test pass found that by pointing at the middle of a
      frame with three earlier passes' overlays stacked in it.
- [x] **The matte view, and where a view mode lives** — white where the picture
      is kept, black where it has gone: the fastest way to see what a tolerance
      is actually doing.
      It is **not** a field on the render list. A view mode is a property of
      the person looking, not of the document, so it goes on the engine beside
      the only other two things that are not the document — the clock and the
      position — as `vd_engine_set_view(engine, VD_VIEW_NORMAL |
      VD_VIEW_MATTE | VD_VIEW_PLAIN)`. That is what keeps "a frame is a pure
      function of (document, time)" true: no project file can record a view
      mode, because it never reaches one. And it keeps "preview and export
      differ in the clock and in nothing else" true by **naming** the second
      difference rather than leaving a hole in it — `vd_export` builds its own
      headless `VdEngine` and never calls this, so a zeroed engine renders
      exactly what the export writes.
      `VD_VIEW_PLAIN` is the eyedropper's render, so one enum pays for both
      features. It crosses the FFI boundary as an index, so it is append only —
      and it is **two** enums to keep in step rather than the usual three,
      because it never reaches the document.
      The toggle is ephemeral app state and **resets when the selection
      changes**. Somebody who leaves it on and comes back later has a
      black-and-white editor, which reads as a broken app rather than as a
      debug view.
- [x] **The tests, and one new fixture** — `vd_key_test.c` pins what a key
      means with no GPU in the room: a green plate keys, a grey key keys
      nothing, tolerance 0 keys nothing, softness 0 is a hard edge, and a
      despill holds Y. `vd_compositor_test.c` pins that the shader agrees with
      it, on a plate built by hand the way the look tests build theirs — the
      arrangement that already keeps `vd_lut_sample` and the texture fetch
      honest. One new golden for a keyed plate over a background, and **every
      existing golden unchanged**, which is the short circuit's proof.
      A `green_screen.mp4` goes into `engine/tests/media/generate.sh` — a
      coloured subject on a green field, a few KB, committed like the rest —
      for the engine and parity tests, because a key that works on a synthetic
      buffer and not on subsampled chroma is a key that does not work. **Its
      screen has a gradient across it**, half the light at the left edge, which
      is more fall-off than a badly lit screen has, and it is the fixture that
      caught the arithmetic above.
      Dart gets the round trip, `withColor`, the command and an inspector
      widget test — and, because `EditorScreen` builds a real `PreviewEngine`
      and cannot be pumped, a read of its source for the two callbacks and the
      Escape handler, which is `tour_test.dart`'s arrangement.
      The parity scene took two goes, and the first is worth recording. It used
      the same test pattern the other parity scenes do and failed by a hair —
      8% of pixels past the threshold against 4% allowed. The diff said why:
      every count was on the *pattern's* own saturated vertical bars, with the
      subject's outline solid black. Perfect agreement on the matte, and a
      scene measuring the encoder rather than the key. Four flat quadrants
      underneath leave the matte as the only hard edge in the frame, which is
      what the scene is for.
      Measured in the running app at 1920x1080: the eyedropper picks `#00c965`
      off a shot whose own colour it is, four tolerances go on the clip, and
      **layers stay flat at 2 and decoders flat at 6** through all of them — a
      slider that reopened the file on every value would stutter the preview
      for the length of the drag. The frame before the pick and the frame after
      it are **byte-identical**, which is the whole of "it leaves the frame as
      it found it"; the keyed frame is black but for the shape on the lane
      above, which is a key belonging to the clip that carries it; and the bars
      turn black at the same moment, which is a keyed layer containing.
- [x] **What is deliberately not in it.** Spatial matte controls — shrink,
      grow, edge blur, a garbage matte — are a second render pass and a
      different feature: a chroma-space key with a despill is what makes a
      green screen work, and the rest is what makes it work *well*, which is a
      decision to take later against real footage. Keyframing the key is the
      fast-follow keyframes item and not this one. And the bin and the timeline
      strip still draw green, because a thumbnail is a picture of the *file*,
      drawn by `vd_thumbnail`, which knows nothing about a clip — right, but
      worth saying out loud rather than leaving to be discovered.

**Exit criteria:** a green-screen clip dropped on an overlay lane, keyed with
one click of the eyedropper, shows the lane underneath through it — in the
preview *and* in the exported file, with the two compared by the parity test
rather than by eye. **Met**, by `parity_keyed`: one keyed timeline through both
clocks against one committed picture. What is left is somebody sitting down
with real footage and deciding whether the defaults are the right defaults,
which is a judgement rather than a test.

---

## Post-v1 (priority order)

1. **Fast-follow features:** ~~chroma key~~ (**done — see M6 above**) · on-device
   auto-captions (stays free) · voiceover recording · keyframes on all transforms ·
   120 fps export · premium pack drops
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
| ~~FFmpeg LGPL compliance in a sold, notarized app~~ | **Retired in M4 packaging.** M1 vendored a universal LGPL 2.1 build, dynamically linked, with a build script that fails rather than emit a GPL or non-free configuration. The rest arrived with `tools/package_mac.sh` and `tools/make_notices.dart`: the nested dylibs are signed inside-out ahead of the frameworks that contain them, and the notice — source URL, checksum, configure line, relink instructions and the §3(b) written offer — ships as an asset the About sheet shows and as a folder in the disk image. What is left is running the notarized build once, which is the packaging item, not this risk |
| Preview/export parity drift | One compositor + golden-frame CI from M2, parity tests in M4 |
| Solo-dev scope creep | Milestone exit criteria are the guardrails; anything not in the brief goes to Post-v1 |
