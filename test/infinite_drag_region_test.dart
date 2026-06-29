// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_mouse_cursor/native_mouse_cursor.dart';
import 'package:native_mouse_cursor/src/native_mouse_cursor_platform_interface.dart';

import 'support.dart';

void main() {
  late MockNativeMouseCursorPlatform mock;

  setUp(() {
    // A warp host (desktop): canWarpPointer → true, so the drag drives the value
    // from the controller's effective delta rather than the lock ticker.
    mock = MockNativeMouseCursorPlatform()..canWarp = true;
    NativeMouseCursorPlatform.instance = mock;
  });

  const handle = ValueKey('handle');

  // An InfiniteDragRegion with a keyed handle, inside a MaterialApp (which
  // provides the root Overlay that the app-wide cursor pin inserts into).
  Future<void> pumpRegion(
    WidgetTester tester, {
    MouseCursor? cursor,
    required void Function(Offset) onScrub,
    void Function(bool)? onActiveChanged,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: InfiniteDragRegion(
              cursor: cursor,
              onScrub: onScrub,
              onActiveChanged: onActiveChanged,
              child: const SizedBox(
                key: handle,
                width: 120,
                height: 60,
                child: Text('drag'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The MouseRegion the region wraps the handle in (nearest ancestor).
  MouseRegion regionAround(WidgetTester tester) => tester
      .widgetList<MouseRegion>(
        find.ancestor(
          of: find.byKey(handle),
          matching: find.byType(MouseRegion),
        ),
      )
      .first;

  int mouseRegionsWith(WidgetTester tester, MouseCursor cursor) => tester
      .widgetList<MouseRegion>(find.byType(MouseRegion))
      .where((m) => m.cursor == cursor)
      .length;

  Future<TestGesture> startDrag(WidgetTester tester) async {
    final g = await tester.startGesture(tester.getCenter(find.byKey(handle)));
    await tester.pump();
    return g;
  }

  testWidgets('renders its child', (tester) async {
    await pumpRegion(tester, onScrub: (_) {});
    expect(find.text('drag'), findsOneWidget);
  });

  testWidgets('cursor omitted defers to the currently-used cursor', (
    tester,
  ) async {
    await pumpRegion(tester, onScrub: (_) {});
    expect(regionAround(tester).cursor, MouseCursor.defer);
  });

  testWidgets('cursor provided sets the region cursor', (tester) async {
    await pumpRegion(tester, cursor: SystemMouseCursors.grab, onScrub: (_) {});
    expect(regionAround(tester).cursor, SystemMouseCursors.grab);
  });

  testWidgets('pins the cursor app-wide only while dragging, when given one', (
    tester,
  ) async {
    await pumpRegion(tester, cursor: SystemMouseCursors.grab, onScrub: (_) {});
    expect(
      mouseRegionsWith(tester, SystemMouseCursors.grab),
      1,
    ); // just the region

    final g = await startDrag(tester);
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    // Region + the full-screen app-wide pin both carry the cursor now.
    expect(mouseRegionsWith(tester, SystemMouseCursors.grab), 2);

    await g.up();
    await tester.pump();
    expect(mouseRegionsWith(tester, SystemMouseCursors.grab), 1); // pin removed
  });

  testWidgets('does not pin anything while dragging when cursor is omitted', (
    tester,
  ) async {
    await pumpRegion(tester, onScrub: (_) {});
    final before = tester
        .widgetList<MouseRegion>(find.byType(MouseRegion))
        .length;

    final g = await startDrag(tester);
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    final during = tester
        .widgetList<MouseRegion>(find.byType(MouseRegion))
        .length;
    await g.up();
    await tester.pump();

    expect(during, before); // no overlay pin inserted
  });

  testWidgets('a horizontal drag drives onScrub and toggles active', (
    tester,
  ) async {
    final active = <bool>[];
    var scrubbed = Offset.zero;
    await pumpRegion(
      tester,
      cursor: SystemMouseCursors.grab,
      onScrub: (d) => scrubbed += d,
      onActiveChanged: active.add,
    );

    final g = await startDrag(tester);
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();

    expect(active.first, isTrue);
    expect(active.last, isFalse);
    expect(scrubbed.dx, greaterThan(0));
  });
}
