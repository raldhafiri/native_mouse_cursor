// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

part of 'native_mouse_cursor.dart';

/// Holds which [NativeMouseCursor] is active (per device) and the latest pointer
/// position, and drives the [NativeMouseCursorOverlay]'s repaint. One instance
/// is created by the mounted overlay widget and registered on
/// [NativeMouseCursor._overlay] so cursor sessions can route into it.
class _CursorOverlayController extends ChangeNotifier {
  /// Whether the overlay should actually paint (decided by platform / `force`).
  /// Until a mounted overlay calls [enable], cursor sessions keep going native.
  bool enabled = false;

  // device → active cursor cache-key.
  final Map<int, String> _active = {};

  // The latest pointer position in the overlay's local coordinate space. A
  // single value (mouse cursors are effectively one pointer) so we never depend
  // on the hover event's device id matching the cursor session's.
  Offset? _lastPosition;

  bool _nativePointerHidden = false;
  bool _pointerSyncScheduled = false;

  // Infinite-drag wrap cursor (web): a baked-bitmap cache-key painted at an
  // explicit position, independent of hover — under a pointer lock there are no
  // hover events to drive [_lastPosition]. Set via
  // [NativeMouseCursor.wrapOverlayCursor].
  String? _wrapKey;
  Offset? _wrapPosition;

  void setWrapCursor({String? key, Offset? position}) {
    if (key == _wrapKey && position == _wrapPosition) return;
    _wrapKey = key;
    _wrapPosition = position;
    if (enabled) notifyListeners();
  }

  /// Turn the overlay on or off. On: retain baked bitmaps so we have something
  /// to paint, and route cursor sessions here. Off: drop the painted cursors and
  /// let sessions go back to the native cursor.
  void setEnabled(bool value) {
    if (value == enabled) return;
    enabled = value;
    if (value) {
      NativeMouseCursor._cache.enableRetention();
    } else {
      _active.clear();
      _syncNativePointer();
    }
    notifyListeners();
  }

  void activate(int device, String key) {
    _active[device] = key;
    _syncNativePointer();
    notifyListeners();
  }

  void deactivate(int device) {
    if (_active.remove(device) != null) {
      _syncNativePointer();
      notifyListeners();
    }
  }

  // On Android the engine's `none` cursor can be unreliable, so ask our plugin
  // to hide the system pointer (a null PointerIcon) while a cursor is active and
  // restore it when none is. Web/desktop hide via the session's
  // `SystemMouseCursors.none`, so this is Android-only.
  //
  // Coalesced into a microtask: a rotating cursor changes angle bucket by
  // disposing the old session (deactivate) then activating the new one
  // (activate) in the same frame. Reconciling once *after* both keeps the
  // pointer hidden throughout — otherwise the brief deactivate would un-hide the
  // system pointer and it'd flash back on every bucket change.
  void _syncNativePointer() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_pointerSyncScheduled) return;
    _pointerSyncScheduled = true;
    Future.microtask(() {
      _pointerSyncScheduled = false;
      final wantHidden = _active.isNotEmpty;
      if (wantHidden == _nativePointerHidden) return;
      _nativePointerHidden = wantHidden;
      NativeMouseCursorPlatform.instance.setPointerHidden(wantHidden);
    });
  }

  void updatePosition(Offset position) {
    _lastPosition = position;
    if (_active.isNotEmpty) notifyListeners();
  }

  /// The pointer left the app (window) — stop painting until it returns.
  void pointerExited() {
    if (_lastPosition == null) return;
    _lastPosition = null;
    if (_active.isNotEmpty) notifyListeners();
  }

  /// A lazily-rendered overlay bitmap just landed — repaint to show it.
  void bitmapReady() {
    if (enabled) notifyListeners();
  }
}

