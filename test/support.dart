// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:native_mouse_cursor/native_mouse_cursor_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// One recorded `createCursor` call (so tests can assert the baked geometry).
class CreatedCursor {
  CreatedCursor({
    required this.key,
    required this.width,
    required this.height,
    required this.hotX,
    required this.hotY,
    required this.dpr,
  });

  final String key;
  final int width;
  final int height;
  final int hotX;
  final int hotY;
  final double dpr;
}

/// A fake platform that records every call, so the managed cursor logic can be
/// exercised without a real OS backend.
class MockNativeMouseCursorPlatform
    with MockPlatformInterfaceMixin
    implements NativeMouseCursorPlatform {
  final List<CreatedCursor> created = <CreatedCursor>[];
  final List<String> set = <String>[];
  final List<String> deleted = <String>[];
  final List<bool> pointerHidden = <bool>[];
  int resetCount = 0;
  bool supported = true;

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
    created.add(CreatedCursor(
      key: key,
      width: width,
      height: height,
      hotX: hotX,
      hotY: hotY,
      dpr: devicePixelRatio,
    ));
  }

  @override
  Future<void> setCursor(String key) async {
    set.add(key);
  }

  @override
  Future<void> deleteCursor(String key) async {
    deleted.add(key);
  }

  @override
  Future<void> resetCursor() async {
    resetCount++;
  }

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> setPointerHidden(bool hidden) async {
    pointerHidden.add(hidden);
  }

  @override
  Future<void> createCursorWeb({
    required String key,
    required Uint8List lo,
    required Uint8List hi,
    required double density,
    required int hotX,
    required int hotY,
  }) async {
    created.add(CreatedCursor(
      key: key,
      width: lo.length,
      height: hi.length,
      hotX: hotX,
      hotY: hotY,
      dpr: density,
    ));
  }
}

/// A solid [w]×[h] white image, for image-source cursor tests.
Future<ui.Image> solidImage(int w, int h) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(w, h);
}
