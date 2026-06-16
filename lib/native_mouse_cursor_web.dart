// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

// ignore: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'native_mouse_cursor_platform_interface.dart';

/// Web implementation: each cursor becomes a `url(data:image/png;base64,…) x y`
/// CSS cursor value, applied to the Flutter view's host element(s) on
/// [setCursor].
///
/// The bitmap handed to us is already logical-size and ≤128 px (the framework
/// side caps it for the browser), with [hotX]/[hotY] in the bitmap's own pixels
/// and [devicePixelRatio] == 1, so the CSS hotspot is used as-is.
///
/// We set the cursor on several candidate view elements because which element
/// actually carries the cursor varies across Flutter web engine versions.
class NativeMouseCursorWeb extends NativeMouseCursorPlatform {
  NativeMouseCursorWeb();

  // Per cursor: CSS `cursor` values to apply in order — a plain `url()` that
  // works everywhere, then `image-set(...)` upgrades that a HiDPI browser uses
  // for a crisp cursor (invalid values are ignored, leaving the last good one).
  final Map<String, List<String>> _css = {};

  static void registerWith(Registrar registrar) {
    NativeMouseCursorPlatform.instance = NativeMouseCursorWeb();
  }

  // Candidate elements that may carry the pointer's cursor, newest-engine first.
  static const _hostSelectors = <String>[
    'flt-glass-pane',
    'flutter-view',
    'flt-scene-host',
  ];

  // Resolved (and cached) host elements we write `style.cursor` on. Cached so a
  // rotating cursor isn't re-querying the DOM every angle.
  List<web.HTMLElement>? _hosts;

  List<web.HTMLElement> get _hostElements {
    final cached = _hosts;
    if (cached != null && cached.isNotEmpty && cached.first.isConnected) {
      return cached;
    }
    final found = <web.HTMLElement>[];
    for (final selector in _hostSelectors) {
      final el = web.document.querySelector(selector);
      if (el != null) found.add(el as web.HTMLElement);
    }
    final body = web.document.body;
    if (body != null) found.add(body);
    return _hosts = found;
  }

  void _setCursorValue(String value) {
    for (final el in _hostElements) {
      el.style.cursor = value;
    }
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
    final loUrl = 'url(data:image/png;base64,${base64Encode(lo)})';
    final hiUrl = 'url(data:image/png;base64,${base64Encode(hi)})';
    final hot = '$hotX $hotY';
    final d = density.toStringAsFixed(2);
    _css[key] = <String>[
      '$loUrl $hot, auto', // universal fallback (correct size, soft on HiDPI)
      'image-set($loUrl 1x, $hiUrl ${d}x) $hot, auto', // crisp on HiDPI
      '-webkit-image-set($loUrl 1x, $hiUrl ${d}x) $hot, auto', // older WebKit
    ];
  }

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
    final b64 = base64Encode(pngBytes);
    _css[key] = ['url(data:image/png;base64,$b64) $hotX $hotY, auto'];
  }

  @override
  Future<void> setCursor(String key) async {
    final css = _css[key];
    if (css == null) return;
    // Apply each candidate; the browser keeps the last one it understands.
    for (final value in css) {
      _setCursorValue(value);
    }
  }

  @override
  Future<void> resetCursor() async => _setCursorValue('');

  @override
  Future<void> deleteCursor(String key) async {
    _css.remove(key);
  }
}
