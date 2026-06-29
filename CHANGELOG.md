# Changelog

## 1.2.0 (unreleased)

- Add **`InfiniteDragRegion`** — infinite drag in one widget. Wraps any handle
  and picks the right model per target automatically (desktop edge-warp, web
  Pointer Lock), so consumers no longer hand-roll the gesture/lock plumbing.
- **Infinite drag now works on Firefox** (uses a click-to-engage Pointer Lock,
  since Firefox grants a lock only from a `click`; other browsers keep
  press-drag). On web the cursor is painted **wrapping** the viewport while
  locked, instead of vanishing.
- Also public, for painting a custom wrapping cursor: `DragCursorOverlay`,
  `NativeMouseCursor.wrapOverlayCursor`, `InfiniteDragController.wrapPosition`.
- Docs/structure: implementation libraries moved under `lib/src/`, so the
  generated API docs now show only the public `native_mouse_cursor` library.
- Additive — no breaking changes.

## 1.1.0

- Add **infinite drag** support: `InfiniteDragController` plus the
  `NativeMouseCursor.warpPointer` / `canWarpPointer` primitives. Drive an
  unbounded value scrub from your own gesture; works on macOS, Windows, Linux
  (X11 and Wayland) and the web, falling back to a clamped drag elsewhere. See
  [doc/infinite_drag.md](doc/infinite_drag.md).
- Web cursor fix: pre-decode the data-URL cursor bitmaps and skip redundant
  re-applies, fixing the random "cursor didn't load / blank" flashes in Chrome.
- Additive only — no breaking changes.

## 1.0.2

- Add a live web demo (GitHub Pages) plus a demo GIF, live-demo link, and
  `screenshots:` entry so it shows on pub.dev.
- Add pub.dev `topics:` (cursor, mouse, pointer, ui, desktop) for discoverability.
- Hide implementation-only libraries (`*_web`, `*_method_channel`,
  `*_platform_interface`) from the generated API docs via `dartdoc_options.yaml`.
- No runtime code changes.

## 1.0.1

- Documentation only: tidy the platform-support icons in the README. No code
  changes.

## 1.0.0

🎉 First stable release.

Use any image, SVG, or painted glyph as a **real OS mouse cursor** — drawn by the
OS compositor, so it tracks the pointer with zero lag and a baked shadow never
shimmers. It's a real `MouseCursor`, usable anywhere a `SystemMouseCursors` value
works.

### API

One coherent flow: **register a source under an id, then `get` it.**

- `NativeMouseCursor.configure(devicePixelRatio:, onReady:)` — set the bake DPR
  and a rebuild callback; call again on a DPR change. Or mix in
  `NativeMouseCursorMixin` to wire this up automatically from `build()`.
- `NativeMouseCursor.svg / .image / .draw / .builder(id, …)` — register a glyph
  from an SVG asset, a `ui.Image`, a `CursorPainter`, or a custom per-angle
  builder; all share `size`, `shadow` and `hotspot` (centre by default).
- `NativeMouseCursor.get(id, angle:, flipX:, flipY:, fallback:)` — fetch the
  cursor at an angle, optionally mirrored; every `(angle, flip)` variant is baked
  + cached on demand, with the nearest ready variant shown meanwhile. Returns a
  non-null `MouseCursor` — until the bitmap is baked it returns `fallback`
  (default `SystemMouseCursors.basic`), so it drops into `MouseRegion` with no
  `??`.
- `NativeMouseCursor.has(id)` — guard a one-off lazy registration.
- `NativeMouseCursor.dispose(id)` / `disposeAll()` — release native bitmaps.
- `NativeMouseCursorOverlay(force: true)` — an opt-in overlay that paints the
  baked bitmap in-app and hides the system cursor, for a perfectly seamless
  per-region cursor. Meaningful on **web** (and desktop) where the system cursor
  can be hidden; off by default and a transparent pass-through otherwise.

The package owns everything hard behind those calls: loading the glyph, rotation,
the baked `NativeCursorShadow`, automatic bitmap sizing, an angle-keyed cache,
background warming and DPR re-baking.

### Platforms

macOS (`NSCursor`, Swift Package Manager — no CocoaPods), Windows (`HCURSOR`),
Linux (`GdkCursor`), Android (`PointerIcon`, API 24+), Web (CSS `cursor: url(...)`,
128-capped, with an `image-set(… 2x)` high-res variant for HiDPI crispness).
iOS/iPadOS and Android < 24 have no native cursor API, so they use the system
pointer (iPadOS won't let an app hide or replace it).
