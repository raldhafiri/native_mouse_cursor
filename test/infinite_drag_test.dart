// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_mouse_cursor/native_mouse_cursor.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const viewport = Size(1000, 600);

  group('InfiniteDragController (warp host)', () {
    late MockNativeMouseCursorPlatform mock;
    late InfiniteDragController drag;

    setUp(() {
      mock = MockNativeMouseCursorPlatform()..canWarp = true;
      drag = InfiniteDragController(platform: mock);
    });

    test('passes ordinary deltas through unchanged', () async {
      await drag.start(const Offset(500, 300));
      expect(drag.warpAvailable, isTrue);
      final dx = await drag.update(
        globalPosition: const Offset(520, 300),
        delta: const Offset(20, 0),
        viewportSize: viewport,
      );
      expect(dx, 20);
      expect(mock.warps, isEmpty); // mid-viewport: no wrap
    });

    test('skips the giant warp-jump frame', () async {
      await drag.start(const Offset(500, 300));
      // A delta of >= ~half the viewport width can only be a teleport. Use a
      // mid-screen position so this isolates the jump-skip from any edge wrap.
      final dx = await drag.update(
        globalPosition: const Offset(150, 300),
        delta: const Offset(-980, 0),
        viewportSize: viewport,
      );
      expect(dx, 0); // jump suppressed
      expect(mock.warps, isEmpty); // mid-screen: jump-skip only, no wrap
    });

    test('warps toward the opposite side at the right border', () async {
      await drag.start(const Offset(500, 300));
      await drag.update(
        globalPosition: const Offset(998, 300), // within margin of right edge
        delta: const Offset(6, 0),
        viewportSize: viewport,
      );
      expect(mock.warps, hasLength(1));
      // Lands well inside the LEFT half (inset ~15% in), not on the boundary.
      expect(mock.warps.single.dx, greaterThan(viewport.width * 0.10));
      expect(mock.warps.single.dx, lessThan(viewport.width * 0.5));
    });

    test('warps toward the opposite side at the left border', () async {
      await drag.start(const Offset(500, 300));
      await drag.update(
        globalPosition: const Offset(2, 300),
        delta: const Offset(-6, 0),
        viewportSize: viewport,
      );
      expect(mock.warps, hasLength(1));
      // Lands well inside the RIGHT half.
      expect(mock.warps.single.dx, lessThan(viewport.width * 0.90));
      expect(mock.warps.single.dx, greaterThan(viewport.width * 0.5));
    });

    test('does not re-warp on the frames right after a warp (cooldown)',
        () async {
      await drag.start(const Offset(500, 300));
      // First update at the edge → one warp.
      await drag.update(
        globalPosition: const Offset(998, 300),
        delta: const Offset(6, 0),
        viewportSize: viewport,
      );
      expect(mock.warps, hasLength(1));
      // The next couple of updates (the jump + settle) must NOT fire more warps,
      // even if they still report being near an edge.
      final dxA = await drag.update(
        globalPosition: const Offset(2, 300), // looks like it's at the left edge
        delta: const Offset(-980, 0), // the warp jump
        viewportSize: viewport,
      );
      final dxB = await drag.update(
        globalPosition: const Offset(4, 300),
        delta: const Offset(2, 0),
        viewportSize: viewport,
      );
      expect(mock.warps, hasLength(1)); // still just the one
      expect(dxA, 0); // jump swallowed
      expect(dxB, 0); // settle frame swallowed
    });

    test('does not lock the pointer on a warp host', () async {
      await drag.start(const Offset(500, 300));
      await drag.end();
      expect(mock.lockCount, 0);
      expect(mock.unlockCount, 0);
    });

    test('horizontal axis (default) never warps vertically', () async {
      await drag.start(const Offset(500, 300));
      // Pointer drifts to the TOP edge during a horizontal scrub.
      await drag.update(
        globalPosition: const Offset(500, 1), // at the top edge
        delta: const Offset(4, -4),
        viewportSize: viewport,
      );
      expect(mock.warps, isEmpty); // no vertical wrap → no "jump to top"
    });

    test('both axes wrap when axis: both', () async {
      final d = InfiniteDragController(axis: InfiniteDragAxis.both,
          platform: mock);
      await d.start(const Offset(500, 300));
      await d.update(
        globalPosition: const Offset(500, 1), // top edge
        delta: const Offset(0, -4),
        viewportSize: viewport,
      );
      expect(mock.warps, hasLength(1)); // vertical wrap fired
      expect(mock.warps.single.dy, greaterThan(viewport.height * 0.5));
    });
  });

  group('InfiniteDragController (no-warp / web host)', () {
    late MockNativeMouseCursorPlatform mock;
    late InfiniteDragController drag;

    setUp(() {
      mock = MockNativeMouseCursorPlatform()..canWarp = false;
      drag = InfiniteDragController(platform: mock);
    });

    test('locks the pointer on start and unlocks on end', () async {
      await drag.start(const Offset(500, 300), onLockedDelta: (_) {});
      expect(drag.warpAvailable, isFalse);
      expect(mock.lockCount, 1);
      await drag.end();
      expect(mock.unlockCount, 1);
    });

    test('update() returns zero on the lock path (ticker drives instead)',
        () async {
      await drag.start(const Offset(500, 300), onLockedDelta: (_) {});
      mock.lockDelta = const Offset(42, 0);
      final dx = await drag.update(
        globalPosition: const Offset(500, 300),
        delta: Offset.zero,
        viewportSize: viewport,
      );
      expect(dx, 0); // the locked path is driven by onLockedDelta, not update()
      expect(mock.warps, isEmpty); // never warps on web/Wayland
      await drag.end();
    });

    test('pushes polled lock motion to onLockedDelta on a ticker', () async {
      Offset received = Offset.zero;
      await drag.start(const Offset(500, 300),
          onLockedDelta: (d) => received += d);
      mock.lockDelta = const Offset(42, -3);
      // Wait past the ~16ms ticker so it polls drainPointerLockDelta once.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(received.dx, 42);
      expect(received.dy, -3);
      await drag.end();
    });
  });
}
