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
           access — `lib/pro` — what this installation has paid for, and the signed
           licence that says so — `lib/app` — what this build is, and what went wrong
           on this machine that nobody was told about — and `lib/ui`);
           `assets/fonts` holds the five OFL faces a caption can be set in, and
           `assets/luts` the five .cube looks a clip can wear, and `assets/packs`
           the signed content packs it ships, and `assets/notices` what is in
           vdodtor that we did not write and the licence it is under, and
           `assets/sample` the footage the sample project is cut from;
           `tool/licence.dart` and `tool/pack.dart` are the fulfilment side — keygen,
           sign, check, build — sharing `lib/pro/licence.dart` and `lib/pro/pack.dart`
           with the app, so what they mint is readable by construction
  packages/vdodtor_engine/   FFI plugin — ffigen bindings, the macOS podspec that drives
                             CMake, the preview texture, the open panel / drop target
                             and the one call that opens a URL in the browser
engine/    C engine (CMake): vd_time (tick math), vd_anim (in/out presets),
           vd_transition (how one clip becomes the next),
           vd_color (five grading sliders as one matrix),
           vd_lut (the grade that cannot be one: .cube looks),
           vd_key (the grade that decides whether a pixel is there at all),
           vd_stretch (the sound of a speed: WSOLA, and the tape),
           vd_eq (what a clip sounds like, as a short list of presets),
           vd_probe,
           vd_export (the timeline counted out into an MP4),
           vd_decoder, vd_sticker (GIF/APNG/WebP overlays), vd_compositor (Metal),
           vd_raster (the frame a drawn source draws into), vd_text (Core Text
           captions), vd_shape (rect/ellipse/line/arrow), vd_audio_*,
           vd_engine (transport), vd_thumbnail, vd_peaks
site/      vdodtor.app — six plain static pages (no build step) and one
           stylesheet, serving the addresses the app opens; `source/` carries
           the byte-identical notice and LGPL text the app ships, and `CNAME`
           the domain `.github/workflows/site.yml` publishes them at
tools/     build_ffmpeg.sh — vendors universal LGPL FFmpeg into third_party/ffmpeg
           make_luts.dart  — writes every look from the formulae in it: the built-in
                             five into app/assets/luts, a pack's into build/packs/<id>
                             beside the manifest tool/pack.dart signs
           make_icon.dart  — draws the app icon into the macOS asset catalogue:
                             the timeline as a mark, three levels of detail,
                             its own rasteriser and its own PNG writer
           make_notices.dart — writes app/assets/notices from what is vendored,
                             and copies the same two files into site/source
           make_sample.sh  — writes app/assets/sample: the three shots and the
                             bed the sample project is cut from, generated for
                             make_luts.dart's reason
           package_mac.sh  — build, check, sign, notarize, DMG
```

### Commands

```sh
brew install cmake nasm          # once
tools/build_ffmpeg.sh            # once, ~10 min; required before any engine build

cmake -S engine -B build/engine -DCMAKE_BUILD_TYPE=Release
cmake --build build/engine
ctest --test-dir build/engine --output-on-failure

# after an intentional change to how the picture is drawn, re-approve the golden
# frames — then read `git diff` on the PNGs, which is the actual approval:
VD_UPDATE_GOLDENS=1 ctest --test-dir build/engine -R 'golden|parity'

cd app
flutter pub get && flutter test
dart analyze --fatal-infos lib test tool
flutter run -d macos

# mint a licence for a development build (the private half of the release key is
# not in this repository; this is the development one, and no shipped build may
# trust it — see the first Packaging item in PLAN.md):
dart run tool/licence.dart sign --key <seed from tool/licence_dev_key.txt> \
    --id DEV-0001 --name "Ada Lovelace"
dart run tool/licence.dart check VDO1.…

# rebuild the shipped content pack (needed whenever a look's formula changes, and
# whenever the signing key does — a pack is verified against the same constant):
dart run tools/make_luts.dart                 # from the repo root
cd app && dart run tool/pack.dart build --from ../build/packs/cinema \
    --key <seed> --out assets/packs/cinema.vdpack
dart run tool/pack.dart show assets/packs/cinema.vdpack

# redraw the app icon (needed whenever its geometry or the palette it borrows
# from lib/ui/theme.dart changes; app/test/app/icon_test.dart draws it again and
# compares, so a change made and not run turns that red). It writes the macOS
# asset catalogue *and* the two icons the website wears:
dart run tools/make_icon.dart                 # from the repo root

# the website is plain files — no build step. To look at it, serve site/ as a
# root, because the pages use absolute paths and file:// resolves those to the
# filesystem root:
python3 -m http.server 8000 --bind 127.0.0.1 --directory site

# regenerate the sample project's footage (needed when its palette, its length
# or its frame rate changes; the edit over it lives in
# app/lib/media/sample_project.dart and needs no regenerating at all):
tools/make_sample.sh                          # from the repo root

# what the sample looks like on somebody's first launch, in the running app —
# the one self-test pass that edits nothing:
VD_SELFTEST=sample app/build/macos/Build/Products/Debug/vdodtor.app/Contents/MacOS/vdodtor

# a disk image. --adhoc is a build to look at; a real one needs a Developer ID
# Application certificate and an `xcrun notarytool store-credentials` profile:
tools/package_mac.sh --adhoc                 # from the repo root
tools/package_mac.sh --identity "Developer ID Application: … (TEAMID)" \
    --profile vdodtor

# after re-vendoring FFmpeg, so the licence notice describes what is shipped
# (package_mac.sh refuses to build a DMG if this would change anything):
dart run tools/make_notices.dart

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
  — like `vd_time` and `time.dart`. Change one and you must change the other. The fade
  table has a **column per `FadeCurve`**, in enum order, so a curve inserted in the middle
  of one of the three enums reads the wrong column and the table says so.
