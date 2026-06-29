// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';

import 'native_mouse_cursor_platform_interface.dart';

/// Which axis (or axes) an [InfiniteDragController] wraps the pointer on.
enum InfiniteDragAxis {
  /// Wrap only at the left/right edges (the common case: a horizontal value
  /// scrub). The pointer never wraps vertically, so a slight vertical drift
  /// during the drag can't teleport it to the top/bottom.
  horizontal,

  /// Wrap only at the top/bottom edges (a vertical scrub).
  vertical,

  /// Wrap at all four edges (a free 2-D drag).
  both,
}

/// Drives an **infinite drag** (value "scrub"): a horizontal
/// (or free) drag whose value can grow forever because the pointer wraps at the
/// window edge instead of running into it.
///
/// You keep owning the gesture — wire your own `GestureDetector` (or
/// `Listener`) to a controller instance and, on each drag update, hand it the
/// pointer's **global** position and the **viewport** size. It returns the
/// *effective* delta to apply to your value, having already:
///
///  * **skipped the warp-jump frame** — the one giant delta a teleport produces
///    (only a warp can move the pointer half a window in one event), so your
///    value doesn't lurch when the cursor wraps; and
///  * **wrapped the pointer at the edge** — on desktop via a native warp
///    ([NativeMouseCursorPlatform.warpPointer]); on web via the Pointer Lock
///    API (whose unbounded `movementX` is used as the delta source directly).
///
/// ### Platform behaviour
///  * **macOS / Windows / Linux-X11** — the OS pointer is warped at the edge;
///    the cursor stays visible and the drag is truly infinite.
///  * **Web** — the pointer is *locked* on [start] (the real cursor is hidden)
///    and the delta is sourced from pointer-lock movement, not from the Flutter
///    delta you pass. The browser can't keep a *locked* cursor visible, but you
///    can opt into a painted **wrapping cursor** via [start]'s `onCursorWrap`
///    (wired to [NativeMouseCursor.wrapOverlayCursor]): a fake cursor that loops
///    the viewport off the accumulated motion, matching the desktop edge-warp.
///  * **Linux/Wayland** — warping is normally forbidden by the compositor, so
///    [warpAvailable] is `false` and the drag falls back to Flutter's clamped
///    delta (it stops at the window edge like an ordinary drag). See the README
///    for the `wp_pointer_warp_v1` situation.
///  * **mobile** — no warp; ordinary clamped delta.
///
/// ### Usage
/// ```dart
/// final _drag = InfiniteDragController();
///
/// GestureDetector(
///   onHorizontalDragStart: (d) => _drag.start(d.globalPosition),
///   onHorizontalDragUpdate: (d) async {
///     final dx = await _drag.update(
///       globalPosition: d.globalPosition,
///       delta: d.delta,
///       viewportSize: MediaQuery.sizeOf(context).size, // or window size
///     );
///     setState(() => value += dx * scrubRate);
///   },
///   onHorizontalDragEnd: (_) => _drag.end(),
///   child: handle,
/// );
/// ```
///
/// Create one per draggable handle (or reuse one — only a single drag can be
/// active at a time). [dispose] it with its `State` to release the web lock.
class InfiniteDragController {
  InfiniteDragController({
    this.edgeMargin = 16.0,
    this.axis = InfiniteDragAxis.horizontal,
    NativeMouseCursorPlatform? platform,
  }) : _platform = platform ?? NativeMouseCursorPlatform.instance;

  final NativeMouseCursorPlatform _platform;

  /// Which edges wrap the pointer. Defaults to [InfiniteDragAxis.horizontal]
  /// (a horizontal value scrub) so a vertical drift never teleports the pointer
  /// to the top/bottom. Use [InfiniteDragAxis.both] for a free 2-D drag.
  final InfiniteDragAxis axis;

  /// How close (logical px) the pointer must get to a window edge before it is
  /// wrapped to the opposite side (default 16). A comfortable margin so the wrap
  /// still triggers despite a few px of cursor-hotspot / DPI slop near the edge.
  /// Desktop only.
  final double edgeMargin;

