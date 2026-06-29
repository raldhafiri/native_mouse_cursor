// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_mouse_cursor_platform_interface.dart';

/// Method-channel implementation (macOS / Linux / Windows native hosts).
class MethodChannelNativeMouseCursor extends NativeMouseCursorPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('native_mouse_cursor');

  @override
  Future<void> createCursor({
    required String key,
    required Uint8List pngBytes,
    required int width,
    required int height,
    required int hotX,
    required int hotY,
    required double devicePixelRatio,
  }) async {
    await methodChannel.invokeMethod<void>('createCursor', {
      'key': key,
      'buffer': pngBytes,
      'width': width,
      'height': height,
      'hotX': hotX,
      'hotY': hotY,
      'devicePixelRatio': devicePixelRatio,
    });
  }

  @override
  Future<void> setCursor(String key) async {
    await methodChannel.invokeMethod<void>('setCursor', {'key': key});
  }

  @override
  Future<void> deleteCursor(String key) async {
    await methodChannel.invokeMethod<void>('deleteCursor', {'key': key});
  }

  @override
  Future<bool> isSupported() async {
    try {
      return await methodChannel.invokeMethod<bool>('isSupported') ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  @override
  Future<void> setPointerHidden(bool hidden) async {
    try {
      await methodChannel.invokeMethod<void>('setPointerHidden', {
        'hidden': hidden,
      });
    } on MissingPluginException {
      // Host doesn't implement it (everything but Android) — fine.
    } on PlatformException {
      // Ignore.
    }
  }

  @override
  Future<void> warpPointer(
    double x,
    double y, {
    double? viewportWidth,
    double? viewportHeight,
  }) async {
    try {
      await methodChannel.invokeMethod<void>('warpPointer', {
        'x': x,
        'y': y,
        'viewportW': ?viewportWidth,
        'viewportH': ?viewportHeight,
      });
    } on MissingPluginException {
      // Host doesn't implement warping (mobile / Wayland fallback) — no-op.
    } on PlatformException {
      // Ignore.
    }
  }

  @override
  Future<bool> canWarpPointer() async {
    try {
      return await methodChannel.invokeMethod<bool>('canWarpPointer') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  // Pointer lock: web uses the Pointer Lock API; Linux/Wayland implements these
  // natively (pointer-constraints + relative-pointer) since it can't warp. On
  // macOS/Windows/Linux-X11 the host doesn't implement them → MissingPlugin
  // exception → the no-op defaults (those hosts warp instead).

  @override
  Future<bool> lockPointer() async {
    try {
      return await methodChannel.invokeMethod<bool>('lockPointer') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> unlockPointer() async {
    try {
      await methodChannel.invokeMethod<void>('unlockPointer');
    } on MissingPluginException {
      // Host warps instead — nothing to unlock.
    } on PlatformException {
      // Ignore.
    }
  }

  @override
  Future<Offset> drainPointerLockDelta() async {
    try {
      // Use the untyped invokeMethod and read the map loosely: a strict
      // invokeMapMethod<String, dynamic> can throw a TypeError on some hosts
      // (the platform map comes back as Map<Object?, Object?>), which would
      // silently kill the polling ticker.
      final raw = await methodChannel.invokeMethod<dynamic>(
        'drainPointerLockDelta',
      );
      if (raw is! Map) {
        assert(() {
          if (raw != null) {
            // ignore: avoid_print
            debugPrint(
              '[native_mouse_cursor] drain returned non-map: '
              '${raw.runtimeType} = $raw',
            );
          }
          return true;
        }());
        return Offset.zero;
      }
      final dx = (raw['dx'] as num?)?.toDouble() ?? 0;
      final dy = (raw['dy'] as num?)?.toDouble() ?? 0;
      return Offset(dx, dy);
    } on MissingPluginException {
      return Offset.zero;
    } on PlatformException {
      return Offset.zero;
    } catch (_) {
      // Be defensive: never let a parse error kill the drag ticker.
      return Offset.zero;
    }
  }
}
