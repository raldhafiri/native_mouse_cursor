// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_mouse_cursor/native_mouse_cursor.dart';

void main() {
  group('NativeCursorShadow', () {
    test('defaults match the macOS system-cursor shadow', () {
      const shadow = NativeCursorShadow();
      expect(shadow.color, const Color(0x80000000));
      expect(shadow.offset, const Offset(0, 1));
      expect(shadow.blur, 1.5);
    });

    test('blurSigma is blur / 2 (CSS box-shadow convention)', () {
      expect(const NativeCursorShadow(blur: 1.5).blurSigma, 0.75);
      expect(const NativeCursorShadow(blur: 4).blurSigma, 2.0);
    });

    test('blurSigma is 0 when blur is 0', () {
      expect(const NativeCursorShadow(blur: 0).blurSigma, 0.0);
    });
  });
}
