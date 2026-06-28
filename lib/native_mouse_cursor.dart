// Copyright (c) 2026 Rami Al-Dhafiri.
// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'native_mouse_cursor_platform_interface.dart';

export 'infinite_drag.dart';

part 'native_mouse_cursor_overlay.dart';

/// A real **OS mouse cursor** built from your own glyph.
///
/// Because the operating system draws it, the cursor (and any shadow baked into
/// it) tracks the pointer with zero lag and never shimmers — unlike a
/// Flutter-painted overlay that chases the pointer a frame behind.
///
/// The whole API is: **register a source, then [get] it.**
///
/// ```dart
/// // once (and again on a DPR change):
/// NativeMouseCursor.configure(devicePixelRatio: dpr, onReady: () => setState(() {}));
///
/// // register a glyph under an id — pick the source that fits:
/// NativeMouseCursor.svg('rotate', 'assets/icons/rotate.svg'); // size + shadow defaulted
///
/// // use it anywhere a MouseCursor works:
/// MouseRegion(
///   cursor: NativeMouseCursor.get('rotate', angle: handleAngle),
///   child: handle,
/// );
/// ```
///
/// The package owns everything hard behind those calls: loading the glyph,
/// rotation, the baked drop shadow, automatic bitmap sizing, an angle-keyed
/// cache, background warming and DPR re-baking.
class NativeMouseCursor extends MouseCursor {
  const NativeMouseCursor._(this.key);

  /// The native registry key identifying this baked cursor variant.
  final String key;

  // ───────────────────────────── configure ───────────────────────────────────

  /// Set the [devicePixelRatio] to bake at and an [onReady] callback (typically
  /// `setState`) fired when a cursor finishes building. Optional — without it
  /// the DPR defaults to 1. Call it again when the DPR changes: bitmaps re-bake,
  /// registrations are kept.
  static void configure({
    required double devicePixelRatio,
    VoidCallback? onReady,
    int angleBucketDegrees = 4,
  }) {
    final m = _managed ??= _CursorCache(
        devicePixelRatio: devicePixelRatio,
        angleBucketDegrees: angleBucketDegrees);
    if (onReady != null) m.onCursorReady = onReady;
    m.devicePixelRatio = devicePixelRatio;
  }

  // ──────────────────────── register a cursor source ──────────────────────────
  // Each registers a glyph under [id]; the bitmap box is sized AUTOMATICALLY to
  // fit the rotated glyph + shadow, and the hotspot (the click point, in the
  // glyph's own coords) defaults to its centre. Fetch the result with [get].

  /// Register the SVG [asset] under [id], drawn at [size] (default: the SVG's
  /// own size). Re-rasterised crisply from the vector per rotation bucket + DPR.
  /// A default [shadow] is baked in; pass `shadow: null` for none.
  static void svg(
    String id,
    String asset, {
    ui.Size? size,
    NativeCursorShadow? shadow = const NativeCursorShadow(),
    ui.Offset? hotspot,
  }) =>
      _cache.register(_SvgSource(
          id: id,
          asset: asset,
          size: size,
          shadow: shadow,
          hotspot: hotspot));

  /// Register a decoded [image] under [id], drawn at [size] (default: the
  /// image's pixels as logical units — render it at a comfortable resolution).
  /// A default [shadow] is baked in; pass `shadow: null` for none.
  static void image(
    String id,
    ui.Image image, {
    ui.Size? size,
    NativeCursorShadow? shadow = const NativeCursorShadow(),
    ui.Offset? hotspot,
  }) =>
      _cache.register(_ImageSource(
          id: id,
          image: image,
          size: size,
          shadow: shadow,
          hotspot: hotspot));

  /// Register a hand-[painter]ed glyph under [id]: paint into a [size]-logical
  /// box; the package scales it to the DPR, rotates about the centre by the
  /// `get` angle, and bakes the [shadow] (a default one; pass `shadow: null` for
  /// none).
  static void draw(
    String id, {
    required ui.Size size,
    required CursorPainter painter,
    NativeCursorShadow? shadow = const NativeCursorShadow(),
    ui.Offset? hotspot,
  }) =>
      _cache.register(_DrawSource(
          id: id,
          size: size,
          painter: painter,
          shadow: shadow,
          hotspot: hotspot));

  /// Register a fully custom source under [id]: produce the bitmap yourself for
  /// a given angle (radians) + DPR.
  static void builder(
    String id, {
    required Future<ui.Image> Function(double angle, double devicePixelRatio)
        build,
    ui.Offset? hotspot,
  }) =>
      _cache.register(
          _BuilderSource(id: id, build: build, hotspot: hotspot));

  // ───────────────────────────────── fetch ───────────────────────────────────

