# Infinite drag — technical details

An **infinite drag**: drag a value and it keeps changing forever, because the
pointer never runs out of room. The easy path is the
[`InfiniteDragRegion`](../lib/src/infinite_drag_region.dart) widget — wrap your handle
and it handles every platform and browser for you (see the
[README](../README.md)). Under it sits
[`InfiniteDragController`](../lib/src/infinite_drag.dart) for when you want to own the
gesture. This page documents how each platform achieves it under the hood, and
what you need to build it.

## The easy path: `InfiniteDragRegion`

```dart
InfiniteDragRegion(
  cursor: NativeMouseCursor.get('scrub', fallback: SystemMouseCursors.resizeLeftRight),
  onScrub: (delta) => setState(() => value += delta.dx * scrubRate),
  child: Text('$value'),
)
```

It detects the host and chooses the gesture model + lock/warp strategy, arms the
web Pointer Lock, and paints the wrapping cursor — everything below is what it
does internally (and what you'd wire by hand with `InfiniteDragController`).

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
| <img src="platform_icons/apple.svg" width="20" height="20" alt="" align="top"> | **macOS** | Warp | `CGWarpMouseCursorPosition` (+ re-associate); cursor re-asserted after each warp | Visible, wraps. No entitlement needed. |
| <img src="platform_icons/windows.svg" width="20" height="20" alt="" align="top"> | **Windows** | Warp | `SetCursorPos`, mapped by ratio across the physical client rect | Visible, wraps. Correct at fractional DPI (e.g. 250 %). |
| <img src="platform_icons/linux.svg" width="20" height="20" alt="" align="top"> | **Linux / X11** | Warp | `XWarpPointer` | Visible, wraps. |
| <img src="platform_icons/linux.svg" width="20" height="20" alt="" align="top"> | **Linux / Wayland** (modern) | Warp | `wp_pointer_warp_v1` (staging) — GNOME 49+, Plasma 6.5+, Hyprland 0.51+, wlroots 0.21+ | Visible, wraps. |
| <img src="platform_icons/linux.svg" width="20" height="20" alt="" align="top"> | **Linux / Wayland** (older) | Lock | `pointer-constraints-v1` + `relative-pointer-v1` | **Frozen in place** (no warp protocol). |
| <img src="platform_icons/web.svg" width="20" height="20" alt="" align="top"> | **Web — Chrome / Safari / Edge** | Lock | Pointer Lock on **press** (`pointerdown`), `movementX` | Real cursor hidden; a baked cursor is painted **wrapping** the viewport. |
| <img src="platform_icons/web.svg" width="20" height="20" alt="" align="top"> | **Web — Firefox** | Lock | Pointer Lock on **click** (`mousedown`-focus), `movementX` | Same wrapping cursor; **click-to-engage** (click / Esc to exit). |
| <img src="platform_icons/apple.svg" width="20" height="20" alt="" align="top"> <img src="platform_icons/android.svg" width="20" height="20" alt="" align="top"> | **iOS / Android** | — | none | Ordinary clamped drag (no mouse-warp use case). |

> **XWayland caveat.** Forcing an X11 backend on a Wayland session
> (`GDK_BACKEND=x11`) runs the app through **XWayland**, where the compositor
> ignores `XWarpPointer` — so the cursor won't wrap and the scrub clamps at the
> edge. That's an XWayland limitation, not the plugin. In normal use it never
> happens: on Wayland a Flutter app runs as a **native Wayland client** (→ the
> Wayland warp/lock path), and on Xorg as a **real** X11 client (→ `XWarpPointer`,
> which works). To exercise the X11 path, use a real "Ubuntu on Xorg" session, not
> `GDK_BACKEND=x11` under Wayland.

The lock strategy (Wayland, web) drives the value from a **polled motion
stream**: while locked, the OS stops sending ordinary motion to Flutter, so the
gesture's `onDragUpdate` goes silent. The controller therefore polls the
platform on a ticker and pushes deltas to the `onLockedDelta` callback you pass
to `start()` — make sure you provide it (the warp platforms don't need it).

## Keeping the cursor put across warps

On the warp platforms the OS teleports the pointer off your handle to the opposite
edge, where it would otherwise pick up whatever cursor *that* region declares (the
system arrow). So `InfiniteDragRegion` pins your `cursor` **app-wide** for the
duration of the drag — a full-screen, hit-transparent `MouseRegion` overlay — so
it stays the custom glyph through every warp. On **macOS** there's one extra step:
`CGWarpMouseCursorPosition` emits **no** mouse-moved event, so Flutter never
re-evaluates the cursor at the warp target — the native plugin therefore
**re-asserts** the current `NSCursor` right after the warp. (X11 and Wayland do get
a motion event from the warp, so the app-wide pin alone keeps the cursor correct;
the web hides the real cursor entirely and paints the wrapping one.)

## Web note — why Chrome press-drags but Firefox click-engages

Browsers grant Pointer Lock only with [transient
activation](https://developer.mozilla.org/en-US/docs/Web/API/Element/requestPointerLock)
**and** while the document is focused. The document is focused as the *default
action of `mousedown`* — which fires **after** `pointerdown`:

```
pointerdown → mousedown (focuses the document) → mouseup → click
```

- **Chrome / Safari / Edge** are lenient and grant a lock requested on
  `pointerdown`, so a normal **press-drag** works: `InfiniteDragController.start`
  requests the lock, and the value is driven by `onLockedDelta`.
- **Firefox** strictly requires the document to already be focused, so a
  `pointerdown` request (which is *before* the `mousedown` that focuses it) is
  denied with `WrongDocumentError: document is not focused`. The fix is to lock
  on a **`click`** (after focus) — i.e. **click-to-engage**: click to enter a
  locked scrub, move, click / Esc to exit. The request must run in a **native
  capture-phase** listener too, because Flutter `stopPropagation`s the click.

`InfiniteDragRegion` reads `InfiniteDragController.isFirefoxWeb` and picks the
model; the lower-level entry points are `startScrub`/`stopScrub` (click-engage),
`armPointerLock` (gate which region engages, e.g. from `MouseRegion.onEnter`), and
`lockPointer`, which now reports whether the lock actually engaged so a denied
request degrades to a clamped drag instead of a dead one.

### Wrapping cursor

While locked the real cursor is hidden (browser policy), so the package paints a
baked cursor **wrapping** the viewport instead, off the unbounded `movementX/Y`
(`newPos = (pos + delta) % viewport` — the
[MDN pointer-lock](https://mdn.github.io/dom-examples/pointer-lock/) trick),
exposed as the pure `InfiniteDragController.wrapPosition(...)`. `InfiniteDragRegion`
does this automatically when its `cursor` is a `NativeMouseCursor`; standalone you
can use `DragCursorOverlay.show(context, cursor:)` (a transient painter, no
app-wide overlay needed) or `NativeMouseCursor.wrapOverlayCursor(id, position)`
(paints through an existing `NativeMouseCursorOverlay`).

## Windows note

The Windows warp does **not** compute `logical × dpi/96` itself — at fractional
scales that overshoots and the cursor escapes the window. Instead it maps the
target by **ratio** across the window's real physical client rectangle (obtained
with the thread pinned to per-monitor-DPI-aware-v2), which is exact at 100 % /
125 % / 150 % / 250 % alike. The cursor hotspot is also kept in device pixels
(not divided by the DPR) so the click point lines up with the visible cursor.

The custom cursor survives each warp **without** a manual re-assert (unlike
macOS): it's installed as the window-class cursor (`SetClassLongPtr` with
`GCLP_HCURSOR`), and `SetCursorPos` fires `WM_MOUSEMOVE` → `WM_SETCURSOR`, whose
default handling redraws that class cursor.

## Wayland note

Historically Wayland **forbade** an application from setting the pointer position,
so the edge-wrap trick was impossible and the only option was lock + relative
motion. That changed with the staging
[`wp_pointer_warp_v1`](https://wayland.app/protocols/pointer-warp-v1) protocol
(wayland-protocols 1.45, 2025), which lets a client request a **surface-local**
warp. So the Wayland backend now has **two tiers**:

**1. Warp (preferred) — `wp_pointer_warp_v1`.** When the compositor advertises
it, we bind the global and call `warp_pointer(surface, pointer, x, y, serial)` to
move the cursor to the opposite edge — a **visible wrapping cursor**, like
X11/macOS/Windows. `canWarpPointer()` returns `true` in this case, so the
controller takes the warp path. The protocol requires the target surface to have
pointer focus (satisfied by the drag's implicit grab, button held), a valid
`wl_pointer.enter` serial, and an in-bounds target. We bind our **own**
`wl_seat`/`wl_pointer` purely to capture that serial + focus — GDK's pointer
already has a listener and libwayland allows only one per proxy. Available on
**GNOME 49+ (Mutter)**, **Plasma 6.5+ (KWin)**, **Hyprland 0.51+**, **wlroots
0.21+**.

**2. Lock (fallback) — older compositors.** Where `wp_pointer_warp_v1` is absent,
`canWarpPointer()` returns `false` and we fall back to the lock model (same as the
web):

- **Lock** the pointer with
  [`pointer-constraints-unstable-v1`](https://wayland.app/protocols/pointer-constraints-unstable-v1)
  (`zwp_locked_pointer_v1`), and
- read an unbounded **relative-motion** stream with
  [`relative-pointer-unstable-v1`](https://wayland.app/protocols/relative-pointer-unstable-v1)
  (`zwp_relative_pointer_v1`, the *unaccelerated* delta — slow movement survives
  the compositor's acceleration curve).

This freezes the cursor in place but still gives a true infinite drag. Selection
between the two tiers is automatic and per-session (it depends on what the running
compositor advertises).

> ⚠️ `wp_pointer_warp_v1` is a **staging** protocol on compositors released in
> 2025; coverage is still partial, so many users get the lock fallback for now.
> Honoring is ultimately compositor-discretion — the lock path remains the
> guaranteed one.

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
- **One binary, both backends.** The X11 and Wayland paths are *both* compiled in;
  the active one is chosen at **runtime** from the GDK display type
  (`GDK_IS_X11_DISPLAY` vs `GDK_IS_WAYLAND_DISPLAY`) — there's no separate X11 vs
  Wayland build.
- **libwayland version range.** Works with both the modern
  `wl_proxy_marshal_flags` (libwayland ≥ 1.19.91) and the older
  `wl_proxy_marshal_constructor[_versioned]` (≥ 1.9.91, e.g. 1.18).
- **Wayland globals** are bound **once** and cached: `zwp_pointer_constraints_v1` +
  `zwp_relative_pointer_manager_v1` (lock path), plus `wp_pointer_warp_v1` and our
  own `wl_seat`/`wl_pointer` (warp path — the extra pointer exists only to read the
  `wl_pointer.enter` serial the warp request requires). Only the per-lock
  `locked_pointer` + `relative_pointer` are created/destroyed per drag.
- The relative-motion events are pumped on each drain poll so they're delivered
  even while a Flutter drag has GDK's loop busy.

### Build requirements (Linux)

Wayland support (both the lock **and** warp paths) is compiled in only when the
build can generate the protocol glue — `wayland-scanner`, the `wayland-client`
headers, and the system protocol XML. These are **usually already present**:
`libgtk-3-dev` (a Flutter Linux desktop prerequisite) pulls in `libwayland-dev`
(which provides `wayland-scanner`) and `wayland-protocols`, so a normal Flutter
Linux dev box needs nothing extra. Only on a **minimal / headless** build image
that lacks them do you install them explicitly:

```bash
sudo apt install libwayland-dev wayland-protocols
```

The lock protocols come from the system `wayland-protocols`; the newer
`wp_pointer_warp_v1` XML is **vendored** in
[`linux/wayland_protocols/`](../linux/wayland_protocols/), so warp needs **no
newer `wayland-protocols` version** on the build host — only `wayland-scanner`.

If `wayland-scanner` / `wayland-protocols` are absent, or the compositor doesn't
advertise the protocol, the relevant path is cleanly compiled/short-circuited out
and the drag falls back to a normal (edge-clamped) drag — it never fails to
build. X11 needs no extra packages (it's runtime `dlsym` from the already-loaded
libX11).