- **A fade has a shape, and an EQ is a name.** `FadeCurve` is four ramps that are all 0 at
  0 and 1 at 1 — linear (the default, so every project written before the choice existed
  sounds bit for bit as it did), smooth, equal power and exponential — and the curve is
  **one per clip, not one per fade**: two shapes on one clip is a distinction nobody
  makes. `EqPreset` goes the other way: the document carries only the name and
  `engine/src/vd_eq.c` owns what it means, the arrangement a look and a transition preset
  already have. So the curve **is** mirrored in Dart (the timeline draws a fade through
  `Clip.gainAt`) and the EQ is **not** (nothing draws a response curve) — which is the
  `vd_anim` rule applied twice and landing on opposite sides. A curve with no fade left to
  shape is dropped by `ClipAudio.clampedTo`, which every path that sets a fade or shortens
  a clip runs through: `ClipAnimation`'s rule, that a document records what *happens*
  rather than what was clicked on the way there — and what keeps the file, the document
  and the Reset button from disagreeing about a shape the panel no longer shows.
- **The EQ runs before the envelope, and that is the one ordering decision in the mixer.**
  A filter is linear, so a gain and an EQ commute — but the envelope is a gain that
  *changes*, and running a fade into a biquad has the filter chasing the ramp instead of
  the sound. `mix_at` filters the clip as it was recorded and shapes the result. Both the
  filter and the stretcher are reset wherever the clip re-seeks: a biquad's state is the
  last two samples it saw, and ringing them into material from somewhere else is a click
  at exactly the moment somebody is listening.
- **A volume point is measured in the source, not in the clip.** `VolumePoint.sourceTime`
  is the coordinate `Clip.sourceIn` is in, so a trim slides the clip's window over the
  curve instead of dragging the curve with it, a split needs no dividing, and points
  outside a clip's window are kept rather than swept up. Anything that changes a clip's
  length or window must leave `ClipAudio.points` alone — a retime included, which is why
  a duck on a 2x clip arrives twice as soon on the timeline and still lands on the word
  it was drawn for. A fade is the opposite: measured on the *timeline*, so it stays the
  length it was drawn. Both mappings exist twice — `ClipAudio.gainAt` and `mix_at` — and
  the timeline draws the first: `TimelineController.volumeLine` and the painter's
  envelope both divide and multiply by the rate, so the curve is drawn where it is
  heard.
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
- **Preview and export differ in the clock and in nothing else.** Playback works out
  what time it is — from the audio device, or from the wall when there is no sound — and
  renders that; an export counts frames and asks for those. Both go through
  `vd_engine_render_at` and `vd_audio_renderer_render_at`, which are the same clip list,
  the same decoders, the same compositor, the same envelopes and the same filters with a
  position handed in instead of read off a clock. Nothing below those two functions can
  tell which called it, and that is what makes the frame on screen a promise about the
  frame in the file. Two *instances* though, not two implementations: `vd_export` makes
  its own headless `VdEngine`, because it renders at its own size and must not drag the
  playhead around under somebody who is still editing. The output size is the
  **timeline's** own `width`/`height` — a 4K export of a 1080p edit is one number
  changing, since nothing in a render list is measured in pixels — so there is no second
  place to write a resolution down.
- **The resolution gate is on the pixels, and the tier reaches nothing below it.**
  `ExportPlan.isPermitted` is the whole of free/Pro in the editor, and it is measured on
  `outputFormat.isAboveFreeTier` rather than on which chip is lit: "same as project" on a
  4K project is a 4K file, so a gate attached to the picker would have its one hole at the
  default selection. Above 1080p without Pro, **nothing is written** — no watermark, no
  shortened export, no silent downscale, since a file that came out smaller than the one
  asked for is worse than a refusal. Below it the tier changes nothing whatsoever about
  the file, which is what `timelineFor` and `settings` not mentioning it is the proof of,
  and what `app/test/engine/export_plan_test.dart` asserts by handing both tiers the same
  project and comparing the render lists. The engine never hears about any of it:
  `vd_export` takes a width and a height, and who is allowed to ask for them is a product
  decision that lives in the app. The sheet opens on the biggest size it *can* write —
  a free installation with a 4K project opens on 1080p, not on a locked button — and a
  locked chip is still selectable, so the numbers under it are real and the refusal is on
  the button. `Entitlement` is a `ChangeNotifier` because buying happens while that sheet
  is open — the gate lifts under the user, keeping the 4K they had chosen — and what
  calls `grant` is `Licensing`, which is the next entry.
- **A licence is a signed sentence, and the signature is the whole of the check.**
  `VDO1.<payload>.<signature>`: a few `name value` lines naming the order, the buyer,
  the tier and — for a subscription — its date, under an Ed25519 signature.
  `app/lib/pro/ed25519.dart` is RFC 8032 over `BigInt` with SHA-512 beside it, written
  rather than depended on because a package in the path between somebody paying and
  being let in is a third party who can break it, and because a pure-Dart check is one
  `flutter test` can reach. Symmetric anything — HMAC, a hashed email, a serial with a
  checksum — would ship the secret that mints keys inside the app that checks them;
  public-key signing is the only arrangement where the verifier cannot also write one.
  **The signature covers the bytes that arrived and parsing happens afterwards**, so a
  key carrying a field this build has never heard of still opens it and a change to how
  the writer spaces a line cannot invalidate a licence already sold. And because
  nothing can ever be revoked — whatever is signed is true forever on every machine —
  the payload says as little as possible: no device count, because a number nobody can
  check only inconveniences the people who paid.
- **The tier is settled once, at launch, and the engine never hears about any of it.**
  `Licensing` reads the licence, decides, and grants a `Tier` to the `Entitlement`
  widgets listen to; nothing below that line knows a licence exists, which is what
  keeps `ExportPlan.isPermitted` the one predicate. Nothing re-checks while the app
  runs: taking Pro away mid-export to enforce a date that passed while somebody was
  working is the one thing this product promises not to do. `Tier` lives in its own
  file with no Flutter import so `app/tool/licence.dart` can build payloads with the
  same enum the app reads them back with, under plain `dart run` where `dart:ui` does
  not exist.