  /// The cursor registered under [id] at [angle] (radians), optionally mirrored
  /// with [flipX]/[flipY]. Each (angle, flip) combination is baked + cached on
  /// demand; the unflipped variant is warmed in the background, so it's usually
  /// ready on the first hover. The nearest already-baked angle of the same flip
  /// is returned meanwhile.
  ///
  /// Never returns null — until the bitmap is registered and baked it returns
  /// [fallback] (default [SystemMouseCursors.basic]), so it drops straight into
  /// a `MouseRegion(cursor: …)` with no `??`. Pass [fallback] to pick the
  /// stand-in shown for that first frame (e.g. `SystemMouseCursors.grab`).
  static MouseCursor get(
    String id, {
    double angle = 0,
    bool flipX = false,
    bool flipY = false,
    MouseCursor fallback = SystemMouseCursors.basic,
  }) =>
      _cache.get(id, angle: angle, flipX: flipX, flipY: flipY) ?? fallback;

  /// Whether a cursor source is already registered under [id] — so callers can
  /// register once without tracking that themselves
  /// (`if (!NativeMouseCursor.has(id)) NativeMouseCursor.svg(id, …)`).
  static bool has(String id) => _managed?.isRegistered(id) ?? false;

  // ──────────────────────────────── dispose ──────────────────────────────────

  /// Forget the cursor registered under [id] and release its native bitmaps.
  static void dispose(String id) => _cache.disposeId(id);

  /// Forget every registered cursor and release all native bitmaps.
  static void disposeAll() => _managed?.disposeAll();

  // ─────────────────────────── pointer warping ────────────────────────────────

  /// Teleport the OS pointer to ([x], [y]) in Flutter-LOGICAL window
  /// coordinates (top-left origin, y-down — the same space as
  /// `PointerEvent.position`).
  ///
  /// This is the low-level primitive behind an **infinite drag**
  /// (a value scrub): warp the pointer to the opposite edge when it reaches
  /// the window border so the drag never runs out of room. Most consumers don't
  /// call this directly — they drive an [InfiniteDragController], which handles
  /// the edge math (and the web's pointer-lock fallback) for you.
  ///
  /// Native on macOS / Windows / Linux-X11; a graceful no-op on web, mobile and
  /// Linux-Wayland (see [InfiniteDragController]).
  ///
  /// Pass [viewportWidth]/[viewportHeight] (the logical window size) when known
  /// — on Windows it makes the warp exact at fractional display scales (e.g.
  /// 250%); [InfiniteDragController] always supplies them.
  static Future<void> warpPointer(
    double x,
    double y, {
    double? viewportWidth,
    double? viewportHeight,
  }) =>
      NativeMouseCursorPlatform.instance.warpPointer(
        x,
        y,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
      );

  /// Whether this host can teleport the pointer via [warpPointer] — `true` on
  /// macOS / Windows / Linux-X11, `false` on web / mobile / Linux-Wayland.
  static Future<bool> canWarpPointer() =>
      NativeMouseCursorPlatform.instance.canWarpPointer();

  // ─────────────────────────── MouseCursor wiring ─────────────────────────────

  @override
  MouseCursorSession createSession(int device) =>
      _NativeMouseCursorSession(this, device);

  @override
  String get debugDescription => 'NativeMouseCursor($key)';

  @override
  bool operator ==(Object other) =>
      other is NativeMouseCursor && other.key == key;

  @override
  int get hashCode => key.hashCode;

  // ───────────────────────────────── internals ───────────────────────────────

  static _CursorCache? _managed;
  static _CursorCache get _cache =>
      _managed ??= _CursorCache(devicePixelRatio: 1.0);

  /// The active [NativeMouseCursorOverlay]'s controller, when one is mounted and
  /// has decided this platform needs the Flutter-painted fallback. Null = render
  /// natively (the default everywhere a real OS cursor exists).
  static _CursorOverlayController? _overlay;

  /// Register a baked bitmap with the OS and return its handle. [hotspot] is in
  /// the bitmap's LOGICAL (box) coordinates.
  static Future<NativeMouseCursor> _createNative(
    ui.Image image, {
    required ui.Offset hotspot,
    required double devicePixelRatio,
    required String key,
  }) async {
    if (kIsWeb) return _createWeb(image, hotspot, devicePixelRatio, key);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await NativeMouseCursorPlatform.instance.createCursor(
      key: key,
      pngBytes: data!.buffer.asUint8List(),
      width: image.width,
      height: image.height,
      hotX: (hotspot.dx * devicePixelRatio).round(),
      hotY: (hotspot.dy * devicePixelRatio).round(),
      devicePixelRatio: devicePixelRatio,
    );
    return NativeMouseCursor._(key);
  }

