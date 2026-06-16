// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

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
}
