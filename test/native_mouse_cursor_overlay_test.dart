// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_mouse_cursor/native_mouse_cursor.dart';

Widget _wrap(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

void main() {
  testWidgets('renders its child (pass-through when not forced)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const NativeMouseCursorOverlay(child: Text('hello'))),
    );
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('force overlay mounts and rebuilds without error', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const NativeMouseCursorOverlay(force: true, child: SizedBox())),
    );
    await tester.pump();
    // Toggling force back off should not throw.
    await tester.pumpWidget(
      _wrap(const NativeMouseCursorOverlay(force: false, child: SizedBox())),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not block hit-testing of its child', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        NativeMouseCursorOverlay(
          force: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => tapped = true,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SizedBox), warnIfMissed: false);
    expect(tapped, isTrue);
  });
}