  bool _dragging = false;

  /// Resolved on [start]: whether the host can warp the pointer (desktop) — if
  /// not, the controller uses Flutter deltas / web pointer lock.
  bool _canWarp = false;

  /// True between [start] and [end] on web once a pointer lock was requested, so
  /// [update] drains lock movement instead of trusting the Flutter delta.
  bool _locked = false;

  /// On the LOCK path (web pointer-lock, Linux/Wayland constraints), the OS
  /// stops sending ordinary motion to Flutter — so `onDragUpdate` (and thus
  /// [update]) stops firing and can't drive the value. We instead POLL the
  /// platform's locked-motion accumulator on a ticker and push the delta to
  /// [_onLockedDelta]. Null when not on the lock path.
  Timer? _lockTicker;
  void Function(Offset delta)? _onLockedDelta;

  /// Optional sink for the WRAPPED fake-cursor position on the lock path (web).
  /// When the app passes [start]'s `onCursorWrap`, the controller accumulates the
  /// locked motion into a fake cursor that wraps the viewport — mirroring the
  /// desktop edge-warp — and pushes its position here each frame so a visible
  /// cursor can be painted while the real pointer is locked + hidden. Null on the
  /// warp path and when the app didn't opt in.
  void Function(Offset position)? _onCursorWrap;
  Size _wrapViewport = Size.zero;
  Offset _fakeCursor = Offset.zero;

  /// Frames to ignore the edge-warp after one fires. A fast drag can queue
  /// several updates that all still report "near the edge" before the warp
  /// visibly lands, firing multiple conflicting warps ("goes crazy"). After a
  /// warp we skip the next couple of updates' wrap + delta so the pointer
  /// settles back inside first.
  int _warpCooldown = 0;

  /// Whether the host can warp the pointer for this drag. Valid after [start]
  /// (false before). Lets the UI decide e.g. whether to show an edge hint.
  bool get warpAvailable => _canWarp;

  /// Web plumbing for [InfiniteDragRegion] — "arm" the lock while the pointer is
  /// over the draggable so a press/click there engages a scrub. Use
  /// [InfiniteDragRegion] instead.
  @internal
  void armPointerLock(bool armed) => _platform.setPointerLockArmed(armed);

  /// Web plumbing for [InfiniteDragRegion] — true on Firefox, which needs a
  /// click-engaged lock ([startScrub]) rather than press-drag. Use
  /// [InfiniteDragRegion] instead.
  @internal
  bool get isFirefoxWeb => _platform.isFirefox;

  /// Web plumbing for [InfiniteDragRegion] — engage a press/click Pointer Lock
  /// scrub (the model that works on every browser, Firefox included), driving the
  /// value from [onLockedDelta] and reporting enter/exit via [onActive]. Tear
  /// down with [stopScrub]. Use [InfiniteDragRegion] instead.
  @internal
  void startScrub({
    required void Function(Offset delta) onLockedDelta,
    void Function(bool active)? onActive,
  }) {
    _onLockedDelta = onLockedDelta;
    _platform.setPointerLockListener((locked) {
      _locked = locked;
      _dragging = locked;
      if (locked) {
        _startLockTicker();
      } else {
        _stopLockTicker();
      }
      onActive?.call(locked);
    });
    _platform.enablePointerLockScrub(true);
  }

  /// Web plumbing for [InfiniteDragRegion] — tear down [startScrub].
  @internal
  void stopScrub() {
    _platform.enablePointerLockScrub(false);
    _platform.setPointerLockListener(null);
    _stopLockTicker();
    if (_locked) {
      _locked = false;
      unawaited(_platform.unlockPointer());
    }
    _dragging = false;
    _onLockedDelta = null;
  }

  /// Whether a drag is currently active.
  bool get isDragging => _dragging;

