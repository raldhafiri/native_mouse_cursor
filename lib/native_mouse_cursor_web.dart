// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

// ignore: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show Offset;

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

  // The last cursor KEY we applied. Re-applying the SAME data-URL cursor string
  // makes Chrome re-decode the PNG, and under rapid re-sets (a rotating cursor,
  // or hover churn) it intermittently drops a frame and shows a BLANK cursor —
  // the "random, like it didn't load" bug. We dedupe by key so a steady cursor
  // is written once and left alone.
  String? _appliedKey;

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
    final loData = 'data:image/png;base64,${base64Encode(lo)}';
    final hiData = 'data:image/png;base64,${base64Encode(hi)}';
    final loUrl = 'url($loData)';
    final hiUrl = 'url($hiData)';
    final hot = '$hotX $hotY';
    final d = density.toStringAsFixed(2);
    _css[key] = <String>[
      '$loUrl $hot, auto', // universal fallback (correct size, soft on HiDPI)
      'image-set($loUrl 1x, $hiUrl ${d}x) $hot, auto', // crisp on HiDPI
      '-webkit-image-set($loUrl 1x, $hiUrl ${d}x) $hot, auto', // older WebKit
    ];
    // Pre-decode both bitmaps so Chrome has them cached when the cursor is
    // applied: a fresh data-URL cursor that isn't decoded yet renders BLANK
    // until the next pointer move (the "random, didn't load" bug).
    _warm(loData);
    _warm(hiData);
  }

  // Kick off a browser decode of a data-URL image so it's cached before use.
  void _warm(String dataUrl) {
    final img = web.HTMLImageElement();
    img.decoding = 'sync';
    img.src = dataUrl;
    img.decode().toDart.catchError((_) => null);
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
    final data = 'data:image/png;base64,${base64Encode(pngBytes)}';
    _css[key] = ['url($data) $hotX $hotY, auto'];
    _warm(data); // pre-decode so it's cached before the cursor is applied
  }

  @override
  Future<void> setCursor(String key) async {
    final css = _css[key];
    if (css == null) return;
    // Skip a redundant re-apply of the SAME cursor — re-writing the data-URL
    // makes Chrome re-decode it and randomly blank for a frame.
    if (_appliedKey == key) return;
    _appliedKey = key;
    // Drop a stale host cache if it has become disconnected (Flutter rebuilt the
    // DOM — e.g. on resize/restart), so the cursor isn't written to a dead
    // element (→ blank). The getter re-resolves when _hosts is null.
    final cached = _hosts;
    if (cached != null &&
        (cached.isEmpty || !cached.first.isConnected)) {
      _hosts = null;
    }
    // Apply each candidate; the browser keeps the last one it understands.
    for (final value in css) {
      _setCursorValue(value);
    }
  }

  @override
  Future<void> resetCursor() async {
    _appliedKey = null;
    _setCursorValue('');
  }

  @override
  Future<void> deleteCursor(String key) async {
    _css.remove(key);
  }

  // ─────────────────────────── pointer warping ────────────────────────────────
  // Browsers expose NO API to teleport the pointer, so warping is unavailable on
  // web. The "infinite drag" effect is delivered through the Pointer Lock API
  // instead (below): an unbounded relative-movement stream with no edges.

  @override
  Future<void> warpPointer(
    double x,
    double y, {
    double? viewportWidth,
    double? viewportHeight,
  }) async {
    // No-op: the web cannot move the system pointer. Use lockPointer().
  }

  @override
  Future<bool> canWarpPointer() async => false;

  // ──────────────────────────────── pointer lock ───────────────────────────────

  // Accumulated pointer-lock movement (CSS px) since the last drain; reset by
  // [drainPointerLockDelta]. movementX/Y are already in CSS (logical) px.
  double _lockedDx = 0;
  double _lockedDy = 0;

  // The live pointermove listener, kept so we can remove it on unlock.
  web.EventListener? _moveListener;

  // The element that should own the lock — the same host element the cursor is
  // written to (newest Flutter web engine first).
  web.Element? get _lockTarget {
    for (final el in _hostElements) {
      // body is a last-resort fallback; prefer a real Flutter view element.
      if (el != web.document.body) return el;
    }
    return web.document.body ?? web.document.documentElement;
  }

  @override
  Future<bool> lockPointer() async {
    final target = _lockTarget;
    if (target == null) return false;
    _lockedDx = 0;
    _lockedDy = 0;
    final listener = (web.Event event) {
      // Only accumulate while the element actually holds the lock; movementX/Y
      // are 0 outside a lock, so this is also safe pre-engagement.
      if (web.document.pointerLockElement == target) {
        final e = event as web.MouseEvent;
        _lockedDx += e.movementX;
        _lockedDy += e.movementY;
      }
    }.toJS;
    _moveListener = listener;
    web.document.addEventListener('pointermove', listener);
    // requestPointerLock must be called from a user gesture; a drag start is
    // one, so this resolves when the browser grants (or silently denies) it.
    target.requestPointerLock();
    return true;
  }

  @override
  Future<void> unlockPointer() async {
    final listener = _moveListener;
    if (listener != null) {
      web.document.removeEventListener('pointermove', listener);
      _moveListener = null;
    }
    if (web.document.pointerLockElement != null) {
      web.document.exitPointerLock();
    }
    _lockedDx = 0;
    _lockedDy = 0;
  }

  @override
  Future<Offset> drainPointerLockDelta() async {
    final d = Offset(_lockedDx, _lockedDy);
    _lockedDx = 0;
    _lockedDy = 0;
    return d;
  }
}