  /// A CSS `cursor: url(...)` image is drawn at its intrinsic pixels = CSS
  /// pixels (browsers do NOT divide by devicePixelRatio), and Chrome ignores
  /// cursors larger than 128 px. So we hand the web backend TWO bitmaps:
  ///  • `lo` — logical-size (1×), 128-capped: the universal fallback, correctly
  ///    sized everywhere but soft on HiDPI.
  ///  • `hi` — the device-resolution bitmap (128-capped): served via CSS
  ///    `image-set(... Nx)` so HiDPI browsers (Chrome/Safari) render it crisp.
  /// The hotspot is expressed in the lo bitmap's pixels (= CSS px).
  static Future<NativeMouseCursor> _createWeb(
      ui.Image src, ui.Offset hotspot, double dpr, String key) async {
    final logicalW = src.width / dpr;
    final logicalH = src.height / dpr;
    final maxLogical = math.max(logicalW, logicalH);
    final loScale = maxLogical > 128 ? 128 / maxLogical : 1.0;
    final loW = math.max(1, (logicalW * loScale).round());
    final loH = math.max(1, (logicalH * loScale).round());

    // hi: a crisp device-resolution bitmap, served via image-set at an INTEGER
    // density. Chrome lays an image-set cursor out in the 1x candidate's box and
    // then draws the chosen candidate into it; if the hi candidate's
    // density-adjusted size doesn't EXACTLY match the lo box, Chrome clips the
    // cursor (the "clipped cursor" glitch). A fractional density
    // (`hiW / loW` rounded to 2 dp) introduced exactly that mismatch. So we pin
    // the density to a whole number `k` and size hi as `loW * k` — an exact
    // multiple, so hi/k == lo and there's no rounding drift. `k` is the device
    // ratio, capped so hi never exceeds Chrome's 128 px intrinsic limit.
    var density = (src.width / loW).round();
    if (density < 1) density = 1;
    while (density > 1 && math.max(loW, loH) * density > 128) {
      density--;
    }
    final hiW = loW * density;
    final hiH = loH * density;

    final lo = await _resample(src, loW, loH);
    final hi = await _resample(src, hiW, hiH);
    final loPng = (await lo.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    final hiPng = (await hi.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    lo.dispose();
    hi.dispose();

    await NativeMouseCursorPlatform.instance.createCursorWeb(
      key: key,
      lo: loPng,
      hi: hiPng,
      density: density.toDouble(), // exact integer → no clip-causing drift
      hotX: (hotspot.dx * loScale).round(),
      hotY: (hotspot.dy * loScale).round(),
    );
    return NativeMouseCursor._(key);
  }

  /// Redraw [src] into a [w]×[h] bitmap (area-averaged downscale).
  static Future<ui.Image> _resample(ui.Image src, int w, int h) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    return recorder.endRecording().toImage(w, h);
  }
}

/// Mix into a [State] to keep [NativeMouseCursor] configured automatically: in
/// [didChangeDependencies] it points the cache at the context's
/// devicePixelRatio (re-baking on a DPR change) and rebuilds the widget when a
/// freshly-baked cursor lands. With it, you can call `NativeMouseCursor.svg` /
/// `get` straight from `build()` — no manual `configure`/`setState` wiring.
///
/// ```dart
/// class _MyState extends State<MyWidget> with NativeMouseCursorMixin {
///   @override
///   Widget build(BuildContext context) => MouseRegion(
///     cursor: NativeMouseCursor.get('rotate', angle: a),
///     child: ...,
///   );
/// }
/// ```
mixin NativeMouseCursorMixin<T extends StatefulWidget> on State<T> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    NativeMouseCursor.configure(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      onReady: () {
        if (mounted) setState(() {});
      },
    );
  }
}

class _NativeMouseCursorSession extends MouseCursorSession {
  _NativeMouseCursorSession(NativeMouseCursor super.cursor, super.device);

  NativeMouseCursor get _cursor => cursor as NativeMouseCursor;

  // True once this session has applied a web CSS cursor, so [dispose] knows to
  // clear it (and NOT to clear when the overlay path was taken, which would
  // un-hide the suppressed system pointer mid-rotation).
  bool _appliedWebCursor = false;

  @override
  Future<void> activate() async {
    final overlay = NativeMouseCursor._overlay;
    if (overlay != null && overlay.enabled) {
      // Overlay mode (force): paint the cursor in Flutter and hide the system
      // cursor (works on web/desktop, where 'none' is honoured).
      overlay.activate(device, _cursor.key);
      try {
        await SystemChannels.mouseCursor.invokeMethod<void>(
          'activateSystemCursor',
          <String, dynamic>{'device': device, 'kind': 'none'},
        );
      } catch (_) {
        // 'none' isn't honoured on every host — ignore where it isn't.
      }
      return;
    }
    if (kIsWeb) _appliedWebCursor = true;
    await NativeMouseCursorPlatform.instance.setCursor(_cursor.key);
  }

