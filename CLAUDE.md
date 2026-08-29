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

No source code yet — next work is the M0 spikes in PLAN.md. Planned layout:
`app/` (Flutter), `engine/` (C/C++, CMake), `docs/`. There are no build/lint/test commands
to document until that lands; re-run `/init` at that point to replace this section with real ones.

Remote: `https://github.com/iChintanSoni/vdodtor.git` (branch `master`, also the main branch).
