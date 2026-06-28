// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'native_mouse_cursor_method_channel.dart';

/// Platform interface for the native cursor backend.
abstract class NativeMouseCursorPlatform extends PlatformInterface {
  NativeMouseCursorPlatform() : super(token: _token);

  static final Object _token = Object();

  static NativeMouseCursorPlatform _instance = MethodChannelNativeMouseCursor();

  static NativeMouseCursorPlatform get instance => _instance;

  static set instance(NativeMouseCursorPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Register a cursor bitmap ([pngBytes], [width]×[height] device pixels) under
  /// [key], with hotspot [hotX]/[hotY] (device pixels) and source
  /// [devicePixelRatio] so the OS sizes it in logical points.
  Future<void> createCursor({
    required String key,
    required Uint8List pngBytes,
    required int width,
    required int height,
    required int hotX,
    required int hotY,
    required double devicePixelRatio,
  }) {
    throw UnimplementedError('createCursor() has not been implemented.');
  }

  /// Make the cursor registered under [key] the active OS cursor.
  Future<void> setCursor(String key) {
    throw UnimplementedError('setCursor() has not been implemented.');
  }

  /// Web only: register a cursor from a low-res ([lo], 1×, CSS-sized) and a
  /// high-res ([hi]) PNG so HiDPI browsers render it crisply via CSS
  /// `image-set`. [density] is the high-res bitmap's resolution multiplier;
  /// [hotX]/[hotY] are in CSS pixels. A no-op off the web.
  Future<void> createCursorWeb({
    required String key,
    required Uint8List lo,
    required Uint8List hi,
    required double density,
    required int hotX,
    required int hotY,
  }) async {}

  /// Clear any cursor this backend has applied, returning to the default. Used
  /// on web (where the cursor is a CSS property we own) when a cursor session
  /// ends, so nothing lingers; a no-op on native hosts (the OS manages it).
  Future<void> resetCursor() async {}

  /// Forget the cursor registered under [key].
  Future<void> deleteCursor(String key) {
    throw UnimplementedError('deleteCursor() has not been implemented.');
  }

  /// Whether this host can show a true native OS cursor. Hosts without one
  /// (iOS/iPadOS, Android below API 24) return `false`. Defaults to `true`.
  Future<bool> isSupported() async => true;

  /// Hide/show the system pointer, used by [NativeMouseCursorOverlay] so the
  /// painted cursor replaces it instead of doubling it. Implemented on Android
  /// (a null `PointerIcon`); a no-op elsewhere (web/desktop hide via Flutter's
  /// own `SystemMouseCursors.none`). Defaults to a no-op.
  Future<void> setPointerHidden(bool hidden) async {}

  // ─────────────────────────── pointer warping ────────────────────────────────
  // The cheap primitive behind an infinite drag (a value scrub):
  // teleport the OS pointer so a drag can wrap at the window edge and never run
  // out of room. Desktop hosts warp natively; web can't (see the web impl's
  // pointer-lock path), mobile has no use case.

  /// Teleport the OS pointer to ([x], [y]) in Flutter-LOGICAL window
  /// coordinates (top-left origin, y-down — the same space as
  /// `PointerEvent.position`).
  ///
  /// [viewportWidth]/[viewportHeight] are the logical window size (the same
  /// space as [x]/[y]); when provided, the native side maps by RATIO across the
  /// physical client rect, which is exact at fractional display scales (e.g.
  /// 250%) where a naive logical×(dpi/96) conversion overshoots and the cursor
  /// escapes the window. Pass them whenever you can (the [InfiniteDragController]
  /// does).
  ///
  /// Implemented natively on macOS (`CGWarpMouseCursorPosition`), Windows
  /// (`SetCursorPos`) and Linux/X11 (`XWarpPointer`). On Linux/Wayland it is a
  /// best-effort no-op (Wayland forbids warping; the newer `wp_pointer_warp_v1`
  /// staging protocol is not yet reachable from a GTK/GDK Flutter plugin — see
  /// the README). On web it is a no-op (browsers can't move the pointer — use
  /// [InfiniteDragController] which sources its delta from the Pointer Lock API
  /// instead). A graceful no-op on mobile and any host without the capability.
  Future<void> warpPointer(
    double x,
    double y, {
    double? viewportWidth,
    double? viewportHeight,
  }) async {}

  /// Whether this host can teleport the OS pointer via [warpPointer]. `true` on
  /// macOS / Windows / Linux-X11; `false` on web / mobile / Linux-Wayland.
  /// [InfiniteDragController] uses this to pick its edge-wrap vs. pointer-lock
  /// strategy. Defaults to `false`.
  Future<bool> canWarpPointer() async => false;

  // ───────────────────── pointer lock (web infinite drag) ──────────────────────
  // Web can't warp, but the Pointer Lock API gives an unbounded relative delta
  // stream (movementX) with no edges — the same "infinite drag" effect. These
  // are implemented only on web; native hosts use warping instead.

  /// Web only: request Pointer Lock on the Flutter view element and start
  /// streaming relative pointer movement. While locked the OS cursor is hidden
  /// and `pointermove` reports unbounded `movementX`/`movementY` deltas, which
  /// [InfiniteDragController] consumes instead of Flutter drag deltas. A no-op
  /// off the web. Returns `true` if the lock was requested.
  Future<bool> lockPointer() async => false;

  /// Web only: exit Pointer Lock (re-showing the cursor) and stop the movement
  /// stream. A no-op off the web.
  Future<void> unlockPointer() async {}

  /// Web only: the accumulated relative movement (logical px) since the last
  /// call, then reset to zero — a poll-based drain of the pointer-lock
  /// `movementX`/`movementY` stream. Off the web it returns `Offset.zero`.
  Future<Offset> drainPointerLockDelta() async => Offset.zero;
}