  @override
  void dispose() {
    NativeMouseCursor._overlay?.deactivate(device);
    // On web the cursor is a CSS property we own; clear it when a session that
    // set one ends so nothing lingers (leaving a region, or the overlay taking
    // over). MouseTracker disposes the old session before activating the next,
    // so a still-hovered region immediately re-sets its cursor — no flicker.
    if (_appliedWebCursor) {
      NativeMouseCursorPlatform.instance.resetCursor();
    }
  }
}

/// A drop shadow baked behind a cursor glyph.
///
/// Speaks CSS drop-shadow vocabulary: pass the blur *radius* as [blur]
/// (not a Gaussian sigma) — the baked Gaussian uses σ = [blur] / 2, the same
/// `radius * 0.5` convention as CSS `box-shadow`. The defaults
/// (`x:0, y:1, blur:1.5, black 50%`) match the macOS system-cursor shadow.
class NativeCursorShadow {
  const NativeCursorShadow({
    this.color = const ui.Color(0x80000000),
    this.offset = const ui.Offset(0, 1),
    this.blur = 1.5,
  });

  /// The glyph silhouette is recoloured to this (srcIn) then blurred; the
  /// colour's alpha is the shadow strength.
  final ui.Color color;

  /// Screen-space offset (logical px) — applied OUTSIDE the rotation, so the
  /// light stays overhead however the cursor turns.
  final ui.Offset offset;

  /// CSS drop-shadow blur *radius* (logical px) — NOT a sigma.
  final double blur;

  /// The Gaussian sigma actually baked: σ = [blur] / 2 (CSS convention).
  double get blurSigma => blur > 0 ? blur / 2 : 0.0;
}

/// Paints a cursor glyph into a [size]-logical box (top-left origin). The cache
/// applies DPR scaling, rotation and the baked shadow around this callback.
typedef CursorPainter = void Function(ui.Canvas canvas, ui.Size size);

// ─────────────────────────────── cursor sources ──────────────────────────────
// Internal: each source knows how to rasterise its glyph for an angle + DPR.
// Public registration goes through NativeMouseCursor.svg/.image/.draw/.builder.

abstract class _Source {
  const _Source({
    required this.id,
    this.hotspot,
    this.shadow,
  });

  /// Cache id — one bitmap is cached per (id, angle bucket, DPR, flip).
  final String id;

  /// Click point in the GLYPH's own logical coords (its [size] / SVG viewBox),
  /// origin top-left; null = the glyph centre. The package maps it into the
  /// auto-sized bitmap (the glyph is centred there), so callers needn't know the
  /// box size.
  final ui.Offset? hotspot;

  /// Optional drop shadow baked behind the glyph.
  final NativeCursorShadow? shadow;

  /// Rasterise the bitmap for [angle] (radians) at [dpr], optionally mirrored
  /// with [flipX]/[flipY]. Returns the bitmap and its hotspot in the bitmap's
  /// own LOGICAL px (box space).
  Future<(ui.Image, ui.Offset)> render(double angle, double dpr,
      {bool flipX = false, bool flipY = false});
}

class _SvgSource extends _Source {
  _SvgSource({
    required super.id,
    required this.asset,
    this.size,
    super.hotspot,
    super.shadow,
  });
  final String asset;
  final ui.Size? size;

  // Parse the SVG once; every bake (per angle bucket / DPR) reuses the picture.
  Future<PictureInfo>? _picture;
  Future<PictureInfo> _load() =>
      _picture ??= vg.loadPicture(SvgAssetLoader(asset), null);

  @override
  Future<(ui.Image, ui.Offset)> render(double angle, double dpr,
      {bool flipX = false, bool flipY = false}) async {
    final info = await _load();
    final glyph = size ?? info.size;
    final box = _cursorBox(glyph, shadow: shadow);
    final image = await _bake(
      box: box,
      dpr: dpr,
      angle: angle,
      flipX: flipX,
      flipY: flipY,
      shadow: shadow,
      painter: (canvas, s) {
        canvas.save();
        canvas.translate(
            (s.width - glyph.width) / 2, (s.height - glyph.height) / 2);
        canvas.scale(
            glyph.width / info.size.width, glyph.height / info.size.height);
        canvas.drawPicture(info.picture);
        canvas.restore();
      },
    );
    return (
      image,
      _transformHotspot(
          _hotspotInBox(box, glyph, hotspot), box, angle, flipX, flipY)
    );
  }
}

