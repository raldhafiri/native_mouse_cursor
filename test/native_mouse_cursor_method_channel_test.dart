// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_mouse_cursor/src/native_mouse_cursor_method_channel.dart';
import 'package:native_mouse_cursor/src/native_mouse_cursor_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelNativeMouseCursor();
  const channel = MethodChannel('native_mouse_cursor');
  final calls = <MethodCall>[];
  Object? reply;

  setUp(() {
    calls.clear();
    reply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return reply;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('the method channel is the default platform instance', () {
    expect(
      NativeMouseCursorPlatform.instance,
      isA<MethodChannelNativeMouseCursor>(),
    );
  });

  test('createCursor forwards the bitmap + hotspot', () async {
    await platform.createCursor(
      key: 'rotate',
      pngBytes: Uint8List.fromList(const [1, 2, 3]),
      width: 64,
      height: 64,
      hotX: 32,
      hotY: 30,
      devicePixelRatio: 2,
    );
    expect(calls.single.method, 'createCursor');
    final args = calls.single.arguments as Map;
    expect(args['key'], 'rotate');
    expect(args['width'], 64);
    expect(args['hotX'], 32);
    expect(args['hotY'], 30);
    expect(args['devicePixelRatio'], 2);
  });

  test('setCursor / deleteCursor forward the key', () async {
    await platform.setCursor('rotate');
    await platform.deleteCursor('rotate');
    expect(calls.map((c) => c.method), ['setCursor', 'deleteCursor']);
    expect((calls.last.arguments as Map)['key'], 'rotate');
  });

  test('setPointerHidden forwards the flag', () async {
    await platform.setPointerHidden(true);
    expect(calls.single.method, 'setPointerHidden');
    expect((calls.single.arguments as Map)['hidden'], true);
  });

  test('isSupported returns the host value', () async {
    reply = false;
    expect(await platform.isSupported(), isFalse);
    expect(calls.single.method, 'isSupported');
  });

  test('isSupported defaults to true when the host returns null', () async {
    reply = null;
    expect(await platform.isSupported(), isTrue);
  });

  test('isSupported is true when the host plugin is missing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null); // simulate no plugin
    expect(await platform.isSupported(), isTrue);
  });
}
