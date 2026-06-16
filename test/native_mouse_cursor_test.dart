// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_mouse_cursor/native_mouse_cursor.dart';
import 'package:native_mouse_cursor/native_mouse_cursor_platform_interface.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    NativeMouseCursorPlatform.instance = MockNativeMouseCursorPlatform();
    NativeMouseCursor.configure(devicePixelRatio: 2);
  });

  tearDown(() => NativeMouseCursor.disposeAll());

  group('get() fallback', () {
    test('returns SystemMouseCursors.basic for an unregistered id', () {
      expect(NativeMouseCursor.get('missing'), SystemMouseCursors.basic);
    });

    test('returns the provided fallback for an unregistered id', () {
      expect(
        NativeMouseCursor.get('missing', fallback: SystemMouseCursors.grab),
        SystemMouseCursors.grab,
      );
    });
  });

  group('registration', () {
    test('has() is false before registering, true after', () {
      expect(NativeMouseCursor.has('h'), isFalse);
      NativeMouseCursor.draw('h',
          size: const Size(16, 16), painter: (canvas, size) {});
      expect(NativeMouseCursor.has('h'), isTrue);
    });

    test('dispose removes a registration (get falls back again)', () {
      NativeMouseCursor.draw('d',
          size: const Size(16, 16), painter: (canvas, size) {});
      expect(NativeMouseCursor.has('d'), isTrue);

      NativeMouseCursor.dispose('d');

      expect(NativeMouseCursor.has('d'), isFalse);
      expect(NativeMouseCursor.get('d'), SystemMouseCursors.basic);
    });

    test('disposeAll clears every registration', () {
      NativeMouseCursor.draw('a',
          size: const Size(16, 16), painter: (canvas, size) {});
      NativeMouseCursor.draw('b',
          size: const Size(16, 16), painter: (canvas, size) {});

      NativeMouseCursor.disposeAll();

      expect(NativeMouseCursor.has('a'), isFalse);
      expect(NativeMouseCursor.has('b'), isFalse);
    });
  });

  // The bake itself (GPU rasterisation) is covered by the on-device integration
  // test; here we unit-test the pure geometry it relies on.
  group('cursor box', () {
    test('is the integer ceiling of the glyph diagonal (no shadow)', () {
      // √(20² + 20²) = 28.28 → ceil → 29, square.
      expect(cursorBoxForTest(const Size(20, 20), shadow: null),
          const Size(29, 29));
    });

    test('adds the shadow offset + 3σ as padding', () {
      // core 28.28 + 2·(offset 1 + 3·0.75) = 28.28 + 6.5 = 34.78 → ceil 35.
      final box = cursorBoxForTest(const Size(20, 20),
          shadow: const NativeCursorShadow());
      expect(box, const Size(35, 35));
    });

    test('is square even for a non-square glyph (fits any rotation)', () {
      final box = cursorBoxForTest(const Size(40, 10), shadow: null);
      expect(box.width, box.height);
    });
  });

  group('hotspot in box', () {
    test('centres a null hotspot', () {
      expect(hotspotInBoxForTest(const Size(30, 30), const Size(20, 20), null),
          const Offset(15, 15));
    });

    test('maps a glyph hotspot into the centred box', () {
      // 20-glyph centred in 30-box → +5 offset; (2,3) → (7,8).
      expect(
        hotspotInBoxForTest(
            const Size(30, 30), const Size(20, 20), const Offset(2, 3)),
        const Offset(7, 8),
      );
    });
  });

  group('hotspot transform (mirror + rotate around box centre)', () {
    test('flipX mirrors x across the centre', () {
      expect(
        transformHotspotForTest(const Offset(7, 8), const Size(30, 30), 0, true,
            false),
        const Offset(23, 8),
      );
    });

    test('flipY mirrors y across the centre', () {
      expect(
        transformHotspotForTest(const Offset(7, 8), const Size(30, 30), 0,
            false, true),
        const Offset(7, 22),
      );
    });

    test('the box centre is invariant under rotation', () {
      final p = transformHotspotForTest(
          const Offset(15, 15), const Size(30, 30), 1.23, false, false);
      expect(p.dx, closeTo(15, 1e-9));
      expect(p.dy, closeTo(15, 1e-9));
    });

    test('rotates a non-centre point about the centre', () {
      // (20,15) is +5 on x from centre; rotating 90° puts it +5 on y.
      final p = transformHotspotForTest(
          const Offset(20, 15), const Size(30, 30), math.pi / 2, false, false);
      expect(p.dx, closeTo(15, 1e-6));
      expect(p.dy, closeTo(20, 1e-6));
    });
  });
}
