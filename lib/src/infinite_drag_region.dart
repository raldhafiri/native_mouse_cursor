// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../native_mouse_cursor.dart';

/// A drop-in **infinite-drag** region: wrap any widget and get an unbounded
/// value scrub, with all the per-platform / per-browser Pointer Lock vs
/// edge-warp machinery handled for you.
///
/// ```dart
/// double value = 0;
/// InfiniteDragRegion(
///   cursor: NativeMouseCursor.get('scrub', fallback: SystemMouseCursors.resizeLeftRight),
///   onScrub: (delta) => setState(() => value += delta.dx * 0.25),
///   child: Text('$value'),
/// );
/// ```
///
/// What it does automatically (the same logic you'd otherwise hand-roll):
///  * **desktop** — drags with the OS pointer warping at the window edge, so the
///    value can grow forever without the cursor leaving the app.
///  * **web — Chrome / Safari / Edge** — press-drag via Pointer Lock.
///  * **web — Firefox** — click-to-engage via Pointer Lock (Firefox grants a
///    lock only from a `click`): click to start scrubbing, move, click / Esc to
///    stop.
///  * On web, when [cursor] is a [NativeMouseCursor], paints that baked cursor as
///    a **wrapping** cursor while locked (the real one is hidden) so it never
///    leaves the viewport.
///
/// [onScrub] receives the *effective* delta (logical px) each frame — apply it to
/// your value, scaled however you like. For a [InfiniteDragAxis.horizontal] axis
/// use `delta.dx`; for vertical, `delta.dy`; for both, the whole offset.
///
/// For finer control, the lower-level [InfiniteDragController] is still available.
class InfiniteDragRegion extends StatefulWidget {
  const InfiniteDragRegion({
    super.key,
    required this.child,
    required this.onScrub,
    this.onActiveChanged,
    this.axis = InfiniteDragAxis.horizontal,
    this.cursor,
  });

  /// The draggable content.
  final Widget child;

  /// Called each frame with the effective drag delta (logical px) to apply.
  final void Function(Offset delta) onScrub;

  /// Called when a scrub starts (`true`) and ends (`false`) — handy to highlight
  /// the control or show a hint while dragging.
  final void Function(bool active)? onActiveChanged;

  /// Which axis (or axes) the drag scrubs / wraps on.
  final InfiniteDragAxis axis;

  /// The cursor for the region, e.g.
  /// `NativeMouseCursor.get('scrub', fallback: SystemMouseCursors.resizeLeftRight)`.
  /// When it resolves to a [NativeMouseCursor], that baked glyph is also painted
  /// as the wrapping cursor on web while the pointer is locked (and hidden), so
  /// it never leaves the viewport.
  ///
  /// Leave it `null` (the default) to keep whatever cursor is already in effect:
  /// the region defers to the ambient / child cursor and nothing is pinned during
  /// the drag. Provide one to show — and, on desktop, **pin across the edge
  /// warps** — a specific cursor.
  final MouseCursor? cursor;

  @override
  State<InfiniteDragRegion> createState() => _InfiniteDragRegionState();
}

class _InfiniteDragRegionState extends State<InfiniteDragRegion> {
  late final InfiniteDragController _drag = InfiniteDragController(
    axis: widget.axis,
  );
  DragCursorOverlay? _cursor;
  OverlayEntry? _cursorLock; // app-wide cursor pin while warping
  Offset _wrapPos = Offset.zero;

  // Firefox can't lock on a press (pointerdown) — it uses a native click toggle.
  bool get _firefoxWeb => kIsWeb && _drag.isFirefoxWeb;

  @override
  void initState() {
    super.initState();
    if (_firefoxWeb) {
      _drag.startScrub(
        onLockedDelta: _applyLocked,
        onActive: (active) {
          active ? _showWrapCursor() : _hideWrapCursor();
          widget.onActiveChanged?.call(active);
        },
      );
    }
  }

  @override
  void dispose() {
    if (_firefoxWeb) _drag.stopScrub();
    _hideWrapCursor();
    _unlockAppCursor();
    _drag.dispose();
    super.dispose();
  }

  // The lock path (web): raw motion is already the effective scrub delta.
  void _applyLocked(Offset d) {
    if (!mounted) return;
    widget.onScrub(d);
    _advanceWrapCursor(d);
  }