- **The checkout is an address we own, and the licence file is one the user can read.**
  The button opens `vdodtor.app/pro`, which redirects to whichever hosted checkout is
  current — Paddle, Lemon Squeezy, both, neither in five years — so switching provider
  never needs a new build, and a 2026 build still sells in 2031. The licence itself is
  one file in Application Support holding the key verbatim: not the keychain, because a
  receipt should be findable and copyable onto the next machine, and not obfuscated,
  because patching the tier in a hex editor is quicker than any scrambling would be to
  write. Deactivating removes it from *this* Mac and does not use it up, and the sheet
  says so — a deactivation that reads like a cancellation stops people doing the safe
  thing. A lapsed licence is kept rather than deleted, with a fortnight of grace, so
  the sheet can say whose subscription ended and when.
- **The signing key that ships today is a development one, and the app says so.**
  Its private half is in `app/tool/licence_dev_key.txt`, which is correct while nothing
  is sold and is what lets the tests mint licences with no secret in the tree. The
  licence sheet carries a warning for exactly as long as `isDevelopmentSigningKey` is
  true and stops by itself when the constant is replaced — the swap is the first item
  under Packaging in PLAN.md, and forgetting it gives Pro away to anybody who reads
  GitHub.
- **A content pack is a signed file, and a locked item changes what may be *chosen*,
  never what is *drawn*.** `.vdpack` is a manifest — what it is, what it costs, what it
  contains — plus the files and an Ed25519 signature over the lot; `lib/media/packs.dart`
  reads the packs the app ships and the packs somebody installed through one function, so
  the built-in Cinema pack and a download from 2031 arrive the same way. Every pack
  registers with the engine at launch **whatever the tier says**, so a project graded
  while somebody had Pro renders identically after a subscription lapses, on a machine
  that never had one, and in an export years later. The gate is in the picker and nowhere
  else — `ExportPlan.isPermitted`'s rule applied to content, and for the same reason: a
  finished film must not change when a card expires. Locked looks are listed and badged
  and pressing one opens the Pro sheet, because somebody deciding whether to buy should
  see what is in it.
- **A pack is signed for a different reason than a licence is.** The tier decides who may
  *use* content, which is about money. The signature decides whose bytes reach a
  *parser*, which is not: a `.cube` goes through forty lines of our own arithmetic in
  `vd_lut.c`, but a pack can carry a typeface and a typeface goes to Core Text. The
  **signed container is what is stored**, not its unpacked contents, and it is re-read at
  every launch — loose files on disk are files anybody can replace. A user's own single
  `.cube` still loads unsigned, which is the line: one file, one format we wrote the
  reader for. Ids and file names inside a manifest become a directory and a file under
  Application Support, so both are checked against a pattern rather than trusted.
- **A pack carries looks and faces, and that is all it can carry today.** A transition is
  a `VdTransitionPreset` — an index into `vd_transition.c`, not a file — so a pack could
  only name one that exists; carrying a new one means parameterising transitions first. A
  template would be a project file used as a starting point, and "new from template" does
  not exist. `PackContentKind` says both out loud in a comment and gains a value when
  either arrives: it crosses no boundary and is stored nowhere, so appending is free.
- **The licence notice is generated, and it is compared to what actually shipped.**
  `tools/make_notices.dart` writes `app/assets/notices/` out of
  `third_party/ffmpeg/BUILD_INFO.txt` and the `OFL-*.txt` files — version, source URL,
  checksum, the whole `configure` line, how to build a replacement library and drop it
  in, and the LGPL 2.1 §3(b) written offer. Generated for `make_luts.dart`'s reason
  turned up one notch: a notice hand-edited beside a re-vendored library says 7.1 over
  a 9.0.1, and a licence obligation described inaccurately is the one kind of staleness
  worse than a crash. `app/test/app/about_test.dart` reads the *shipped* file and the
  vendored one and makes them agree, the way `vd_lut_test.c` reads the shipped cubes.
  It is an **asset** rather than a file beside the DMG, and `showAboutSheet` is on the
  chooser rather than in the editor bar: LGPL 2.1 §6 wants the user given prominent
  notice, a disk image is a thing people throw away the day they mount it, and the
  chooser is the window every launch starts in. The same two files go into the image as
  well, because somebody deciding whether to install should not have to install first.
- **The icon is drawn, and it is a picture of the timeline.** `tools/make_icon.dart`
  holds the geometry and writes every file `AppIcon.appiconset/Contents.json` names;
  `app/test/app/icon_test.dart` draws it again and compares **pixels**, not bytes,
  because what ships is the picture and the bytes around it are whatever deflate
  produced for the zlib in whichever SDK ran the generator. That is `make_luts.dart`'s
  "generated, not vendored" reaching the last asset that had escaped it — a `.png`
  exported from a design tool cannot be re-rendered at a size Apple adds next year, nor
  re-tinted when `VdColors` moves. The mark is three clip bars in the timeline's own
  track colours, cut under the playhead, drawn as `TimelinePainter._paintPlayhead` draws
  it; the hues are one step brighter than `VdColors` because those are muted to sit
  beside footage and an icon is seen at 32 px on a Finder window, but the playhead is
  `VdColors.playhead` **exactly** — the one loud thing in the product is the same loud
  everywhere. And it is **three drawings rather than one scaled**: under 64 px the
  overlay lane and the cut go, under 32 px the head and the shadow go and the line
  doubles. A 40-unit cut is a third of a pixel at 16 px, where detail is not lost but
  becomes noise. The **disk image wears the same icon**, copied out of the built
  bundle at the name `CFBundleIconFile` gives rather than made again, so there is one
  place an icon comes from; the flag that makes a volume use it lives on the volume
  root, which is why `package_mac.sh` now builds read/write, marks it and compresses
  afterwards.