class _ImageSource extends _Source {
  _ImageSource({
    required super.id,
    required this.image,
    this.size,
    super.hotspot,
    super.shadow,
  });
  final ui.Image image;
  final ui.Size? size;

  ui.Size get _glyph =>
      size ?? ui.Size(image.width.toDouble(), image.height.toDouble());

  @override
  Future<(ui.Image, ui.Offset)> render(double angle, double dpr,
      {bool flipX = false, bool flipY = false}) async {
    final glyph = _glyph;
    final box = _cursorBox(glyph, shadow: shadow);
    final out = await _bake(
      box: box,
      dpr: dpr,
      angle: angle,
      flipX: flipX,
      flipY: flipY,
      shadow: shadow,
      painter: (canvas, s) => canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        ui.Rect.fromCenter(
            center: ui.Offset(s.width / 2, s.height / 2),
            width: glyph.width,
            height: glyph.height),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      ),
    );
    return (
      out,
      _transformHotspot(
          _hotspotInBox(box, glyph, hotspot), box, angle, flipX, flipY)
    );
  }
}

class _DrawSource extends _Source {
  _DrawSource({
    required super.id,
    required this.size,
    required this.painter,
    super.hotspot,
    super.shadow,
  });
  final ui.Size size;
  final CursorPainter painter;

  @override
  Future<(ui.Image, ui.Offset)> render(double angle, double dpr,
      {bool flipX = false, bool flipY = false}) async {
    // Bake into a diagonal-padded box (like svg/image) and centre the painter's
    // own [size] box in it, so a rotated glyph never clips at the edges.
    final box = _cursorBox(size, shadow: shadow);
    final image = await _bake(
      box: box,
      dpr: dpr,
      angle: angle,
      flipX: flipX,
      flipY: flipY,
      shadow: shadow,
      painter: (canvas, s) {
        canvas.save();
        canvas.translate(
            (s.width - size.width) / 2, (s.height - size.height) / 2);
        painter(canvas, size);
        canvas.restore();
      },
    );
    return (
      image,
      _transformHotspot(
          _hotspotInBox(box, size, hotspot), box, angle, flipX, flipY)
    );
  }
}

class _BuilderSource extends _Source {
  _BuilderSource({
    required super.id,
    required this.build,
    super.hotspot,
  });
  final Future<ui.Image> Function(double angle, double devicePixelRatio) build;

  // A builder owns its whole bitmap, so flip doesn't apply — it bakes its own.
  // Its [hotspot] is in the produced bitmap's logical px; null = its centre.
  @override
  Future<(ui.Image, ui.Offset)> render(double angle, double dpr,
      {bool flipX = false, bool flipY = false}) async {
    final image = await build(angle, dpr);
    return (
      image,
      hotspot ?? ui.Offset(image.width / (2 * dpr), image.height / (2 * dpr))
    );
  }
}

/// Map a [glyph]-relative [hotspot] into [box]-logical px (the glyph is centred
/// in the box), or the box centre when [hotspot] is null.
ui.Offset _hotspotInBox(ui.Size box, ui.Size glyph, ui.Offset? hotspot) =>
    hotspot == null
        ? ui.Offset(box.width / 2, box.height / 2)
        : ui.Offset((box.width - glyph.width) / 2 + hotspot.dx,
            (box.height - glyph.height) / 2 + hotspot.dy);

/// Apply the same mirror + rotation [`_bake`] gives the glyph (around the box
/// centre) to a [box]-space hotspot [h], so the click point tracks the visible
/// tip when the cursor is flipped or rotated. (Centre hotspots are unaffected.)
ui.Offset _transformHotspot(
    ui.Offset h, ui.Size box, double angle, bool flipX, bool flipY) {
  var dx = h.dx - box.width / 2;
  var dy = h.dy - box.height / 2;
  if (flipX) dx = -dx; // mirror first (matches _bake's scale-then-rotate)…
  if (flipY) dy = -dy;
  final c = math.cos(angle), s = math.sin(angle); // …then rotate.
  return ui.Offset(
    box.width / 2 + dx * c - dy * s,
    box.height / 2 + dx * s + dy * c,
  );
}

/// A square box that fits [content] at ANY rotation (its diagonal) plus the
/// [shadow]'s offset + blur, so the glyph never clips as it turns.
///
/// The side is rounded UP to a whole logical px so the device bitmap
/// (`side * dpr`) and the logical size (`side`) stay integers at integer DPRs —
/// otherwise a fractional-logical cursor gets resampled (blurry) by some hosts
/// (notably Linux/GDK's scaled cursor surface).
ui.Size _cursorBox(ui.Size content, {NativeCursorShadow? shadow}) {
  final core = math.sqrt(
      content.width * content.width + content.height * content.height);
  final pad =
      shadow == null ? 0.0 : shadow.offset.distance + 3 * shadow.blurSigma;
  final side = (core + 2 * pad).ceilToDouble();
  return ui.Size(side, side);
}

