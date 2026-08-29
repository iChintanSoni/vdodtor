# vdodtor — Product Brief

**v2 (from scratch) · 2026-08-29 · Owner: Chintan Soni**

Supersedes the discarded v0.1 requirements. Every decision below was made explicitly
in the 2026-08-29 brainstorm; unresolved items are collected in §7.

## 1. Vision

An easy-to-use desktop video editor — full multi-track capability without the clutter:
no watermark, no account, no ads, fully offline. **"The Affinity of video editors."**

Target user: people who bounce off DaVinci Resolve (too intimidating) but outgrow
iMovie/Clipchamp (too basic), and resent Filmora/CapCut (upsells, watermarks, accounts).

## 2. Platform roadmap

| Priority | Platform | Plan |
|---|---|---|
| 1 | **Desktop** | macOS v1 (dev machine, paying indie audience), Windows fast-follow |
| 2 | **Web** | Likely a lite funnel (trim / captions / 720p export → desktop download), not full parity |
| 3 | **Mobile** | Later; Flutter UI and document model carry over |

## 3. Stack

- **UI:** Flutter — desktop now; the same codebase compiles for web and mobile later.
- **Engine:** FFmpeg (LGPL build; hardware encode via VideoToolbox / NVENC / QSV)
  plus a custom GPU compositor, exposed over FFI behind an **engine interface**.
- **Preview:** engine renders into a Flutter external texture.
- **Known, accepted cost:** the web version cannot reuse the FFmpeg engine; it needs a
  second WebCodecs/WebGPU backend implementing the same engine interface.
- Document model is engine-agnostic: a project is a scene graph of tracks/clips/properties;
  a rendered frame is a pure function of (document, time); rational time, no float seconds.

## 4. Features

**MVP**
- Project: aspect ratio (9:16 / 16:9 / 1:1 / 4:5) + frame rate (24/25/30/60) at creation
- 1 sequential (magnetic) main video track + 3 parallel overlay tracks
- 6 audio tracks: volume, fades, keyframed ducking, detach-audio
- Trim / split / move / delete / duplicate · snapping · undo/redo · drag-drop import · keyboard shortcuts
- Animated text (~8 in/out presets)
- Shape primitives (rect, rounded rect, circle, line/arrow) with fill/stroke, sharing text animations
- GIF / animated sticker overlays (GIF, animated WebP, APNG)
- 5 classic transitions (dissolve, slide, wipe, fade-black, fade-white)
- Speed 0.1×–10× with pitch-preserved slow motion
- Color adjust (brightness/contrast/saturation/temp/tint) + LUT filter presets
- Basic audio effects: EQ presets, fade curves
- VFR sources normalized to project timebase; rotation metadata honored
- Export: H.264/HEVC via hardware encoder, faststart MP4, background export

**Fast-follow**
- Chroma key · on-device auto-captions (**stays free** — the anti-CapCut wedge) · voiceover
  recording · keyframes on all transforms · 120 fps export · premium packs · Windows port ·
  proxies for heavy 4K timelines

**Later / maybe never**
- Optical-flow slow-mo · masking & motion tracking · HDR output · collaboration ·
  asset marketplace · full web & mobile apps

## 5. Monetization

- **Free tier:** the complete editor, 1080p export. No watermark, no account, no ads. Ever.
- **Pro (hybrid unlock):** 4K+ export and premium packs (LUTs, transitions, templates, fonts).
  ~$5/mo **or** $49–79 lifetime (desktop buyers expect lifetime; price regionally).
- **Sales channel:** direct (Paddle / Lemon Squeezy — no 30% store cut), with optional
  Mac App Store / Microsoft Store listings for discovery.
- Marketing is built into the model: "no watermark", "no account", "your footage never
  leaves your machine" are the top search phrases and press hooks in this category.

## 6. Positioning snapshot

| Competitor | Weakness exploited |
|---|---|
| DaVinci Resolve | Intimidating for casual editors |
| Premiere | Subscription, pro overkill |
| Filmora | Upsells + watermarked free tier |
| CapCut Desktop | Account required, ByteDance baggage, Pro-creep |
| iMovie / Clipchamp | Too basic; semi-abandoned / cloud-tied |

## 7. Open questions

| ID | Question |
|---|---|
| OQ-1 | Confirm macOS-first (currently assumed — it is the dev machine) |
| OQ-2 | Exact pricing and regional tiers |
| OQ-3 | Web-lite scope, when its turn comes |
| OQ-4 | Name/branding — is "vdodtor" final? |
| OQ-5 | Distribution: where do the first 1,000 users come from? |
| OQ-6 | Minimum OS versions; Linux in or out |
| OQ-7 | Built-in screen recording as a differentiator — in or out |