- **A trackpad is not a wheel, and macOS sends neither what you would guess.** A
  discrete wheel notch arrives as a `PointerScrollEvent`; a two-finger swipe carries an
  `NSEvent` phase, so the embedder sends `PointerPanZoomStart/Update/End` instead — a
  `Listener` handling only `onPointerSignal` hears nothing at all, which is how the
  timeline came to be pannable with a mouse and not with the trackpad of the machine it
  was written on. **The signs are opposite**: the embedder negates a wheel's delta and
  not a pan's, because a pan is a *drag* and a drag subtracts from a scroll offset where
  a wheel delta adds to it. And macOS **drops the inertia events** once the fingers lift
  — "the framework will generate scroll momentum", which `Scrollable` does from drag
  velocity and a bare `Listener` does not — so momentum is ours to run, on a
  `FrictionSimulation` off a second ticker, stopped by any gesture that starts. Two
  further traps: `localPan` is transformed as a *position*, so it arrives with the
  widget's own place in the window added and every horizontal swipe measures as
  vertical — accumulate `localPanDelta`, which transforms as a vector — and the axis
  must be **locked once per gesture**, because both axes carry real numbers and picking
  the larger one per event makes a drifting hand stutter. `TimelineView` is the only
  place any of this lives; a widget test that synthesises a mouse proves none of it,
  which is why the trackpad ones use `PointerDeviceKind.trackpad`.
- **Scrolling stops at the end of the film, and the bound is the controller's.**
  `TimelineController` is the only place that knows both numbers it takes — how long the
  project is, and how wide the window is — so `TimelineGeometry` cannot enforce it and
  everything that moves the view goes through `_setGeometry` instead. It is re-applied
  when the *document* moves too: deleting the last clip shortens the film under a view
  that may be looking past the new end. One consequence worth knowing: when the whole
  project fits on screen there is nothing to scroll, so zooming no longer holds the
  playhead still — the film stays left-aligned. The scrollbar is what says there is more
  film than window at all, and its arithmetic is `TimelineGeometry.scrollbarThumb` so the
  thing drawn and the thing dragged cannot disagree.
- **An import makes the lane it needs, whatever the kind.** `MediaImporter.place` used to
  create a missing lane only for overlays, on the reasoning that a new project already
  has a main and an audio lane — true the day it was written, and false the moment
  somebody presses the × every lane but the main one carries. An audio file imported into
  a project with no audio lane went into the bin, left the timeline untouched, and said
  nothing. The lane goes in **with the clip as one command**, so undoing the import
  cannot strand an empty lane, and the one remaining way to be unplaceable — every lane
  of the kind existing and locked — is reported through `ImportResult.unplaced`, which is
  deliberately not a `failures` entry: the file *is* in the project and can be dragged out
  of the bin, so calling it a failed import would be wrong in the other direction.
- **The site is in this repository because the app cannot be updated.** vdodtor
  hard-codes six `vdodtor.app` addresses — `/`, `/download`, `/pro`, `/licence`,
  `/bugs`, `/source` — into a build with no updater, no remote config and no socket, so
  a page renamed on the site is a dead button in every copy ever installed, permanently;
  `Checkout.buy` is the worst of them, since it fails at the moment somebody decided to
  pay. That makes the app and the site two sides of one boundary that must agree, which
  is the `vd_time.c`/`time.dart` arrangement pointed at hyperlinks:
  `app/test/app/site_test.dart` reads `lib/` for every such address and fails if the
  site has no `<path>/index.html`, checks the site's own internal links, and makes the
  download page offer the version `pubspec.yaml` would build. `site/source/` holds the
  **byte-identical** notice and LGPL text the app ships rather than a retelling — the
  shipped notice names that address as where the source is, and a licence obligation
  restated in a second set of words is a second thing that can be wrong. The **domain
  is part of that boundary too**: `site/CNAME` is where the host reads it and a
  compiled-in string is where the app reads it, so `site_test.dart` asserts they are
  the same name — publishing under another one breaks every button exactly as renaming
  a page would. `.github/workflows/site.yml` does the publishing, on a **GitHub-hosted**
  runner rather than the self-hosted Mac CI needs: the site has no build step, and the
  buy button must not wait on a registered runner. Every link, the stylesheet and both
  icons are **absolute**, so the site is only correct at the root of a domain — under a
  `github.io` project subpath it is eight unstyled pages linking to nothing.
- **The sample project is code, and its footage is copied rather than pointed at.**
  An empty editor teaches nobody anything, so the chooser offers a fifteen-second
  edit beside New Project — but it is **not** a shipped `.vdo`: a project file
  asset would carry absolute paths wrong on every machine but the one that wrote
  it and would go stale, silently, the moment the document model moved.
  `lib/media/sample_project.dart` builds it from the model through the **real
  importer and the real probe**, so it is exactly as current as the model is and
  it is a project somebody could have made. That is `make_luts.dart`'s "generated,
  not vendored" applied to a document, and `tools/make_sample.sh` applies the same
  rule to the footage for the harder reason: what ships inside a product sold
  without an account has to be something we may sell. The files are **copied into
  `<library>/Sample Media`** — the decision `BundledLooks.install` makes for a
  user's own `.cube`, and here because a file inside the app bundle is readable
  and **cannot be bookmarked at all**, so a project pointing into the bundle is
  one no scope could ever be minted for. Asking for the sample again reopens
  *theirs*: a button that quietly made "Sample project 2" would shelve somebody's
  work without deleting it. And it is deliberately not a template *system* — a
  template is what `PackContentKind` defers, and one template is a mechanism with
  no second user.