/// Wrap your app with this to make [NativeMouseCursor]s work on platforms that
/// have **no native custom-cursor API** — iOS/iPadOS and Android below API 24 —
/// by painting the same baked bitmap in a Flutter overlay that follows the
/// pointer, while suppressing the system pointer so there's no double cursor.
///
/// Off by default — set [force] to enable it. It's only useful where the system
/// cursor can be **hidden** so the painted one replaces it rather than doubling
/// it: the **web** (hidden via the CSS cursor) and **desktop** (hidden via
/// `SystemMouseCursors.none`). On iOS/iPadOS the system pointer can't be hidden,
/// so the overlay isn't appropriate there (the system pointer would show through).
///
/// On the web it gives a perfectly seamless per-region cursor (vs. the engine's
/// best-effort CSS handling); on desktop it lets you preview that painted cursor.
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) =>
///       NativeMouseCursorOverlay(force: kIsWeb, child: child!),
///   home: const MyHomePage(),
/// );
/// ```
///
/// ⚠️ The overlay is a Flutter widget chasing the pointer, so it has the
/// one-frame lag and possible jitter that a real OS cursor doesn't.
class NativeMouseCursorOverlay extends StatefulWidget {
  const NativeMouseCursorOverlay({
    super.key,
    required this.child,
    this.force = false,
  });

  /// Your app (typically the `child` from `MaterialApp.builder`).
  final Widget child;

  /// Paint cursors with the in-app overlay (hiding the system cursor) instead of
  /// using the native/CSS cursor. Meaningful on web and desktop, where the system
  /// cursor can be hidden. Default: `false`.
  final bool force;

  @override
  State<NativeMouseCursorOverlay> createState() =>
      _NativeMouseCursorOverlayState();
}

class _NativeMouseCursorOverlayState extends State<NativeMouseCursorOverlay> {
  final _CursorOverlayController _controller = _CursorOverlayController();

  @override
  void initState() {
    super.initState();
    NativeMouseCursor._overlay = _controller;
    _controller.setEnabled(widget.force);
  }

  @override
  void didUpdateWidget(NativeMouseCursorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.force != oldWidget.force) _controller.setEnabled(widget.force);
  }

  @override
  void dispose() {
    if (identical(NativeMouseCursor._overlay, _controller)) {
      NativeMouseCursor._overlay = null;
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        // MouseRegion.onHover is dispatched by MouseTracker (reliable for hover);
        // Listener.onPointerMove covers movement while a button is held.
        MouseRegion(
          opaque: false,
          onHover: (e) => _controller.updatePosition(e.localPosition),
          onExit: (e) => _controller.pointerExited(),
          child: Listener(
            onPointerMove: (e) => _controller.updatePosition(e.localPosition),
            child: widget.child,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _CursorOverlayPainter(_controller)),
          ),
        ),
      ],
    );
  }
}

/// Paints the active cursor's baked bitmap at the pointer position, anchored by
/// the cursor's hotspot. Repaints whenever the controller notifies.
class _CursorOverlayPainter extends CustomPainter {
  _CursorOverlayPainter(this._controller) : super(repaint: _controller);

  final _CursorOverlayController _controller;

  @override
  void paint(Canvas canvas, Size size) {
    if (!_controller.enabled) return;
    final cache = NativeMouseCursor._managed;
    if (cache == null) return;
    final dpr = cache.devicePixelRatio;
    final paint = Paint()..filterQuality = FilterQuality.high;

    // Draw the baked bitmap for [key] with its hotspot (logical, box space)
    // landing on [at]. The bitmap is in device pixels; draw it at logical size.
    void drawAt(String key, Offset at) {
      final baked = cache._bitmaps[key];
      if (baked == null) return;
      final w = baked.image.width / dpr;
      final h = baked.image.height / dpr;
      final src = Rect.fromLTWH(
        0,
        0,
        baked.image.width.toDouble(),
        baked.image.height.toDouble(),
      );
      final dst = Rect.fromLTWH(
        at.dx - baked.hotspot.dx,
        at.dy - baked.hotspot.dy,
        w,
        h,
      );
      canvas.drawImageRect(baked.image, src, dst, paint);
    }

    // Infinite-drag wrap cursor: an explicit key at an explicit position, painted
    // even with no active hover session (the pointer is locked + hidden). While
    // it's set it IS the cursor, so skip the frozen hover-session cursor below —
    // otherwise both show at once (the "two cursors" bug).
    final wrapKey = _controller._wrapKey;
    final wrapPos = _controller._wrapPosition;
    if (wrapKey != null && wrapPos != null) {
      drawAt(wrapKey, wrapPos);
      return;
    }

    // Normal per-region cursor sessions, painted at the last hover position.
    final pos = _controller._lastPosition;
    if (pos != null && _controller._active.isNotEmpty) {
      for (final key in _controller._active.values) {
        drawAt(key, pos);
      }
    }
  }

