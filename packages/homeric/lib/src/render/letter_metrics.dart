/// Where a line's lower-case letters sit: the measure a marker, a box or a
/// grip beside a line centres on.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The x-height of a face: how tall its lower-case letters stand above the
/// baseline, as a fraction of the font size.
///
/// A bullet, a to-do box or a paragraph grip reads as level with its line
/// when its middle meets the middle of the line's lower-case letters, half
/// an x-height above the baseline. Flutter reports a face's ascent and
/// descent but not its x-height, so Homeric measures it once per face from
/// the ink of an `x`, and remembers it. Until a face is measured,
/// [ratioOf] answers [fallback] and starts the measurement; [changes]
/// fires when it lands, so a mark drawn with the guess can move once.
///
/// A host that knows its faces can [register] their x-heights up front
/// (from the font's OS/2 `sxHeight`), so nothing ever moves.
abstract final class HomericLetterMetrics {
  /// The guess for a face not yet measured: a typical text face's.
  static const double fallback = 0.48;

  /// Size the `x` is drawn at to measure it.
  static const double _probeSize = 96;

  static final Map<_Face, double> _ratios = <_Face, double>{};
  static final Set<_Face> _measuring = <_Face>{};
  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  /// Fires when a face's x-height becomes known.
  static Listenable get changes => _changes;

  /// Records [family]'s x-height as [ratio] of its size, for every weight
  /// and style unless [weight] or [style] narrows it.
  static void register(
    String family,
    double ratio, {
    FontWeight? weight,
    FontStyle? style,
  }) {
    assert(ratio > 0 && ratio < 1.5);
    _ratios[_Face(family, weight, style)] = ratio;
  }

  /// [style]'s x-height as a fraction of its font size: registered,
  /// measured, or [fallback] while a measurement is under way.
  static double ratioOf(TextStyle style) {
    final face = _Face.of(style);
    final known = _ratios[face] ??
        _ratios[_Face(face.family, face.weight, null)] ??
        _ratios[_Face(face.family, null, face.style)] ??
        _ratios[_Face(face.family, null, null)];
    if (known != null) return known;
    _measure(face, style);
    return fallback;
  }

  /// How far above the baseline the middle of [style]'s lower-case
  /// letters sits, at [textScaler]'s size: half an x-height.
  static double midlineAboveBaseline(
    TextStyle style, {
    TextScaler textScaler = TextScaler.noScaling,
  }) =>
      textScaler.scale(style.fontSize ?? 14) * ratioOf(style) / 2;

  /// Measures each of [styles]' faces, completing once all are known.
  /// For a host that wants its first frame exact, and for tests.
  static Future<void> ensure(Iterable<TextStyle> styles) => Future.wait([
        for (final style in styles)
          if (!_ratios.containsKey(_Face.of(style)))
            _measureNow(_Face.of(style), style),
      ]);

  /// Forgets every measured and registered face.
  @visibleForTesting
  static void debugReset() {
    _ratios.clear();
    _measuring.clear();
  }

  static void _measure(_Face face, TextStyle style) {
    if (!_measuring.add(face)) return;
    unawaited(_measureNow(face, style));
  }

  static Future<void> _measureNow(_Face face, TextStyle style) async {
    _measuring.add(face);
    try {
      final ratio = await _inkRatio(style);
      if (ratio != null) {
        _ratios[face] = ratio;
        _changes.value++;
      }
    } finally {
      _measuring.remove(face);
    }
  }

  /// The top of an `x`'s ink above its baseline, over the size it is drawn
  /// at; null when nothing was drawn (no such glyph).
  static Future<double?> _inkRatio(TextStyle style) async {
    final painter = TextPainter(
      text: TextSpan(
        text: 'x',
        style: style.copyWith(
          fontSize: _probeSize,
          height: 1,
          color: const Color(0xFF000000),
          decoration: TextDecoration.none,
          background: null,
          backgroundColor: null,
          foreground: null,
          shadows: const <Shadow>[],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width.ceil() + 4;
    final height = painter.height.ceil() + 4;
    final baseline =
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic) + 2;
    final recorder = ui.PictureRecorder();
    painter.paint(ui.Canvas(recorder), const Offset(2, 2));
    painter.dispose();
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    final ByteData? bytes;
    try {
      bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
    if (bytes == null) return null;
    final pixels = bytes.buffer.asUint8List();
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        // Half covered or more: anti-aliased fringe above the letter's
        // flat top doesn't count.
        if (pixels[(y * width + x) * 4 + 3] >= 128) {
          final ratio = (baseline - y) / _probeSize;
          return ratio > 0.1 && ratio < 1.5 ? ratio : null;
        }
      }
    }
    return null;
  }
}

@immutable
final class _Face {
  const _Face(this.family, this.weight, this.style);

  factory _Face.of(TextStyle style) =>
      _Face(style.fontFamily, style.fontWeight, style.fontStyle);

  final String? family;
  final FontWeight? weight;
  final FontStyle? style;

  @override
  bool operator ==(Object other) =>
      other is _Face &&
      other.family == family &&
      other.weight == weight &&
      other.style == style;

  @override
  int get hashCode => Object.hash(family, weight, style);
}