- **The tour points at the real panels, and it is offered once.** `lib/ui/tour.dart`
  sits at the top of the editor's own `Stack` rather than in a route, because a
  dialog would put a barrier between the card and the thing it describes — and
  because the editor underneath stays live, so pressing space during the first
  stop plays the film, which is that stop's own instruction working. The hole is
  **re-measured after every frame**: the things being pointed at move for reasons
  the tour cannot see (a resized window, an engine that finishes starting and
  replaces a spinner with a preview, a lane that appears), and a highlight left
  behind the thing it highlights is worse than none. `TourAnchors` is a record so
  a stop naming an anchor nobody declared is a compile error; that it is
  *attached* is checked by reading `editor_screen.dart`, because that widget
  builds a real `PreviewEngine` and cannot be pumped in a widget test. Skipping
  and finishing are the same outcome — both mean "do not show this again" — and
  `CallbackShortcuts` goes **outside** the `Focus`, not inside it: it handles keys
  that bubble *through* it, so the focused node has to be a descendant.
- **A crash report is written, never sent, and scrubbed on the way to the disk.**
  The entitlement above decides this one too: nothing can upload a report and nothing
  can count a launch, so `lib/app/crash.dart` writes a Dart fault to a file in
  Application Support, the chooser offers it at the **next** launch, and the About
  sheet's third tab shows it verbatim with Copy beside it. That is the strongest form
  of opt-in available — there is no server to consent to and the consent *is* the
  paste — and it is also the whole of the analytics answer: none, because an anonymous
  counter would cost the claim in the entry below. `CrashReport.redact` replaces
  absolute paths with `<path>` **before the file is written**, keeping the extension
  (`<path>.mov`) because that is the diagnostic half and the rest is the user's account
  name and the names of their footage; `package:` and `dart:` URIs survive, which is
  what keeps a stack trace worth reading. Scrubbing before the write rather than before
  the display is the point: there is then no unscrubbed copy for anything later to
  find. A signal in the C engine is *not* in here — it kills the process before Dart
  gets a turn, and macOS puts it somewhere the sandbox cannot read — so the sheet says
  where it lives instead. And `record` **never notifies**: it runs inside
  `FlutterError.onError`, in the middle of a frame that is already failing, and a
  repaint scheduled from there is a second failure on top of the first. That is not a
  theory — it is what the reporter caught about itself on its first run.
- **The app cannot open a socket, and that is a feature rather than a gap.** There is
  no `com.apple.security.network.client` entitlement in `Release.entitlements`, so
  nothing in vdodtor can reach the network — including an updater, which is why there
  isn't one. `About.download` and `Checkout.buy` are opened in the **browser** through
  `SystemLinks.open`, which needs no entitlement because it is the browser doing the
  asking. The point is that the promise is *checkable*: `codesign -d --entitlements`
  settles it in ten seconds, where a privacy policy has to be believed — which is the
  actual exploit against the "ByteDance baggage" line in the brief's positioning table.
  `app/test/app/about_test.dart` asserts the entitlement is absent **and** scans `lib/`
  for `HttpClient`, `WebSocket` and friends; the scan is the useful half, because a
  socket added here fails inside the sandbox as a user's bug report rather than as a red
  test, and under `flutter run` it would appear to work perfectly. The cost is that
  nobody is ever told about a new version, so the About sheet says so outright and the
  version line is selectable for typing into a bug report.
- **A universal dylib has a signature per slice, and `codesign -dvv` only shows you
  one.** On Apple Silicon the linker ad-hoc signs the arm64 binary it produces and
  leaves a cross-built x86_64 one bare, so `lipo -create` yields a file that reports
  itself signed — it reports the native slice — and that `codesign --sign` refuses with
  "code object is not signed at all" when it recurses into a framework holding it. The
  error names the *framework*, two levels up from the cause, and it only appears when
  something signs a bundle: every `flutter run` worked while `flutter build macos
  --release` had never once succeeded. `tools/build_ffmpeg.sh` signs each universal
  file after lipo and verifies `--arch arm64` **and** `--arch x86_64`.
- **Signing is inside out, and the entitlements go on the app alone.** A framework's
  seal covers its contents, so `tools/package_mac.sh` signs the FFmpeg dylibs, then the
  frameworks, then the app — sign them the other way round and the bundle verifies on
  the machine that built it and is refused everywhere else. Nested code gets no
  entitlements: the sandbox belongs to the app, and a framework carrying its own copy is
  how "the app is not sandboxed after all" happens. Embedded libraries are checked
  against the vendored ones on **LC_UUID**, not on bytes or cdhash — a dylib is signed
  three times on its way into a bundle and each signature changes both, while the UUID
  is what the linker stamped in. And `--adhoc` deliberately omits the hardened runtime:
  it turns on library validation, which wants one Team ID across everything a process
  maps, and an ad-hoc signature has no team — the app dies in `dyld` before it draws a
  window. A Developer ID gives everything one team; disabling library validation to
  make a test build launch would be turning off the thing being tested.
- **A cancelled or failed export leaves no file.** Half a video plays, looks finished,
  and is missing its ending, which is the part nobody checks. `vd_export_destroy` removes
  anything that is not a completed export, and destroying a running one cancels it first.
- **The encoder pulls; it is not pushed at.** An `AVAssetWriterInput` that has had enough
  stops being ready, and what makes it ready again is the machinery behind
  `requestMediaDataWhenReadyOnQueue:`. A loop polling `isReadyForMoreMediaData` looks like
  it works — the picture alone will write to the end of a film that way — and then wedges
  permanently the moment a second input is added. Video and audio therefore have a queue
  each, and the writer interleaves them; a thread waiting on two semaphores closes the
  file. And each frame is **copied** into one of the encoder's own buffers, because the
  compositor publishes into a single pixel buffer it draws the next frame straight over,
  and an encoder holds what it is handed until it has finished with it.
