# 🖱️ native_mouse_cursor — example

An interactive showcase for [`native_mouse_cursor`](../). Hover each card to see
a **real OS mouse cursor** built from your own glyph.

## ▶️ Run it

```bash
cd example
flutter run -d macos     # or: -d chrome / windows / linux
```

> Use a device with a pointer (desktop, or web in a desktop browser). On
> iOS/iPadOS the OS manages its own pointer, so custom cursors aren't possible
> there — the app still runs, it just uses the system pointer.

## 🧩 What it demonstrates

| Card | Shows | API |
| --- | --- | --- |
| **Rotation** | An arrow that rotates to aim at the centre dot as you move. | `get(id, angle:)` |
| **Mirroring** | Move between quadrants — the glyph mirrors. | `get(id, flipX:, flipY:)` |
| **Hotspot** | A red dot marks the true pointer position — see it on the tip vs the glyph centre. | `hotspot:` |
| **Baked drop shadow** | The same glyph with a baked shadow vs none. | `shadow:` |
| **Cursor sources** | The four ways to register a glyph, side by side. | `svg` / `image` / `draw` / `builder` |
| **Infinite drag** | Drag the number — it scrubs forever (edge-warp on desktop, Pointer Lock on web incl. Firefox) with a wrapping cursor. | `InfiniteDragRegion` |

It also uses **`NativeMouseCursorMixin`** to auto-configure the bake DPR and
rebuild when a cursor finishes baking, so the demos can call `get` straight from
`build()`.

## 🎛️ The "Force painted overlay" switch

The app-bar switch toggles `NativeMouseCursorOverlay(force: …)`:

- **Off** — the real OS cursor (or the CSS `cursor: url(...)` on web).
- **On** — the cursor is painted **inside Flutter** and the system cursor is
  hidden. This is meaningful on **web** (a perfectly seamless per-region cursor)
  and **desktop** (to preview the painted path).

The chip in the app bar shows the active mode: `Native OS`, `CSS url()`, or
`Overlay`.

## 🗂️ Where to look

- [`lib/main.dart`](lib/main.dart) — registration of every cursor and each demo
  widget.
- [`assets/pointer.svg`](assets/pointer.svg) — the glyph used by the `svg` source.

See the [package README](../README.md) for the full API.