/// Rasterise [painter] into a [box]·[dpr] bitmap, rotated about the centre by
/// [angle] (a no-op at 0) with an optional baked [shadow].
Future<ui.Image> _bake({
  required ui.Size box,
  required double dpr,
  required double angle,
  required CursorPainter painter,
  bool flipX = false,
  bool flipY = false,
  NativeCursorShadow? shadow,
}) async {
  final wpx = (box.width * dpr).round();
  final hpx = (box.height * dpr).round();

  // 1. Rasterise the rotated/mirrored glyph at SS× the device resolution.
  //    Supersampling stabilises a thin glyph's anti-aliasing across angles — at
  //    1× the edges land on the pixel grid differently every few degrees, so the
  //    shadow cast from them "breathes" thick/thin as the cursor rotates.
  const ss = 3;
  final sdpr = dpr * ss;
  final gw = (box.width * sdpr).round();
  final gh = (box.height * sdpr).round();
  final r1 = ui.PictureRecorder();
  final c1 = ui.Canvas(r1)
    ..translate(gw / 2, gh / 2)
    ..rotate(angle)
    ..scale(flipX ? -sdpr : sdpr, flipY ? -sdpr : sdpr)
    ..translate(-box.width / 2, -box.height / 2);
  painter(c1, box);
  // toImageSync keeps the supersampled intermediate GPU-resident (no read-back
  // stall); only the final PNG encode reads pixels back.
  final glyphHi = r1.endRecording().toImageSync(gw, gh);

  // 2. Compose at the target resolution. The glyph is downscaled with mipmap
  //    filtering (filterQuality.high area-averages the SS pixels → stable AA).
  //    The shadow is a recoloured, blurred copy of it, offset in SCREEN space
  //    (overhead light, so it stays straight down at every angle). The blur runs
  //    at the SMALL target sigma — never the large SS sigma that makes Impeller's
  //    blur wash a thin shape out.
  final src = ui.Rect.fromLTWH(0, 0, gw.toDouble(), gh.toDouble());
  final dst = ui.Rect.fromLTWH(0, 0, wpx.toDouble(), hpx.toDouble());
  final r2 = ui.PictureRecorder();
  final c2 = ui.Canvas(r2);
  if (shadow != null) {
    c2.drawImageRect(
      glyphHi,
      src,
      dst.shift(ui.Offset(shadow.offset.dx * dpr, shadow.offset.dy * dpr)),
      ui.Paint()
        ..filterQuality = ui.FilterQuality.high
        ..colorFilter = ui.ColorFilter.mode(shadow.color, ui.BlendMode.srcIn)
        ..imageFilter = ui.ImageFilter.blur(
            sigmaX: shadow.blurSigma * dpr, sigmaY: shadow.blurSigma * dpr),
    );
  }
  c2.drawImageRect(
      glyphHi, src, dst, ui.Paint()..filterQuality = ui.FilterQuality.high);
  glyphHi.dispose();
  final picture = r2.endRecording();
  final image = await picture.toImage(wpx, hpx);
  picture.dispose();
  return image;
}

/// A baked cursor bitmap retained for [NativeMouseCursorOverlay] painting: the
/// device-pixel [image] and its [hotspot] in the bitmap's own LOGICAL px.
class _Baked {
  const _Baked(this.image, this.hotspot);
  final ui.Image image;
  final ui.Offset hotspot;
}

/// Internal: the async, angle-bucketed cache behind [NativeMouseCursor]'s
/// static API. [get] returns the cursor if ready, otherwise kicks off the async
/// build and returns the nearest already-built angle meanwhile, calling
/// [onCursorReady] when the exact one lands so the widget rebuilds.
class _CursorCache {
  _CursorCache({
    required double devicePixelRatio,
    this.angleBucketDegrees = 4,
  }) : _dpr = devicePixelRatio;

  double _dpr;

  /// DPR the bitmaps are built at. Changing it drops the baked bitmaps (they're
  /// DPR-specific) but KEEPS registrations, so they re-bake crisp on next use.
  double get devicePixelRatio => _dpr;
  set devicePixelRatio(double value) {
    if (value == _dpr) return;
    _dpr = value;
    for (final c in _cache.values) {
      _deleteNative(c.key);
    }
    _cache.clear();
    _loading.clear();
    _baked.clear();
    _spun.clear();
    for (final b in _bitmaps.values) {
      b.image.dispose();
    }
    _bitmaps.clear();
    _bitmapLoading.clear();
    for (final source in _registered.values) {
      _warm(source); // re-bake the registered set crisp at the new DPR
    }
  }

