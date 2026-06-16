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
      await methodChannel
          .invokeMethod<void>('setPointerHidden', {'hidden': hidden});
    } on MissingPluginException {
      // Host doesn't implement it (everything but Android) — fine.
    } on PlatformException {
      // Ignore.
    }
  }
}