- **A bitrate is written twice.** `vd_export_default_bitrate` and `defaultVideoBitrate` in
  `app/lib/engine/export_plan.dart` are one function in two languages with one table
  asserted in both test suites — the `vd_time.c`/`time.dart` arrangement, and here for the
  reason the audio envelopes have it: the encoder writes at this rate and the app *draws*
  it, under the preset picker. A sentence promising 6.2 Mbps over a file written at 3.7 is
  worse than no sentence. The estimated size is **not** mirrored: nothing in the engine
  needs it, so it lives in Dart alone.
- **The compositor is pinned by golden frames, and the two drivers over it are pinned
  to the same references.** `engine/tests/golden/*.png` are whole composited frames
  compared pixel for pixel, so any change to how the picture is drawn turns
  `vd_golden_test` red — including changes that are correct. That is the point:
  re-approve with the command above and look at the image diff. A failing run leaves the
  actual frame and an amplified difference in `build/engine/tests/golden-failures/`.
  `vd_golden_test.c` builds layers by hand and pins the *compositor*;
  `vd_parity_test.c` renders one timeline through both clocks and pins the fact that
  they agree; `vd_golden.h` is the harness both share, because there is one reference
  set and two sets of scenes over it.
- **A reference belongs to one driver, and that is the only one that may approve it.**
  The preview writes the parity goldens and the export is *measured* against them —
  `through` in `vd_golden_check` is what says which job a call is doing — because the
  preview is what the user was looking at when they decided the edit was finished, and
  an export that disagrees is wrong even when it is prettier. The two are never compared
  only to each other: two drivers that broke the same way would agree perfectly, and a
  committed picture is a third party a human approved by looking at it.
- **Parity is measured on a proportion and a mean, never on the worst pixel.** A frame
  that went through H.264 and 4:2:0 and back cannot equal one that went to memory:
  chroma is stored at half resolution, so every hard colour edge is rebuilt over two
  pixels and lands tens of counts out along that seam. A bound on the worst pixel would
  have to be enormous to be stable and would assert nothing. Both of the other two are
  needed and neither would do alone — a frame of drift across a *cut* moves almost every
  pixel a little and the mean notices, and a frame of drift inside a *dissolve* barely
  moves the outlier count because the blends either side of it are nearly the same
  picture. The measured numbers are in `VD_PARITY_THROUGH_AN_ENCODER`; the exports there
  are written at about a hundred times the default bitrate, because every count H.264
  spends is a count of tolerance the test has to give away.
- **The parity goldens draw no glyph and no curve.** Core Text's rasterisation of a
  sentence and Core Graphics' antialiasing of a circle are both tuned in macOS releases,
  so a reference PNG of either goes red on an upgrade while the renderer is still
  correct — the argument at the head of `vd_text_test.c` and `vd_ink.h`, and the reason
  text never joined the goldens. The caption gets the parity check it can keep instead:
  the typewriter is the one animation that reaches into the raster, so the two drivers
  are compared to *each other* on where the ink is at three points through the reveal,
  with an assertion that the ink was growing so the agreement could have failed.
- **The engine analyses peaks; the app owns the peak file.** `vd_peaks_analyze` returns
  a pyramid in memory and knows nothing about where it is kept.
  `app/lib/media/peaks.dart` is the only definition of the on-disk format, so there is
  one parser rather than a C writer and a Dart reader to keep in step. Bump
  `PeakFile.version` for any change to the layout and every cached file is thrown away
  unread, which is the whole migration story a cache needs. Peaks are a property of the
  **file**: volume, fades and mute scale the drawn envelope at paint time, so nothing
  about a clip can invalidate one.
- **A speed is a rate, not a length.** `Clip.duration` stays the clip's length on the
  *timeline* — so `Track.clipAt`'s binary search, magnetic packing, hit testing and split
  all keep one way of asking how long a clip is — and `ClipSpeed.rate` says how fast the
  window travels over the source while it is on screen. The window it implies,
  `Clip.sourceDuration` = `duration * rate`, is derived and never stored: that is what
  makes a clip taken to 4x and back to 1x the clip it started as rather than a sixteenth
  of it, because what a retime holds still is the window. Changing the rate is therefore
  a change of *length*, which is why `SetClipSpeed` is bounded like a trim — no more
  source than the file has, and on a free-form lane no further than the next clip — and
  why the magnetic lane repacks around it. The floor of one frame is the exception and
  bends the other way: growing the length back up at the rate asked for would *widen* the
  window, so it is the **rate** that gives way instead, and a clip with a frame of source
  in it has nothing left to play faster. A source with no length of its own — a sticker,
  a still — has no window to hold still at all, so retiming one changes the rate and
  leaves the clip exactly as long as it was: what speeds up is the loop. `Clip.speed` and
  `VdTimelineClip::speed` carry the rate and never the window: the engine multiplies, in
  `source_time_at` in **both** `vd_engine.c` and `vd_audio_renderer.c`, and those two
  agreeing with `Clip.sourceTimeAt` is the point — a frame and the sound under it
  disagreeing about where in the file they are is the one bug in a video editor everybody
  can hear.
- **Frame duplication for slow motion is not a feature; it is what asking already does.**
  A frame is on screen until the next frame starts, so a source time that has not left
  the current frame's interval comes straight back out of `vd_decoder`'s cache. Four
  project frames at a quarter speed are one decode, and there is no duplication step
  anywhere in the engine because there is nothing to duplicate. The sound is the whole
  cost of the feature: samples cannot be taken at an instant, so twice as many of them
  have to become half as many.
- **`vd_stretch` is that cost, and it is two answers.** WSOLA when the pitch is kept —
  overlapping windows of the source laid down at the output's rate, each slid within a
  15 ms search to wherever it continues the last one best — and a box-filtered resample
  when `pitchShift` is on, which is the tape. A toggle rather than a rule, because a
  slowed shot usually wants the voice in it to still be that voice and a sped-up montage
  usually wants the chipmunk. Plain C with no platform dependency on `vd_color.c`'s
  terms, testable with a sine in an array, and **not mirrored in Dart** for `vd_anim`'s
  reason: nothing in the app draws a stretch. The analysis position advances by a fixed
  `nominal_skip` whatever the overlap search picks, so the offset is a perturbation and
  never an accumulating drift — the output stays exactly `rate` times shorter than the
  input. And speeding up *decimates*, so the resampler averages over the whole span each
  output frame stands for rather than taking the nearest: nearest-neighbour folds
  everything above the new Nyquist back into the audible band as a whistle, and a box of
  `rate` frames has its first null exactly where that whistle would have come from.