  /// Called when a newly-built cursor lands (typically a `setState`).
  VoidCallback? onCursorReady;

  /// A distinct rotation is baked once per this many degrees.
  final int angleBucketDegrees;

  final Map<String, NativeMouseCursor> _cache = {};
  final Set<String> _loading = {};
  final Map<String, List<int>> _baked = {};
  final Map<String, _Source> _registered = {};

  // When the overlay fallback is active, the baked bitmaps are kept (keyed like
  // [_cache]) so the overlay can paint them, instead of being disposed after
  // they're handed to the OS. Off by default (native renderers don't need them).
  final Map<String, _Baked> _bitmaps = {};
  bool retainBitmaps = false;

  // Keys whose overlay bitmap is being (re-)rendered, so we don't kick off the
  // same render twice.
  final Set<String> _bitmapLoading = {};

  /// Start keeping baked bitmaps so the overlay can paint them. The native
  /// cursors are KEPT (so `get` keeps returning real cursors — no fallback gap
  /// while the overlay turns on); their bitmaps, already disposed, are
  /// re-rendered lazily here and on the next `get`.
  void enableRetention() {
    if (retainBitmaps) return;
    retainBitmaps = true;
    for (final key in _cache.keys.toList()) {
      final parsed = _parseKey(key);
      if (parsed != null) {
        _ensureBitmap(parsed.$1, key, parsed.$2, parsed.$3, parsed.$4);
      }
    }
  }

  // Split a cache key `id@bucket@dpr@flip` back into its source + bake params,
  // scanning from the right so an id containing '@' still parses.
  (_Source, int, bool, bool)? _parseKey(String key) {
    final i3 = key.lastIndexOf('@');
    if (i3 < 0) return null;
    final i2 = key.lastIndexOf('@', i3 - 1);
    if (i2 < 0) return null;
    final i1 = key.lastIndexOf('@', i2 - 1);
    if (i1 < 0) return null;
    final source = _registered[key.substring(0, i1)];
    if (source == null) return null;
    final bucket = int.tryParse(key.substring(i1 + 1, i2)) ?? 0;
    final flip = int.tryParse(key.substring(i3 + 1)) ?? 0;
    return (source, bucket, flip & 2 != 0, flip & 1 != 0);
  }

  /// Render JUST the overlay bitmap for an already-cached cursor (whose
  /// `ui.Image` was disposed) and store it under [key], keeping the native
  /// cursor. No-op unless retaining, already have it, or already rendering.
  void _ensureBitmap(
      _Source source, String key, int bucket, bool flipX, bool flipY) {
    if (!retainBitmaps ||
        _bitmaps.containsKey(key) ||
        !_bitmapLoading.add(key)) {
      return;
    }
    () async {
      try {
        final (image, hotspot) = await source.render(bucket * math.pi / 180,
            _dpr,
            flipX: flipX, flipY: flipY);
        if (retainBitmaps && _cache.containsKey(key)) {
          _bitmaps[key] = _Baked(image, hotspot);
          NativeMouseCursor._overlay?.bitmapReady();
        } else {
          image.dispose();
        }
      } finally {
        _bitmapLoading.remove(key);
      }
    }();
  }

  // Ids that have been fetched ROTATED, so their whole angle circle is being
  // pre-baked (see [_warmCircle]). Reset when the DPR changes.
  final Set<String> _spun = {};

  /// Register [source] under its id and warm its at-rest (angle 0, unflipped)
  /// bitmap in the background; other angles + flips bake lazily on first `get`,
  /// returning the nearest already-baked one meanwhile.
  void register(_Source source) {
    _registered[source.id] = source;
    _warm(source);
  }

  bool isRegistered(String id) => _registered.containsKey(id);

  void _warm(_Source source) => _build(source); // angle 0, unflipped

  // The first time a cursor is fetched ROTATED, pre-bake every angle bucket in
  // the background, so a continuous spin hits the cache each frame instead of
  // baking on demand (which makes the cursor + its straight-down shadow trail
  // the live angle). One-time per cursor + flip-orientation.
  void _warmCircle(_Source source, bool flipX, bool flipY) {
    if (!_spun.add(source.id)) return;
    for (var b = angleBucketDegrees; b < 360; b += angleBucketDegrees) {
      _build(source, angle: b * math.pi / 180, flipX: flipX, flipY: flipY);
    }
  }

  /// The native cursor for a REGISTERED [id] at [angle] (radians) and flip, or
  /// null if [id] isn't registered or its bitmap isn't built yet.
  NativeMouseCursor? get(String id,
      {double angle = 0, bool flipX = false, bool flipY = false}) {
    final source = _registered[id];
    return source == null
        ? null
        : _build(source, angle: angle, flipX: flipX, flipY: flipY);
  }

