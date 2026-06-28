# Infinite drag — technical details

The [`InfiniteDragController`](../lib/infinite_drag.dart) gives an **infinite
drag**: drag a value and it keeps changing forever, because the pointer never
runs out of room. The consumer code is the same on every platform (see the
[README](../README.md)) — this page documents how each platform achieves it under
the hood, and what you need to build it.

## Two strategies

There are only two ways to make a drag "infinite", and the controller picks the
right one per host:

1. **Warp** — when the pointer reaches a window edge, teleport (warp) it to the
   opposite edge. The cursor stays visible and visibly wraps around. Used on
   desktops that allow an app to set the absolute pointer position.
2. **Lock + relative motion** — lock the pointer in place and read an unbounded
   stream of *relative* movement deltas (there are no edges to hit). The cursor
   doesn't move on screen. Used where warping is forbidden (Wayland) or
   impossible (the web).

`NativeMouseCursor.canWarpPointer()` reports which strategy applies:
`true` → warp, `false` → lock. The controller calls it for you.

## Per-platform behaviour

| | Platform | Strategy | Mechanism | Cursor while dragging |
| :---: | --- | --- | --- | --- |
| <img src="platform_icons/apple.svg" width="20" height="20" alt="" align="top"> | **macOS** | Warp | `CGWarpMouseCursorPosition` (+ re-associate) | Visible, wraps. No entitlement needed. |
| <img src="platform_icons/windows.svg" width="20" height="20" alt="" align="top"> | **Windows** | Warp | `SetCursorPos`, mapped by ratio across the physical client rect | Visible, wraps. Correct at fractional DPI (e.g. 250 %). |
| <img src="platform_icons/linux.svg" width="20" height="20" alt="" align="top"> | **Linux / X11** | Warp | `XWarpPointer` | Visible, wraps. |
| <img src="platform_icons/linux.svg" width="20" height="20" alt="" align="top"> | **Linux / Wayland** | Lock | `pointer-constraints-v1` + `relative-pointer-v1` | **Frozen in place** (Wayland forbids warping). |
| <img src="platform_icons/web.svg" width="20" height="20" alt="" align="top"> | **Web** | Lock | Pointer Lock API (`movementX`) | **Hidden** while dragging (browser policy). |
| <img src="platform_icons/apple.svg" width="20" height="20" alt="" align="top"> <img src="platform_icons/android.svg" width="20" height="20" alt="" align="top"> | **iOS / Android** | — | none | Ordinary clamped drag (no mouse-warp use case). |

The lock strategy (Wayland, web) drives the value from a **polled motion
stream**: while locked, the OS stops sending ordinary motion to Flutter, so the
gesture's `onDragUpdate` goes silent. The controller therefore polls the
platform on a ticker and pushes deltas to the `onLockedDelta` callback you pass
to `start()` — make sure you provide it (the warp platforms don't need it).

## Windows DPI note

The Windows warp does **not** compute `logical × dpi/96` itself — at fractional
scales that overshoots and the cursor escapes the window. Instead it maps the
target by **ratio** across the window's real physical client rectangle (obtained
with the thread pinned to per-monitor-DPI-aware-v2), which is exact at 100 % /
125 % / 150 % / 250 % alike. The cursor hotspot is also kept in device pixels
(not divided by the DPR) so the click point lines up with the visible cursor.

## Wayland note

Wayland deliberately **forbids** an application from setting the absolute pointer
position — a client must not be able to move your cursor wherever it wants. So
the edge-wrap trick is impossible. Instead the controller uses the same model as
the web:

- **Lock** the pointer with
  [`pointer-constraints-unstable-v1`](https://wayland.app/protocols/pointer-constraints-unstable-v1)
  (`zwp_locked_pointer_v1`), and
- read an unbounded **relative-motion** stream with
  [`relative-pointer-unstable-v1`](https://wayland.app/protocols/relative-pointer-unstable-v1)
  (`zwp_relative_pointer_v1`, the *unaccelerated* delta — slow movement survives
  the compositor's acceleration curve).

The result is a true infinite drag with the cursor staying in place. Supported by
Mutter (GNOME), KWin (KDE), Sway, Hyprland and wlroots compositors.
`canWarpPointer()` returns `false` on Wayland (it's lock-based, not warp-based);
the controller takes the lock path automatically.

> There is a newer staging protocol,
> [`wp_pointer_warp_v1`](https://wayland.app/protocols/pointer-warp-v1), that
> would allow a *surface-local* warp, but it isn't reachable from a GTK3/GDK
> Flutter plugin today (and it's surface-local, not arbitrary). The
> lock-and-read-relative-motion approach is the correct, portable solution.

### How it's wired (Linux native)

The Linux pointer subsystem lives in
[`linux/nmc_pointer.cc`](../linux/nmc_pointer.cc) (separate from the cursor /
GObject code). A few implementation choices that matter:

- **No build-time linking of libX11 or libwayland-client.** Linking the system
  libs drags their (newer-GLIBC) symbols onto the host executable's link line,
  which breaks on snap-packaged Flutter's older bundled toolchain. Instead all
  native symbols are resolved at **runtime via `dlsym`** from the libraries GDK
  has already loaded. On snap, where GDK may load libwayland with `RTLD_LOCAL`,
  we fall back to `dlopen("libwayland-client.so.0", RTLD_NOLOAD)` to grab the
  in-process copy.
- **libwayland version range.** Works with both the modern
  `wl_proxy_marshal_flags` (libwayland ≥ 1.19.91) and the older
  `wl_proxy_marshal_constructor[_versioned]` (≥ 1.9.91, e.g. 1.18).
- **Wayland globals** (`zwp_pointer_constraints_v1`,
  `zwp_relative_pointer_manager_v1`) are bound **once** and cached; only the
  per-lock `locked_pointer` + `relative_pointer` are created/destroyed per drag.
- The relative-motion events are pumped on each drain poll so they're delivered
  even while a Flutter drag has GDK's loop busy.

### Build requirements (Linux)

The Wayland lock path is compiled in only when the build can generate the
protocol glue. Install the dev packages so `wayland-scanner` and the protocol XML
are available:

```bash
sudo apt install libwayland-dev wayland-protocols
# (plus libgtk-3-dev, which Flutter Linux already needs)
```

If `wayland-scanner` / `wayland-protocols` are absent, or the compositor doesn't
advertise the protocols, the lock path is cleanly compiled/short-circuited out
and the drag falls back to a normal (edge-clamped) drag — it never fails to
build. X11 needs no extra packages (it's runtime `dlsym` from the already-loaded
libX11).
