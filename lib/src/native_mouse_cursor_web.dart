// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

// ignore: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
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
    if (cached != null && (cached.isEmpty || !cached.first.isConnected)) {
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

  // The pointerlockchange / pointerlockerror listeners used to resolve whether a
  // requestPointerLock() actually engaged; cleared once it settles.
  web.EventListener? _lockChangeListener;
  web.EventListener? _lockErrorListener;

  // True between a lockPointer() request and unlockPointer(). Requesting the lock
  // from a raw pointer-down (so Firefox grants it) means a plain CLICK also
  // requests one; if it then engages after the click already ended, this lets it
  // exit itself instead of leaving the cursor captured + hidden.
  bool _lockWanted = false;

  // A tiny offscreen element we focus right before requesting a lock. Firefox
  // denies the lock unless document.hasFocus() is true, and Flutter web (which
  // preventDefaults pointer events) often leaves the document unfocused there;
  // focusing an element WE own is more reliable than focusing Flutter's view.
  web.HTMLElement? _focusSinkEl;

  // Whether the pointer is over a draggable region; gates the click-to-lock so a
  // click engages a scrub only there, not anywhere in the app.
  bool _lockArmed = false;

  @override
  void setPointerLockArmed(bool armed) => _lockArmed = armed;

  web.HTMLElement _focusSink() {
    final existing = _focusSinkEl;
    if (existing != null && existing.isConnected) return existing;
    final el = web.document.createElement('div') as web.HTMLElement;
    el.tabIndex = -1; // programmatically focusable, not in the tab order
    el.setAttribute('aria-hidden', 'true');
    el.style
      ..setProperty('position', 'fixed')
      ..setProperty('left', '0')
      ..setProperty('top', '0')
      ..setProperty('width', '1px')
      ..setProperty('height', '1px')
      ..setProperty('opacity', '0')
      ..setProperty('pointer-events', 'none');
    web.document.body?.appendChild(el);
    return _focusSinkEl = el;
  }

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
    _lockWanted = true;

    final move = (web.Event event) {
      // Only accumulate while the element actually holds the lock; movementX/Y
      // are 0 outside a lock, so this is also safe pre-engagement.
      if (web.document.pointerLockElement == target) {
        final e = event as web.MouseEvent;
        _lockedDx += e.movementX;
        _lockedDy += e.movementY;
      }
    }.toJS;
    _moveListener = move;
    web.document.addEventListener('pointermove', move);

    // Resolve to whether the lock ACTUALLY engaged, so the controller can fall
    // back to a clamped drag when the browser denies it (notably Firefox, which
    // only grants a lock requested from an active user gesture). The previous
    // code returned `true` unconditionally, so a denied lock left the drag dead.
    final settled = Completer<bool>();
    void clearLockListeners() {
      final c = _lockChangeListener, e = _lockErrorListener;
      if (c != null) web.document.removeEventListener('pointerlockchange', c);
      if (e != null) web.document.removeEventListener('pointerlockerror', e);
      _lockChangeListener = null;
      _lockErrorListener = null;
    }

    _lockChangeListener = ((web.Event _) {
      if (web.document.pointerLockElement == target && !settled.isCompleted) {
        clearLockListeners();
        if (!_lockWanted) {
          // unlockPointer() ran before the lock engaged (a quick click, not a
          // drag) — exit at once so the cursor isn't left captured + hidden.
          web.document.exitPointerLock();
          settled.complete(false);
          return;
        }
        settled.complete(true);
      }
    }).toJS;
    _lockErrorListener = ((web.Event _) {
      if (!settled.isCompleted) {
        clearLockListeners();
        if (kDebugMode) {
          debugPrint(
            '[NativeMouseCursor] pointer lock was denied (pointerlockerror). On '
            'Firefox this means the request did not come from an active user '
            'gesture — the infinite drag will fall back to a clamped drag.',
          );
        }
        settled.complete(false);
      }
    }).toJS;
    web.document.addEventListener('pointerlockchange', _lockChangeListener!);
    web.document.addEventListener('pointerlockerror', _lockErrorListener!);

    // Firefox denies the lock unless the DOCUMENT is focused. Flutter web
    // preventDefaults pointer events, so on Firefox the click often never
    // focuses the document — force it synchronously by focusing an element we
    // own (focusing Flutter's view is unreliable; it manages its own focus).
    web.window.focus();
    _focusSink().focus();
    if (kDebugMode && !web.document.hasFocus()) {
      debugPrint(
        '[NativeMouseCursor] document STILL not focused after focus() — Firefox '
        'will deny the lock. That means the browsing context itself lacks focus '
        '(DevTools holding it, or an embedded/iframe view), which page code '
        'cannot override. The drag falls back to a clamped drag.',
      );
    }

    // MUST run synchronously inside the user-gesture call stack (no `await`
    // precedes this in the caller): browsers grant a lock only off a user
    // activation, and an intervening microtask drops it — Firefox strictly so.
    //
    // requestPointerLock() returns a Promise that REJECTS on denial (e.g.
    // "document is not focused"). Handle it so it isn't an uncaught error and so
    // the result settles even if no pointerlockerror event arrives; the
    // listeners above settle the success/engaged case.
    target.requestPointerLock().toDart.then(
      (_) {},
      onError: (Object e) {
        if (kDebugMode) {
          debugPrint('[NativeMouseCursor] requestPointerLock rejected: $e');
        }
        if (!settled.isCompleted) {
          clearLockListeners();
          settled.complete(false);
        }
      },
    );

    // Resolve on the browser's confirmation; guard with a timeout so a browser
    // that fires neither event can't hang the drag.
    return settled.future.timeout(
      const Duration(milliseconds: 800),
      onTimeout: () {
        clearLockListeners();
        return web.document.pointerLockElement == target;
      },
    );
  }

  @override
  Future<void> unlockPointer() async {
    _lockWanted = false;
    final listener = _moveListener;
    if (listener != null) {
      web.document.removeEventListener('pointermove', listener);
      _moveListener = null;
    }
    // A drag can end before requestPointerLock() settled — drop those too.
    final c = _lockChangeListener, e = _lockErrorListener;
    if (c != null) web.document.removeEventListener('pointerlockchange', c);
    if (e != null) web.document.removeEventListener('pointerlockerror', e);
    _lockChangeListener = null;
    _lockErrorListener = null;
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

  // ─────────────────────────── click-to-lock (web) ─────────────────────────────
  // Firefox grants Pointer Lock only when the document is focused, and the
  // document is focused as the DEFAULT ACTION of `mousedown` — which fires AFTER
  // `pointerdown`. So a press-drag (lock at pointerdown) is denied on Firefox,
  // but a `click` (after mousedown) is granted. This locks on a native `click`
  // — the MDN-proven model — and works on every browser: click an armed region
  // to enter a locked scrub, move to change, click again / Esc to exit.

  void Function(bool locked)? _lockStateCb;
  web.EventListener? _clickLockListener;
  web.EventListener? _lockWatchListener;

  @override
  void setPointerLockListener(void Function(bool locked)? listener) {
    _lockStateCb = listener;
    if (listener != null) _ensureLockWatcher();
  }

  @override
  bool get isFirefox =>
      web.window.navigator.userAgent.toLowerCase().contains('firefox');

  @override
  void enablePointerLockScrub(bool enable) {
    if (enable) {
      _ensureLockWatcher();
      if (_clickLockListener != null) return;
      final l = ((web.Event _) {
        if (web.document.pointerLockElement != null) {
          // Click again to exit. Exiting programmatically (not via Esc) lets a
          // subsequent click re-lock immediately — Firefox blocks a re-lock that
          // follows the Esc default-unlock gesture.
          web.document.exitPointerLock();
        } else if (_lockArmed) {
          final target = _lockTarget;
          if (target == null) return;
          _lockedDx = 0;
          _lockedDy = 0;
          target.requestPointerLock().toDart.then(
            (_) {},
            onError: (Object e) {
              if (kDebugMode) {
                debugPrint('[NativeMouseCursor] click lock rejected: $e');
              }
            },
          );
        }
      }).toJS;
      _clickLockListener = l;
      // CAPTURE phase on the document, so it runs BEFORE Flutter — which can
      // stopPropagation the click (a bubble-phase listener would never fire).
      web.document.addEventListener('click', l, true.toJS);
    } else {
      final l = _clickLockListener;
      if (l != null) {
        web.document.removeEventListener('click', l, true.toJS);
        _clickLockListener = null;
      }
      if (web.document.pointerLockElement != null) {
        web.document.exitPointerLock();
      }
    }
  }

  // A single persistent pointerlockchange watcher: (un)hooks the movement
  // accumulator and reports lock state to the controller.
  void _ensureLockWatcher() {
    if (_lockWatchListener != null) return;
    final w = ((web.Event _) {
      final locked = web.document.pointerLockElement != null;
      if (locked && _moveListener == null) {
        final move = ((web.Event event) {
          final e = event as web.MouseEvent;
          _lockedDx += e.movementX;
          _lockedDy += e.movementY;
        }).toJS;
        _moveListener = move;
        web.document.addEventListener('pointermove', move);
      } else if (!locked && _moveListener != null) {
        web.document.removeEventListener('pointermove', _moveListener!);
        _moveListener = null;
        _lockedDx = 0;
        _lockedDy = 0;
      }
      _lockStateCb?.call(locked);
    }).toJS;
    _lockWatchListener = w;
    web.document.addEventListener('pointerlockchange', w);
  }
}