- **The mixer tracks the timeline, not the source.** `VdAudioClip::expected_position` is
  a *timeline* position, which it was not before a clip could be retimed: a stretcher
  buffers its own input, so the source position after a chunk sits a window-length ahead
  of where the arithmetic says it should, and comparing the two would re-seek — and reset
  the stretcher — on every chunk of every retimed clip. A clip at 1x keeps no stretcher
  at all, so the common path is bit for bit the path it always was.
- **A grade is five sliders and one matrix.** Brightness, contrast, saturation,
  temperature and tint are all affine on RGB, so `vd_color_transform` composes them
  into one 3x3 and an offset on the CPU and the shader does a single multiply-add.
  That is what keeps the meaning of a grade in plain C, testable with no GPU, the way
  `vd_anim` and `vd_transition` are — and it is the line `vd_lut` sits on the other
  side of: a LUT is the grade that *cannot* be a matrix, which is why it is a
  lookup table.
  Every slider is −1..1 with 0 neutral, so a zeroed `VdColorAdjust` is the ungraded
  shot; the compositor checks `vd_color_is_neutral` first so an ungraded fragment takes
  the arithmetic it took before the feature existed, and the goldens did not move.
  **Not mirrored in Dart**, for `vd_anim`'s reason: nothing in the app draws a grade.
- **Brightness is a gain, and a white balance keeps its level.** Adding a constant
  raises the blacks to grey — the faded look, not "brighter" — so brightness multiplies
  and black stays black. And temperature's channel gains are divided through by the
  BT.709 luma of the white they produce: red weighs three times what blue does, so
  raising one and lowering the other brightens the picture, and a temperature slider
  that does that is an exposure slider the user fights with the brightness one.
  Saturation measures grey with BT.709 weights whatever matrix the source was coded in —
  by then the picture is RGB, and it is the project's idea of grey that matters.
- **A grade belongs to a layer, and reaches every kind of one.** Per frame it would be
  an effect on the *project*: warming a shot would warm the caption over it. On a
  premultiplied layer — caption, shape, sticker — it is undone and redone around the
  alpha rather than applied through it, because the map is affine and pushing alpha
  through the offset row gives a half-transparent pixel half a contrast lift. A
  blur-filled clip's backdrop is graded *once*, inside the offscreen pass and not again
  at the composite, or the bars end up twice as far from neutral as the picture in them.
- **A key is the grade that changes whether a pixel is *there*, and it runs on
  chroma divided by brightness.** `vd_color` is every affine map on RGB, which is why
  five sliders fold into one 3x3; `vd_lut` is the arbitrary map left over, which is why
  it is a lattice. A chroma key is neither and the difference is not one of degree —
  those two decide what colour a pixel is and this one decides whether it is there — so
  it is `vd_key.c`, its own `ClipKey`, its own inspector section, on `vd_color.c`'s
  terms: plain C, no GPU, asserted on numbers, with the shader mirroring it and
  `vd_compositor_test.c` holding the two together.
  **Both halves of "chroma divided by brightness" are needed.** Distance in RGB makes
  the matte a function of how well that corner was lit. Projecting onto (Cb, Cr) is the
  usual answer and only half of one: Cb and Cr are *differences*, so they shrink with
  the picture, and a screen at a third of the key light sits a third of the way in
  towards grey — further from the sampled green than most of the subject is. That is why
  simple keyers need a perfectly lit screen. Dividing by the pixel's own luma removes
  it, because in a gamma-encoded signal a shadow is still a uniform scaling of all three
  channels. Then the distance is divided by the key's own, so **`tolerance` is the
  fraction of the way from the key colour to grey** and means the same thing on a blue
  screen as on a green one — blue carries a fifth of green's luma and its coordinates
  are an order of magnitude larger. The despill runs on the same axis at constant luma,
  because taking green off the green *channel* trades a green halo for a grey one.
  **A zeroed `VdChromaKey` is off twice over** — tolerance 0, and a black key is grey
  with no hue to be near — so the shader short-circuits on `graded`/`lut_size`'s terms
  and no golden frame moved. **And the key is measured before the grade and the look**,
  or every slider in the colour panel is secretly a keying control; the assertion is a
  fully desaturated frame, with no chroma left to key on at all, still keying. **A keyed
  layer contains**: filling its bars with a blurred copy of a background just declared
  absent floods the frame with the colour being removed, and the backdrop's offscreen is
  cleared *opaque*, so the holes would paint black over the lane beneath. The
  substitution has to happen before `compute_fit`, not only at the `wants_blur` test —
  `VD_FIT_BLUR` is not `VD_FIT_CONTAIN` to that function. **Not mirrored in Dart**, for
  `vd_anim`'s reason: nothing in the app draws a matte.
- **A view mode belongs to the person looking, so it lives on the engine.**
  `vd_engine_set_view` sits beside the clock and the position — the only other two things
  the engine owns that the document does not — and never on a clip, so no project file
  can record one because it never reaches one. That is also what keeps "preview and
  export differ in the clock and in nothing else" true rather than approximately true:
  `vd_export` builds its own headless `VdEngine` and never calls it, so the second
  difference is *named* rather than a hole. `VD_VIEW_MATTE` draws every layer's alpha as
  opaque luminance — opaque, because a matte you can see past is not a matte —
  and `VD_VIEW_PLAIN` strips the grade, the look and the key from every layer, which is
  what `vd_engine_pick_color` renders through: the eyedropper has to see the screen as
  the camera recorded it, or a grade applied afterwards moves the key out from under
  itself and a key already on has removed the thing being pointed at. So one enum pays
  for both features, and it is **two** enums to keep in step rather than the usual three.
  The pick averages a 5x5 patch — one pixel of a screen through 4:2:0 is noise — and
  renders normally again before returning, because it publishes into the texture the
  preview is showing. In the app both are ephemeral state on `EditorScreen`: the matte
  view turns itself off when the selection moves, and Escape cancels a pick before it
  clears a selection.