  /// Begin an infinite drag. Pass the pointer's current **global** position
  /// (`PointerEvent.position` / `d.globalPosition`).
  ///
  /// **Web call site matters.** This requests Pointer Lock, which browsers grant
  /// only from an *activating* event. Call it from a raw
  /// `Listener.onPointerDown` — NOT `GestureDetector.onHorizontalDragStart`,
  /// which fires during a `pointermove` (Firefox rejects the lock there, and
  /// once locked the frozen position stops a gesture drag from ever being
  /// recognised). On web the value is then driven entirely by [onLockedDelta];
  /// call [end] from `onPointerUp`. On desktop, keep using the gesture callbacks
  /// + [update] (the OS pointer warps at the edge).
  ///
  /// [onLockedDelta] is REQUIRED to support the **lock** path (web pointer-lock
  /// and Linux/Wayland): while the pointer is locked the OS stops sending motion
  /// to Flutter, so `onDragUpdate` (and [update]) stop firing. The controller
  /// then polls the platform on a ticker and pushes the effective delta to this
  /// callback instead — apply your scrub there. On the warp path (macOS /
  /// Windows / Linux-X11) it isn't used; [update] drives the value as usual.
  ///
  /// [onCursorWrap] (lock path only) opts into a visible **wrapping cursor**: the
  /// controller accumulates the locked motion into a fake cursor position that
  /// wraps the viewport (the MDN pointer-lock trick) and calls this each frame.
  /// Wire it to [NativeMouseCursor.wrapOverlayCursor] to paint the baked cursor,
  /// or draw your own. Requires [viewportSize]. On the warp path it's unused (the
  /// real OS cursor already wraps).
  Future<void> start(
    Offset globalPosition, {
    void Function(Offset delta)? onLockedDelta,
    void Function(Offset position)? onCursorWrap,
    Size? viewportSize,
  }) async {
    assert(
      onCursorWrap == null || viewportSize != null,
      'Pass viewportSize to start() when using onCursorWrap — wrapping needs the '
      'viewport bounds.',
    );
    _dragging = true;
    _locked = false;
    _warpCooldown = 0;
    _onLockedDelta = onLockedDelta;
    _onCursorWrap = onCursorWrap;
    _wrapViewport = viewportSize ?? Size.zero;
    _fakeCursor = globalPosition;

    // WEB: never warps — it uses Pointer Lock, which the browser grants only off
    // an active user gesture. requestPointerLock() must therefore run inside the
    // gesture's synchronous call stack, BEFORE any `await` (an intervening
    // microtask drops the activation — Firefox rejects it outright, Chrome is
    // lenient). So fast-path web here and request the lock first, skipping the
    // `await canWarpPointer()` round-trip that used to precede it.
    if (kIsWeb) {
      _canWarp = false;
      if (onLockedDelta == null) {
        assert(_warnNoLockedDelta());
        return; // no delta sink → caller's update() drives a clamped drag.
      }
      // Request the lock synchronously (no await precedes this call). Do NOT
      // suppress update() yet: until the lock actually engages, the caller's
      // update() drives an ordinary CLAMPED drag. If it engages (Chrome), switch
      // to the polled ticker for a true infinite drag. If it's DENIED — Firefox
      // rejects a lock requested during a pointermove, which is exactly when
      // GestureDetector fires onStart — the clamped drag just continues, with no
      // flicker and no dead drag.
      _platform.lockPointer().then((engaged) {
        if (!_dragging || _locked) return;
        if (engaged) {
          _locked = true;
          _startLockTicker();
        }
      });
      return;
    }

    _canWarp = await _platform.canWarpPointer();
    if (!_canWarp) {
      // The LOCK path drives the value via [onLockedDelta] (the OS stops sending
      // motion to Flutter while locked, so update() can't). If the caller didn't
      // provide that callback, locking would produce a DEAD drag — the pointer
      // freezes but nothing applies the motion. So only lock when we have a sink
      // for the deltas; otherwise fall back to Flutter's clamped delta (update()).
      if (onLockedDelta == null) {
        assert(_warnNoLockedDelta());
        return;
      }
      // No native warp (Wayland / mobile). Try a pointer LOCK for a true infinite
      // drag (Wayland pointer-constraints). If it engages, drive the value from a
      // polled motion stream.
      _locked = await _platform.lockPointer();
      if (_locked) _startLockTicker();
    }
  }

