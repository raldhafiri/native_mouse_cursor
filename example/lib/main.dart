// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:native_mouse_cursor/native_mouse_cursor.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Toggles the in-app painted overlay (hides the system cursor). Meaningful on
  // web/desktop, where the system cursor can be hidden.
  bool _force = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF5B5BD6),
        brightness: Brightness.light,
      ),
      // Wrap the whole app once. Pass-through where a native/CSS cursor exists;
      // `force` paints the overlay everywhere.
      builder: (context, child) =>
          NativeMouseCursorOverlay(force: _force, child: child!),
      home: ShowcasePage(
        force: _force,
        onForceChanged: (v) => setState(() => _force = v),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class ShowcasePage extends StatefulWidget {
  const ShowcasePage({
    super.key,
    required this.force,
    required this.onForceChanged,
  });

  final bool force;
  final ValueChanged<bool> onForceChanged;

  @override
  State<ShowcasePage> createState() => _ShowcasePageState();
}

// `NativeMouseCursorMixin` auto-configures the bake DPR and rebuilds when a
// cursor finishes baking — so the demos can just call `get` from `build`.
class _ShowcasePageState extends State<ShowcasePage>
    with NativeMouseCursorMixin {
  bool _registered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_registered) {
      _registered = true;
      _registerCursors();
    }
  }

  Future<void> _registerCursors() async {
    const box = ui.Size(30, 30);
    // The pointer's natural click point is its tip, in glyph coords → (2.1, 0.9).
    final tip = ui.Offset(_arrowTip.dx * box.width, _arrowTip.dy * box.height);

    // draw — pivots on its TIP (the hotspot is the rotation origin) to aim at
    // the dot.
    NativeMouseCursor.draw('rotate', size: box, painter: _arrow, hotspot: tip);

    // hotspot demo — the SAME glyph with a tip hotspot vs a centre hotspot.
    NativeMouseCursor.draw('tip', size: box, painter: _arrow, hotspot: tip);
    NativeMouseCursor.draw('centre', size: box, painter: _arrow);

    // shadow on / off — a natural pointer (tip is the click point).
    NativeMouseCursor.draw(
      'shadowed',
      size: box,
      painter: _arrow,
      hotspot: tip,
    );
    NativeMouseCursor.draw(
      'plain',
      size: box,
      painter: _arrow,
      shadow: null,
      hotspot: tip,
    );

    // image — the pointer; the mirroring demo flips it horizontally with flipX.
    NativeMouseCursor.image(
      'hand',
      await _arrowImage(64),
      size: box,
      hotspot: tip,
    );

    // the four source types, side by side (tip hotspot; the builder ring is
    // symmetric so its centre default is fine).
    NativeMouseCursor.svg(
      'src_svg',
      'assets/pointer.svg',
      size: box,
      hotspot: tip,
    );
    NativeMouseCursor.image(
      'src_img',
      await _arrowImage(64),
      size: box,
      hotspot: tip,
    );
    NativeMouseCursor.draw(
      'src_draw',
      size: box,
      painter: (c, s) => _arrow(c, s, fill: const ui.Color(0xFFBBE1FF)),
      hotspot: tip,
    );
    NativeMouseCursor.builder('src_builder', build: _builderCursor);

    // A custom ↔ resize glyph for the infinite-drag demo — a real baked OS
    // cursor (centre hotspot), shown while dragging the number.
    NativeMouseCursor.draw(
      'scrub',
      size: const ui.Size(28, 20),
      painter: _scrubArrows,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final modeLabel = widget.force
        ? 'Overlay'
        : (kIsWeb ? 'CSS url()' : 'Native OS');
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: scheme.surfaceContainerLowest,
        titleSpacing: 20,
        title: const Text(
          'native_mouse_cursor',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(modeLabel),
                  avatar: Icon(
                    widget.force ? Icons.brush_outlined : Icons.mouse_outlined,
                    size: 16,
                  ),
                ),
                const SizedBox(width: 8),
                Switch(value: widget.force, onChanged: widget.onForceChanged),
                const Tooltip(
                  message:
                      'Paint the cursor in-app and hide the\n'
                      'system cursor (web / desktop)',
                  child: Icon(Icons.info_outline, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
      // Fill the window width — no centered max-width column, which left
      // annoying empty gaps on the left and right of the scroll area on a wide
      // window. Comfortable side padding keeps the cards off the edges.
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Text(
              'Real OS mouse cursors from your own glyphs. Hover each demo.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          _DemoCard(
            icon: Icons.rotate_right,
            title: 'Rotation',
            description:
                'One get(id, angle:) call — the arrow rotates to aim at the '
                'dot. Each angle is baked once and cached.',
            child: _RotationDemo(),
          ),
          _DemoCard(
            icon: Icons.flip,
            title: 'Mirroring',
            description:
                'Move between quadrants — flipX / flipY mirror one registered '
                'glyph on demand (no second asset). The tip stays on the '
                'pointer.',
            child: _MirrorDemo(),
          ),
          _DemoCard(
            icon: Icons.my_location,
            title: 'Hotspot',
            description:
                'The red dot marks the true pointer position — i.e. the '
                'hotspot. Same glyph, two hotspots: see it at the tip vs the '
                'centre.',
            child: _HotspotDemo(),
          ),
          _DemoCard(
            icon: Icons.contrast,
            title: 'Baked drop shadow',
            description:
                'A CSS-style shadow baked into the bitmap — rock-steady '
                'at every angle, never shimmering.',
            child: _ShadowDemo(),
          ),
          _DemoCard(
            icon: Icons.category_outlined,
            title: 'Cursor sources',
            description:
                'Register a glyph from an SVG, a ui.Image, a painter, or a '
                'custom per-angle builder.',
            child: _SourcesDemo(),
          ),
          _DemoCard(
            icon: Icons.swap_horiz,
            title: 'Infinite drag',
            description:
                'Drag the number to change it — one InfiniteDragRegion. The '
                'pointer wraps at the window edge on desktop; on web it uses '
                'Pointer Lock (press-drag on Chrome/Safari/Edge, click-to-engage '
                'on Firefox) with a wrapping cursor.',
            child: _ScrubDemo(),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────── demos ─────────────────────────────────────

class _RotationDemo extends StatefulWidget {
  @override
  State<_RotationDemo> createState() => _RotationDemoState();
}

class _RotationDemoState extends State<_RotationDemo> {
  double _angle = 0;

  @override
  Widget build(BuildContext context) {
    return _Stage(
      height: 220,
      child: LayoutBuilder(
        builder: (context, c) {
          final center = Offset(c.maxWidth / 2, c.maxHeight / 2);
          // Turn the pointer so its tip aims from the cursor at the dot.
          void aim(Offset local) {
            final d = center - local;
            setState(() => _angle = math.atan2(d.dy, d.dx) - _arrowForward);
          }

          return MouseRegion(
            cursor: NativeMouseCursor.get('rotate', angle: _angle),
            // onHover only fires while NO button is pressed. Pair it with a
            // Listener.onPointerMove so the cursor keeps aiming even while a
            // button is held down (otherwise the angle freezes on press).
            onHover: (e) => aim(e.localPosition),
            child: Listener(
              onPointerMove: (e) => aim(e.localPosition),
              child: CustomPaint(
                painter: _DotPainter(Theme.of(context).colorScheme.primary),
                child: const SizedBox.expand(),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MirrorDemo extends StatefulWidget {
  @override
  State<_MirrorDemo> createState() => _MirrorDemoState();
}

class _MirrorDemoState extends State<_MirrorDemo> {
  bool _flipX = false;
  bool _flipY = false;

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).colorScheme.outlineVariant;
    return _Stage(
      height: 200,
      child: LayoutBuilder(
        builder: (context, c) {
          final center = Offset(c.maxWidth / 2, c.maxHeight / 2);
          // Pick the flip from which quadrant the pointer is in.
          void update(Offset local) {
            final fx = local.dx > center.dx; // right half
            final fy = local.dy > center.dy; // bottom half
            if (fx != _flipX || fy != _flipY) {
              setState(() {
                _flipX = fx;
                _flipY = fy;
              });
            }
          }

          return MouseRegion(
            cursor: NativeMouseCursor.get('hand', flipX: _flipX, flipY: _flipY),
            // onHover fires only with no button pressed; pair with onPointerMove
            // so it still works while a button is held.
            onHover: (e) => update(e.localPosition),
            child: Listener(
              onPointerMove: (e) => update(e.localPosition),
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: _cell('—', !_flipX && !_flipY)),
                        VerticalDivider(width: 1, color: divider),
                        Expanded(child: _cell('flipX', _flipX && !_flipY)),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: divider),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: _cell('flipY', !_flipX && _flipY)),
                        VerticalDivider(width: 1, color: divider),
                        Expanded(
                          child: _cell('flipX · flipY', _flipX && _flipY),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _cell(String label, bool active) {
    final primary = Theme.of(context).colorScheme.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      color: active ? primary.withValues(alpha: 0.10) : Colors.transparent,
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontWeight: active ? FontWeight.w700 : FontWeight.w400,
          color: active ? primary : Colors.black54,
        ),
      ),
    );
  }
}

class _HotspotDemo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: Row(
        children: [
          Expanded(
            child: _HotspotTarget(label: 'tip hotspot', id: 'tip'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _HotspotTarget(label: 'centre hotspot', id: 'centre'),
          ),
        ],
      ),
    );
  }
}

class _HotspotTarget extends StatefulWidget {
  const _HotspotTarget({required this.label, required this.id});
  final String label;
  final String id;

  @override
  State<_HotspotTarget> createState() => _HotspotTargetState();
}

class _HotspotTargetState extends State<_HotspotTarget> {
  Offset? _pointer;

  @override
  Widget build(BuildContext context) {
    return _Stage(
      height: 150,
      child: MouseRegion(
        cursor: NativeMouseCursor.get(widget.id),
        // onHover fires only with no button pressed; pair with onPointerMove so
        // the red dot tracks the pointer even while a button is held.
        onHover: (e) => setState(() => _pointer = e.localPosition),
        onExit: (e) => setState(() => _pointer = null),
        child: Listener(
          onPointerMove: (e) => setState(() => _pointer = e.localPosition),
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                painter: _PointerDotPainter(_pointer),
                child: const SizedBox.expand(),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    widget.label,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              if (_pointer == null)
                Text(
                  'hover here',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.black38),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShadowDemo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Row(
        children: [
          Expanded(
            child: _Swatch(label: 'with shadow', id: 'shadowed'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Swatch(label: 'no shadow', id: 'plain'),
          ),
        ],
      ),
    );
  }
}

class _SourcesDemo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const items = [
      ('SVG', 'src_svg'),
      ('Image', 'src_img'),
      ('Painter', 'src_draw'),
      ('Builder', 'src_builder'),
    ];
    return SizedBox(
      height: 110,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: _Swatch(label: items[i].$1, id: items[i].$2),
            ),
          ],
        ],
      ),
    );
  }
}

/// Infinite-drag demo: drag the big number to change it. [InfiniteDragRegion]
/// handles the per-platform machinery — desktop edge-warp, web Chrome/Safari/Edge
/// press-drag, web Firefox click-to-engage — plus the wrapping cursor on web.
class _ScrubDemo extends StatefulWidget {
  @override
  State<_ScrubDemo> createState() => _ScrubDemoState();
}

class _ScrubDemoState extends State<_ScrubDemo> {
  double _value = 50;
  double _raw = 50; // fractional accumulator; the label shows the rounded int
  bool _scrubbing = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Stage(
      height: 180,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            InfiniteDragRegion(
              cursor: NativeMouseCursor.get(
                'scrub',
                fallback: SystemMouseCursors.resizeLeftRight,
              ),
              onActiveChanged: (a) => setState(() => _scrubbing = a),
              onScrub: (delta) => setState(() {
                _raw += delta.dx * 0.25; // 0.25 units per logical px
                _value = _raw.roundToDouble();
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 8,
                ),
                child: Text(
                  _value.toInt().toString(),
                  style: TextStyle(
                    fontSize: 64,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: _scrubbing ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _scrubbing ? 'scrubbing…' : '← drag the number →',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints a horizontal double-headed (↔) scrub arrow into a [size] box as ONE
/// combined outline: a thin centre bar with a triangular arrowhead at each end,
/// traced as a single closed path so it fills + strokes as one clean shape.
void _scrubArrows(ui.Canvas canvas, ui.Size size) {
  final w = size.width, h = size.height;
  final cy = h / 2;
  final head = w * 0.30; // arrowhead length (each side)
  final ah = h * 0.46; // arrowhead half-height (the wide tip)
  final bar = h * 0.16; // shaft half-thickness

  // Trace the silhouette clockwise from the left tip: out to the top of the
  // left head, in to the bar, across the top of the bar, out to the top of the
  // right head, around the right tip, and symmetrically back along the bottom.
  final path = ui.Path()
    ..moveTo(0, cy) // left tip
    ..lineTo(head, cy - ah) // up the left head
    ..lineTo(head, cy - bar) // in to the shaft (top)
    ..lineTo(w - head, cy - bar) // across the shaft top
    ..lineTo(w - head, cy - ah) // out to the right head top
    ..lineTo(w, cy) // right tip
    ..lineTo(w - head, cy + ah) // down the right head
    ..lineTo(w - head, cy + bar) // in to the shaft (bottom)
    ..lineTo(head, cy + bar) // back across the shaft bottom
    ..lineTo(head, cy + ah) // out to the left head bottom
    ..close();

  canvas.drawPath(path, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  canvas.drawPath(
    path,
    ui.Paint()
      ..color = const ui.Color(0xFF1A1A1A)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = h * 0.10
      ..strokeJoin = ui.StrokeJoin.round,
  );
}

// ──────────────────────────────── building blocks ────────────────────────────

/// A titled, described card wrapping a demo stage.
class _DemoCard extends StatelessWidget {
  const _DemoCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 16),
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(description, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// A rounded, soft-filled interactive area.
class _Stage extends StatelessWidget {
  const _Stage({required this.height, required this.child});
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: child,
        ),
      ),
    );
  }
}

/// A labelled swatch that shows the cursor registered under [id].
class _Swatch extends StatelessWidget {
  const _Swatch({required this.label, required this.id});
  final String label;
  final String id;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: NativeMouseCursor.get(id),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

/// Draws the target dot the rotation arrow points at.
class _DotPainter extends CustomPainter {
  _DotPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    canvas.drawCircle(center, 9, Paint()..color = color);
    canvas.drawCircle(
      center,
      17,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.35),
    );
  }

  @override
  bool shouldRepaint(_DotPainter oldDelegate) => oldDelegate.color != color;
}

/// Marks the true pointer position with a red dot — i.e. where the cursor's
/// hotspot sits. Compare it against the rendered glyph's tip vs centre.
class _PointerDotPainter extends CustomPainter {
  _PointerDotPainter(this.point);
  final Offset? point;

  @override
  void paint(Canvas canvas, Size size) {
    final p = point;
    if (p == null) return;
    canvas
      ..drawCircle(p, 5, Paint()..color = Colors.white)
      ..drawCircle(p, 3.5, Paint()..color = const Color(0xFFE53935));
  }

  @override
  bool shouldRepaint(_PointerDotPainter oldDelegate) =>
      oldDelegate.point != point;
}

// ──────────────────────────────── glyph painters ─────────────────────────────

// The classic OS pointer: tip at the top-left, tail leg to the bottom. Outline
// in normalised (0..1) box coords; the tip is what aims/clicks.
const _arrowTip = ui.Offset(0.07, 0.03);
const _arrowOutline = <ui.Offset>[
  ui.Offset(0.07, 0.03), // tip
  ui.Offset(0.07, 0.74), // left edge, down
  ui.Offset(0.27, 0.59), // notch base, left
  ui.Offset(0.40, 0.93), // tail leg, bottom-left
  ui.Offset(0.52, 0.88), // tail leg, bottom-right
  ui.Offset(0.39, 0.55), // notch base, right
  ui.Offset(0.66, 0.52), // right wing
];

// The angle the tip points at rotation 0 (from the box centre), so the rotation
// demo can turn it to aim anywhere.
final double _arrowForward = math.atan2(_arrowTip.dy - 0.5, _arrowTip.dx - 0.5);

/// Paints the pointer into a [size]-logical box.
void _arrow(
  ui.Canvas canvas,
  ui.Size size, {
  ui.Color fill = const ui.Color(0xFFFFFFFF),
}) {
  final w = size.width, h = size.height;
  final path = ui.Path()
    ..moveTo(_arrowOutline.first.dx * w, _arrowOutline.first.dy * h);
  for (final o in _arrowOutline.skip(1)) {
    path.lineTo(o.dx * w, o.dy * h);
  }
  path.close();
  canvas.drawPath(path, ui.Paint()..color = fill);
  canvas.drawPath(
    path,
    ui.Paint()
      ..color = const ui.Color(0xFF1A1A1A)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = w * 0.07
      ..strokeJoin = ui.StrokeJoin.round,
  );
}

/// Rasterises the pointer into a [px]² image.
Future<ui.Image> _arrowImage(int px) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  _arrow(canvas, ui.Size(px.toDouble(), px.toDouble()));
  return recorder.endRecording().toImage(px, px);
}

/// A custom per-angle builder cursor: a ringed dot (here angle-independent).
Future<ui.Image> _builderCursor(double angle, double dpr) {
  const logical = 26.0;
  final px = (logical * dpr).round();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(dpr);
  const center = ui.Offset(logical / 2, logical / 2);
  canvas.drawCircle(
    center,
    logical * 0.42,
    ui.Paint()..color = const ui.Color(0xFF7E57C2),
  );
  canvas.drawCircle(
    center,
    logical * 0.42,
    ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = const ui.Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(px, px);
}