  int _bucket(double angle) {
    final step = angleBucketDegrees;
    var b = ((angle * 180 / math.pi / step).round() * step) % 360;
    return b < 0 ? b + 360 : b;
  }

  // A 0..3 code for the (flipX, flipY) pair, so each mirror is cached apart.
  int _flip(bool flipX, bool flipY) => (flipX ? 2 : 0) | (flipY ? 1 : 0);

  /// Return the cursor for [source] at [angle] + flip if baked, else kick off
  /// the bake and return the nearest already-baked bucket of the SAME flip
  /// meanwhile (null if none yet).
  NativeMouseCursor? _build(_Source source,
      {double angle = 0, bool flipX = false, bool flipY = false}) {
    final bucket = _bucket(angle);
    if (bucket != 0) _warmCircle(source, flipX, flipY);
    final flip = _flip(flipX, flipY);
    final key = '${source.id}@$bucket@$_dpr@$flip';
    final cached = _cache[key];
    if (cached != null) {
      // The native cursor is ready; make sure the overlay has its bitmap too.
      if (retainBitmaps) _ensureBitmap(source, key, bucket, flipX, flipY);
      return cached;
    }
    if (!_loading.contains(key)) {
      _loading.add(key);
      _bakeAndStore(source, key, bucket, flipX, flipY);
    }
    // Fallback to the nearest already-baked bucket of this id + flip.
    final variant = '${source.id}@$flip';
    final baked = _baked[variant];
    if (baked == null || baked.isEmpty) return null;
    int best = baked.first, bestDist = 1 << 30;
    for (final b in baked) {
      var d = (b - bucket).abs();
      if (d > 180) d = 360 - d;
      if (d < bestDist) {
        bestDist = d;
        best = b;
      }
    }
    final bestKey = '${source.id}@$best@$_dpr@$flip';
    if (retainBitmaps) _ensureBitmap(source, bestKey, best, flipX, flipY);
    return _cache[bestKey];
  }

  Future<void> _bakeAndStore(
      _Source source, String key, int bucket, bool flipX, bool flipY) async {
    final (image, hotspot) = await source.render(bucket * math.pi / 180, _dpr,
        flipX: flipX, flipY: flipY);
    final native = await NativeMouseCursor._createNative(
      image,
      hotspot: hotspot,
      devicePixelRatio: _dpr,
      key: key,
    );
    if (retainBitmaps) {
      _bitmaps[key]?.image.dispose();
      _bitmaps[key] = _Baked(image, hotspot);
    } else {
      image.dispose();
    }
    _cache[key] = native;
    (_baked['${source.id}@${_flip(flipX, flipY)}'] ??= []).add(bucket);
    onCursorReady?.call();
  }

  void _deleteNative(String key) =>
      NativeMouseCursorPlatform.instance.deleteCursor(key);

  /// Forget one registered cursor and release its baked bitmaps.
  void disposeId(String id) {
    _registered.remove(id);
    _spun.remove(id);
    final prefix = '$id@';
    _baked.removeWhere((k, _) => k.startsWith(prefix));
    for (final key in _cache.keys.where((k) => k.startsWith(prefix)).toList()) {
      _deleteNative(key);
      _cache.remove(key);
      _loading.remove(key);
    }
    for (final key in _bitmaps.keys.where((k) => k.startsWith(prefix)).toList()) {
      _bitmaps.remove(key)?.image.dispose();
    }
    _bitmapLoading.removeWhere((k) => k.startsWith(prefix));
  }

  /// Release every cursor in the cache.
  void disposeAll() {
    for (final key in _cache.keys.toList()) {
      _deleteNative(key);
    }
    _cache.clear();
    _loading.clear();
    _baked.clear();
    _registered.clear();
    _spun.clear();
    for (final b in _bitmaps.values) {
      b.image.dispose();
    }
    _bitmaps.clear();
    _bitmapLoading.clear();
  }
}

// ─────────────────────── test-only internals ───────────────────────────────
// Pure geometry behind the bake, exposed so it can be unit-tested without the
// GPU. Not part of the public API — do not use these in app code.

@visibleForTesting
ui.Size cursorBoxForTest(ui.Size content, {NativeCursorShadow? shadow}) =>
    _cursorBox(content, shadow: shadow);

@visibleForTesting
ui.Offset hotspotInBoxForTest(
        ui.Size box, ui.Size glyph, ui.Offset? hotspot) =>
    _hotspotInBox(box, glyph, hotspot);

@visibleForTesting
ui.Offset transformHotspotForTest(
        ui.Offset h, ui.Size box, double angle, bool flipX, bool flipY) =>
    _transformHotspot(h, box, angle, flipX, flipY);