  // Debug-only warning when the lock path is requested without a delta sink.
  bool _warnNoLockedDelta() {
    if (kDebugMode) {
      debugPrint(
        '[InfiniteDrag] lock path skipped: start() was called without '
        'onLockedDelta, so a locked drag could not update any value. Pass '
        'onLockedDelta to enable infinite drag on web / Wayland. Falling back '
        'to a clamped drag.',
      );
    }
    return true;
  }

  // Poll the platform's locked-motion accumulator each frame and push the delta
  // to the app, since Flutter's own drag updates are silent under a lock.
  void _startLockTicker() {
    _lockTicker?.cancel();
    _lockTicker = Timer.periodic(const Duration(milliseconds: 16), (_) async {
      if (!_locked || !_dragging) return;
      final d = await _platform.drainPointerLockDelta();
      if (d == Offset.zero) return;
      _onLockedDelta?.call(d);
      final wrap = _onCursorWrap;
      if (wrap != null) wrap(_advanceFakeCursor(d));
    });
  }

  void _stopLockTicker() {
    _lockTicker?.cancel();
    _lockTicker = null;
  }

  /// Feed one drag update and get back the **effective dx** to apply to your
  /// value (already de-jumped and, on the wrap frame, zero).
  ///
  ///  * [globalPosition] — the pointer's global position this frame.
  ///  * [delta] — the raw Flutter drag delta this frame (`d.delta`).
  ///  * [viewportSize] — the window / viewport size, for the edge math. Use
  ///    `MediaQuery.sizeOf(context)` or the platform window size.
  ///
  /// Use the returned value as your scrub delta. (For a 2-D drag, see
  /// [updateOffset].)
  Future<double> update({
    required Offset globalPosition,
    required Offset delta,
    required Size viewportSize,
  }) async => (await updateOffset(
    globalPosition: globalPosition,
    delta: delta,
    viewportSize: viewportSize,
  )).dx;

  /// The 2-D form of [update]: returns the effective (dx, dy) for a free drag.
  /// Edge-wrapping is applied on whichever axis reaches a border.
  Future<Offset> updateOffset({
    required Offset globalPosition,
    required Offset delta,
    required Size viewportSize,
  }) async {
    if (!_dragging) return Offset.zero;
    final double w = viewportSize.width, h = viewportSize.height;

    // Lock path (web pointer-lock / Wayland constraints): the value is driven by
    // the ticker → onLockedDelta, NOT by this method (the Flutter delta is
    // meaningless while locked, and on Wayland this method isn't even called
    // because the OS stops sending motion). Return zero so a stray web
    // onDragUpdate doesn't double-count.
    if (_locked) return Offset.zero;

    Offset effective = delta;
    if (_canWarp) {
      final bool wrapX = axis != InfiniteDragAxis.vertical;
      final bool wrapY = axis != InfiniteDragAxis.horizontal;

      // 1. ALWAYS skip the giant one-frame delta a WARP produces — on the warped
      //    axis only. Only a teleport can move the pointer ~half a window in one
      //    event; real drag deltas are small. This is magnitude-based and NOT
      //    time-limited, so a warp jump that the OS delivers a few frames late
      //    (common at high DPI) is still caught instead of rocketing the value.
      if (wrapX && w > 0 && delta.dx.abs() >= w * 0.45) {
        effective = Offset(0, effective.dy);
      }
      if (wrapY && h > 0 && delta.dy.abs() >= h * 0.45) {
        effective = Offset(effective.dx, 0);
      }

      // 2. Settle frames right after a warp: swallow a couple of updates so a
      //    fast drag's queued "still near the edge" frames can't fire several
      //    conflicting warps before the first one lands.
      if (_warpCooldown > 0) {
        _warpCooldown--;
        return Offset.zero;
      }

      // 3. Wrap the pointer at a window edge so the drag never runs out of room.
      //    Land it a generous distance in from the opposite edge (~15%) so a
      //    fast drag can't immediately cross back and re-trigger, and so it never
      //    lands ON the boundary (which makes the OS flip the cursor
      //    custom↔default = flicker). Only the configured [axis] wraps, so a
      //    horizontal scrub never teleports vertically (no "jump to top").
      final double m = edgeMargin;
      final double insetX = (w * 0.15).clamp(m + 4, w / 2);
      final double insetY = (h * 0.15).clamp(m + 4, h / 2);
      double? warpX, warpY;
      if (wrapX && w > 2 * m) {
        if (globalPosition.dx >= w - m) {
          warpX = insetX; // wrapped from the right → land near the middle-left
        } else if (globalPosition.dx <= m) {
          warpX = w - insetX;
        }
      }
      if (wrapY && h > 2 * m) {
        if (globalPosition.dy >= h - m) {
          warpY = insetY;
        } else if (globalPosition.dy <= m) {
          warpY = h - insetY;
        }
      }
      if (warpX != null || warpY != null) {
        _warpCooldown = 2; // ignore the next ~2 updates (jump + settle)
        // Keep the un-warped axis at the current position. Pass the viewport so
        // the native side can map by ratio (exact at fractional DPI scales).
        await _platform.warpPointer(
          warpX ?? globalPosition.dx,
          warpY ?? globalPosition.dy,
          viewportWidth: w,
          viewportHeight: h,
        );
      }
    }
    return effective;
  }