  @override
  bool shouldRepaint(_CursorOverlayPainter oldDelegate) => false;
}

/// A transient, self-contained painted cursor for a web infinite drag — shows a
/// cursor at the wrapped lock position **without** wrapping your app in a
/// [NativeMouseCursorOverlay]. While the pointer is locked the OS cursor is
/// hidden; this paints the baked bitmap of a registered cursor in a temporary
/// [OverlayEntry] you put up only for the drag.
///
/// Drive it from [InfiniteDragController.start]'s `onCursorWrap`:
/// ```dart
/// DragCursorOverlay? _cursor;
/// // onPointerDown:
/// _cursor = DragCursorOverlay.show(context,
///     cursor: NativeMouseCursor.get('scrub') as NativeMouseCursor);
/// _drag.start(e.position,
///   onLockedDelta: (d) => apply(d.dx),
///   viewportSize: MediaQuery.sizeOf(context),
///   onCursorWrap: (p) => _cursor?.update(p));
/// // onPointerUp:
/// _cursor?.remove();
/// _cursor = null;
/// ```
class DragCursorOverlay {
  DragCursorOverlay._(this._entry, this._position);

  final OverlayEntry _entry;
  final ValueNotifier<Offset?> _position;

  /// Insert a transient overlay into the root [Overlay] above [context] that
  /// paints [cursor]'s baked bitmap at the position you feed [update]
  /// (overlay-local logical px; the cursor's hotspot lands on it). Returns null
  /// if there's no [Overlay] above [context].
  static DragCursorOverlay? show(
    BuildContext context, {
    required NativeMouseCursor cursor,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return null;
    // Keep the baked bitmap alive (it would otherwise be freed after the native
    // cursor is built).
    NativeMouseCursor._cache.enableRetention();
    final position = ValueNotifier<Offset?>(null);
    final entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(painter: _DragCursorPainter(cursor.key, position)),
        ),
      ),
    );
    overlay.insert(entry);
    return DragCursorOverlay._(entry, position);
  }

  /// Move the painted cursor to [position] (overlay-local logical px). Call from
  /// `onCursorWrap`. Pass null to hide it.
  void update(Offset? position) => _position.value = position;

  /// Remove the overlay and release it. Call on drag end / cancel.
  void remove() {
    _entry.remove();
    _position.dispose();
  }
}

/// Paints the baked bitmap keyed by [_key] at [_position] (its hotspot on the
/// point), repainting whenever the position changes.
class _DragCursorPainter extends CustomPainter {
  _DragCursorPainter(this._key, this._position) : super(repaint: _position);

  final String _key;
  final ValueListenable<Offset?> _position;

  @override
  void paint(Canvas canvas, Size size) {
    final pos = _position.value;
    if (pos == null) return;
    final cache = NativeMouseCursor._managed;
    if (cache == null) return;
    final baked = cache._bitmaps[_key];
    if (baked == null) return;
    final dpr = cache.devicePixelRatio;
    final w = baked.image.width / dpr;
    final h = baked.image.height / dpr;
    final src = Rect.fromLTWH(
      0,
      0,
      baked.image.width.toDouble(),
      baked.image.height.toDouble(),
    );
    final dst = Rect.fromLTWH(
      pos.dx - baked.hotspot.dx,
      pos.dy - baked.hotspot.dy,
      w,
      h,
    );
    canvas.drawImageRect(
      baked.image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_DragCursorPainter old) => old._key != _key;
}