- **A look is the grade that cannot be a matrix, and it runs in the signal.** Every
  slider in `vd_color` is affine, which is why five fold into one 3x3; a split-tone
  pushes shadows one way and highlights the other, and no matrix applies two directions
  to one axis. So it arrives as a lattice: `vd_lut.c` parses a `.cube`, samples it
  trilinearly and bakes the cube the shader fetches — plain C with no GPU in the room,
  on `vd_color.c`'s terms. **Not** in linear light, whatever an older draft of PLAN.md
  said: a `.cube` declares no colour space, and every creative look anybody will load
  was authored against Rec.709 as it comes off the wire — which is what `ycbcr_to_rgb`
  produces and where `vd_color_transform` already works. And it runs **after** the five
  sliders, which is the order a colourist works in and the order the inspector offers
  them in, for the reason temperature already sits above saturation.
- **A look is a name in a catalogue, registered by bytes.** `vd_lut_register` /
  `Looks.register` / `BundledLooks`, the arrangement `vd_text_register_font` and
  `BundledFonts` already have and for the same two reasons: the bundled cubes have no
  path inside a signed bundle, and a project file that named one machine's filesystem
  would only open on that machine. A name nothing was registered under draws ungraded —
  the bargain a caption in a missing face already takes. Nothing is ever unregistered,
  which is what lets `vd_lut_find` hand out a borrowed pointer the render thread keeps.
  A user's own `.cube` is **copied** into `Application Support/vdodtor/Looks` rather
  than linked to: no security-scoped bookmark to mint, nothing to break when they tidy
  up their downloads, and a look is a tool they will want on the next project.
- **The cube is uploaded once, keyed on an id and never on the pointer.** `VdColorLook`
  carries a `id` assigned at parse time; the compositor's eight-slot cache matches on
  it, because a lattice freed and another allocated at the same address would be a cache
  hit on the wrong picture. `VdEngineStats::lut_uploads` is how that is asserted: once
  per look, never during playback and never during a drag on the strength slider.
  It goes up as **RGBA16Unorm** — `RGBA32Float` is not filterable on Apple GPUs, so the
  hardware trilinear the whole design rests on would quietly stop happening and show up
  as banding rather than as an error.
- **`vd_lut.c` parses its own decimals.** `strtof` reads the *locale's* separator and a
  `.cube` always writes a full stop, so under a locale where that separator is a comma
  every value in the file is read as its integer part: the look loads without error and
  renders as garbage. That is a bug that only happens on other people's computers, which
  is exactly the kind worth forty lines to make unreachable.
- **The bundled looks are generated, not vendored.** `tools/make_luts.dart` holds five
  formulae and writes the `.cube` files from them. A look shipped in a product sold
  without an account has to be one we may sell, and the files people share almost never
  are — and thirty lines of arithmetic is something a reviewer can argue with where a
  quarter of a million numbers is not. `engine/tests/vd_lut_test.c` reads the *shipped*
  files, the way `vd_text_test.c` reads the shipped fonts.
- **A transition's overlap is made by the engine, never by the document.** Two clips
  that meet at a cut are butt-joined and non-overlapping in `Track` — `Track.clipAt`
  binary-searches on that, and so do hit testing, split and insert — so the engine
  widens both clips' *drawing* windows across the cut instead: `render_from` and
  `render_to` in `vd_engine.c`, resolved once per edit in `resolve_transitions`.
  Nothing on the timeline moves and the magnetic lane never repacks.
- **"Never fails for lack of media" is the decoder's clamp, reused.** Through its half
  of the window each clip is asked for a source time outside its own trim, and
  `vd_decoder_frame_at` already returns the first frame before the start and the last
  past the end. A cut between two clips trimmed to their very ends still dissolves,
  with a held frame on the side that ran out — no handles, no shortening.
- **A transition is recorded on the incoming clip and names only its own head.** One
  decision, one place: `Clip.transition` / `VdTimelineClip.transition`. The engine
  finds the outgoing clip itself, and `SetClipTransition` clamps the window against
  both neighbours because half of it sits on each side.
- **A dissolve leaves the outgoing clip at full opacity.** With premultiplied
  over-blending, B at alpha t over A *is* B·t + A·(1−t); turning A down as well lets
  the black behind them show through the middle of every dissolve.
- **A fade dips through a layer, not through opacity.** `VdTransitionValue::flash` is a
  solid colour over both clips and under anything on a higher lane, so a caption over a
  fade to black stays legible. Opacity cannot do it: it dips to whatever is *behind*
  the clips — the main track's picture, on an overlay lane — and nothing fades a clip
  to white.
- **`VdLayer::reveal` is a hard edge in the layer's own space, and it is cut at the
  composite.** A blur-filled clip is drawn twice — backdrop into an offscreen texture,
  then composited full-width — and cutting the first leaves the hidden part as opaque
  black which is then painted over everything underneath. `draw_full_frame` takes the
  hide for that reason. Zeroed hides nothing, which is why the goldens never moved.
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
  main, three overlays and eight text lanes; `VD_MAX_LANES` in `vd_engine.c` is their
  sum, and `VD_MAX_LAYERS` is that times three — a lane in the middle of a transition
  draws the clip leaving, the clip arriving and the colour dipped between them. A lane the document allows and the compositor drops is a caption that is on the
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
