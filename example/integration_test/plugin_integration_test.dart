// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_mouse_cursor/native_mouse_cursor.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a registered cursor can be fetched by id', (tester) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 16, 16),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final image = await recorder.endRecording().toImage(16, 16);

    NativeMouseCursor.configure(devicePixelRatio: 2);
    NativeMouseCursor.image('it_cursor', image);

    // The bake runs asynchronously after register(); get() returns the system
    // fallback until it lands, then the baked NativeMouseCursor. Pump until then.
    MouseCursor cursor = SystemMouseCursors.basic;
    for (var i = 0; i < 20 && cursor is! NativeMouseCursor; i++) {
      cursor = NativeMouseCursor.get('it_cursor');
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(cursor, isA<NativeMouseCursor>());

    NativeMouseCursor.disposeAll();
  });
}