  // ─────────────────────────── web cursor wrap ────────────────────────────────

  /// Wrap [pos] + [delta] within [viewport], honouring [axis]: the wrapped axis
  /// folds with a modulo (re-entering the opposite edge — the MDN pointer-lock
  /// trick), while the off-axis is clamped to the viewport so it can't drift out
  /// of sight. Pure — handy for painting your own wrapping cursor from the
  /// `onCursorWrap` / `onLockedDelta` deltas.
  static Offset wrapPosition(
    Offset pos,
    Offset delta,
    Size viewport,
    InfiniteDragAxis axis,
  ) {
    final double w = viewport.width, h = viewport.height;
    final bool wrapX = axis != InfiniteDragAxis.vertical;
    final bool wrapY = axis != InfiniteDragAxis.horizontal;
    double x = pos.dx + delta.dx;
    double y = pos.dy + delta.dy;
    if (w > 0) {
      if (wrapX) {
        x %= w;
        if (x < 0) x += w;
      } else {
        x = x.clamp(0.0, w);
      }
    }
    if (h > 0) {
      if (wrapY) {
        y %= h;
        if (y < 0) y += h;
      } else {
        y = y.clamp(0.0, h);
      }
    }
    return Offset(x, y);
  }

  Offset _advanceFakeCursor(Offset delta) =>
      _fakeCursor = wrapPosition(_fakeCursor, delta, _wrapViewport, axis);

  /// End the active drag: releases the pointer lock (re-showing/unfreezing the
  /// cursor) and stops sourcing lock movement. Safe to call when no drag is
  /// active.
  Future<void> end() async {
    _dragging = false;
    _stopLockTicker();
    _onLockedDelta = null;
    _onCursorWrap = null;
    if (_locked) {
      _locked = false;
      await _platform.unlockPointer();
    }
  }

  /// Cancel the drag (e.g. `onHorizontalDragCancel`) — same teardown as [end].
  Future<void> cancel() => end();

  /// Release any held resources (the pointer lock + ticker). Call from your
  /// `State.dispose`.
  void dispose() {
    _stopLockTicker();
    _onLockedDelta = null;
    _onCursorWrap = null;
    if (_locked) {
      _locked = false;
      unawaited(_platform.unlockPointer());
    }
    _dragging = false;
  }
}