  void _showWrapCursor() {
    final cursor = widget.cursor;
    if (!kIsWeb || cursor is! NativeMouseCursor || !mounted) return;
    final vp = MediaQuery.sizeOf(context);
    _wrapPos = Offset(vp.width / 2, vp.height / 2);
    _cursor ??= DragCursorOverlay.show(context, cursor: cursor);
    _cursor?.update(_wrapPos);
  }

  void _hideWrapCursor() {
    _cursor?.remove();
    _cursor = null;
  }

  // While WARPING (desktop / Wayland-warp), the OS pointer jumps to the opposite
  // edge — landing on a different widget, which would otherwise flip the cursor
  // to that region's (the system default). Pin [cursor] across the whole app for
  // the duration of the drag so it stays put through every warp. Harmless on the
  // lock path (the real cursor is hidden there); opaque:false lets the drag
  // events fall through to the widgets underneath.
  void _lockAppCursor() {
    // No explicit cursor → nothing to pin; leave the ambient/child cursor as-is.
    final cursor = widget.cursor;
    if (cursor == null || _cursorLock != null || !mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _cursorLock = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: MouseRegion(
          cursor: cursor,
          opaque: false,
          child: const SizedBox.expand(),
        ),
      ),
    );
    overlay.insert(_cursorLock!);
  }

  void _unlockAppCursor() {
    _cursorLock?.remove();
    _cursorLock = null;
  }

  void _advanceWrapCursor(Offset d) {
    if (_cursor == null || !mounted) return;
    _wrapPos = InfiniteDragController.wrapPosition(
      _wrapPos,
      d,
      MediaQuery.sizeOf(context),
      widget.axis,
    );
    _cursor!.update(_wrapPos);
  }

  // Press-drag (web Chrome/Safari/Edge) + warp (desktop).
  Future<void> _onStart(Offset globalPosition) async {
    widget.onActiveChanged?.call(true);
    _lockAppCursor(); // keep the cursor put across edge warps
    _showWrapCursor();
    await _drag.start(
      globalPosition,
      onLockedDelta: _applyLocked, // web lock path
      viewportSize: MediaQuery.sizeOf(context),
    );
  }

  Future<void> _onUpdate(Offset globalPosition, Offset delta) async {
    // Warp path (desktop) drives the value here; the lock path returns zero and
    // is driven by [_applyLocked] via the controller's ticker instead.
    final eff = await _drag.updateOffset(
      globalPosition: globalPosition,
      delta: delta,
      viewportSize: MediaQuery.sizeOf(context),
    );
    if (eff != Offset.zero) widget.onScrub(eff);
  }

  void _onEnd() {
    _drag.end();
    _hideWrapCursor();
    _unlockAppCursor();
    widget.onActiveChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    final region = MouseRegion(
      cursor: widget.cursor ?? MouseCursor.defer,
      // Arm the web lock while hovering, so a press/click here engages a scrub.
      onEnter: (_) => _drag.armPointerLock(true),
      onExit: (_) => _drag.armPointerLock(false),
      child: widget.child,
    );
    // Firefox engages via a native click (handled in the web plugin) — no Flutter
    // gesture needed. Everyone else uses press-drag / warp.
    if (_firefoxWeb) return region;
    return _withGesture(region);
  }

  Widget _withGesture(Widget child) {
    switch (widget.axis) {
      case InfiniteDragAxis.horizontal:
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => _onStart(d.globalPosition),
          onHorizontalDragUpdate: (d) => _onUpdate(d.globalPosition, d.delta),
          onHorizontalDragEnd: (_) => _onEnd(),
          onHorizontalDragCancel: _onEnd,
          child: child,
        );
      case InfiniteDragAxis.vertical:
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) => _onStart(d.globalPosition),
          onVerticalDragUpdate: (d) => _onUpdate(d.globalPosition, d.delta),
          onVerticalDragEnd: (_) => _onEnd(),
          onVerticalDragCancel: _onEnd,
          child: child,
        );
      case InfiniteDragAxis.both:
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _onStart(d.globalPosition),
          onPanUpdate: (d) => _onUpdate(d.globalPosition, d.delta),
          onPanEnd: (_) => _onEnd(),
          onPanCancel: _onEnd,
          child: child,
        );
    }
  }
}
