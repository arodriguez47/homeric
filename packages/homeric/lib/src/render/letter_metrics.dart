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

  static final Map<_Face, double> _registered = <_Face, double>{};
  static final Map<_Face, double> _measured = <_Face, double>{};
  static final Map<_Face, Future<void>> _pending = <_Face, Future<void>>{};
  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);
  static bool _watchingFonts = false;

  /// Fires when a face's x-height becomes known, or when fonts load and
  /// the measured ones are taken again.
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
    _registered[_Face(family, weight, style)] = ratio;
  }

  static double? _known(_Face face) {
    for (final key in [
      _Face(face.family, face.weight, face.style),
      _Face(face.family, face.weight, null),
      _Face(face.family, null, face.style),
      _Face(face.family, null, null),
    ]) {
      final ratio = _registered[key];
      if (ratio != null) return ratio;
    }
    return _measured[face];
  }

  /// [style]'s x-height as a fraction of its font size: registered,
  /// measured, or [fallback] while a measurement is under way.
  static double ratioOf(TextStyle style) {
    final face = _Face.of(style);
    final known = _known(face);
    if (known != null) return known;
    unawaited(_measure(face, style));
    return fallback;
  }

  /// How far above the baseline the middle of [style]'s lower-case
  /// letters sits, at [textScaler]'s size: half an x-height.
  static double midlineAboveBaseline(
    TextStyle style, {
    TextScaler textScaler = TextScaler.noScaling,
  }) =>
      textScaler.scale(style.fontSize ?? 14) * ratioOf(style) / 2;

  /// Measures each of [styles]' faces not yet known, completing once all
  /// are. For a host that wants its first frame exact (after its fonts
  /// have loaded), and for tests.
  static Future<void> ensure(Iterable<TextStyle> styles) => Future.wait([
        for (final style in styles)
          if (_known(_Face.of(style)) == null) _measure(_Face.of(style), style),
      ]);

  /// Forgets every measured and registered face.
  @visibleForTesting
  static void debugReset() {
    _registered.clear();
    _measured.clear();
    _pending.clear();
  }

  /// One measurement per face at a time; a face that draws nothing (or
  /// fails) is remembered at [fallback], so it is not measured again on
  /// every build.
  static Future<void> _measure(_Face face, TextStyle style) {
    _watchFonts();
    final running = _pending[face];
    if (running != null) return running;
    late final Future<void> measurement;
    measurement = () async {
      double? ratio;
      try {
        ratio = await _inkRatio(style);
      } catch (_) {
        ratio = null;
      }
      // Fonts changed while this one ran (its entry was dropped, or a new
      // measurement took its place): it read the old letters, so it is
      // thrown away.
      if (!identical(_pending[face], measurement)) return;
      _measured[face] = ratio ?? fallback;
      _pending.remove(face);
      if (ratio != null && ratio != fallback) _changes.value++;
    }();
    return _pending[face] = measurement;
  }

  /// A font that loads after a face was measured (a downloaded one, say)
  /// changes its letters: measured faces are forgotten and measured again
  /// as they are next asked for.
  static void _watchFonts() {
    if (_watchingFonts) return;
    final PaintingBinding binding;
    try {
      binding = PaintingBinding.instance;
    } catch (_) {
      return;
    }
    _watchingFonts = true;
    binding.systemFonts.addListener(() {
      if (_measured.isEmpty && _pending.isEmpty) return;
      _measured.clear();
      // A measurement under way read the old letters: dropped on landing.
      _pending.clear();
      _changes.value++;
    });
  }

  /// The top of an `x`'s ink above its baseline, over the size it is drawn
  /// at; null when nothing was drawn (no such glyph).
  static Future<double?> _inkRatio(TextStyle style) async {
    final painter = TextPainter(
      text: TextSpan(
        text: 'x',
        // Only what shapes the glyph: a host's paint (a foreground
        // shader, a background, shadows, decorations) would add ink that
        // isn't the letter's, so nothing else is carried over.
        style: TextStyle(
          fontFamily: style.fontFamily,
          fontFamilyFallback: style.fontFamilyFallback,
          fontWeight: style.fontWeight,
          fontStyle: style.fontStyle,
          fontVariations: style.fontVariations,
          fontFeatures: style.fontFeatures,
          fontSize: _probeSize,
          height: 1,
          color: const Color(0xFF000000),
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

/// A face as Homeric remembers it. Registered x-heights are keyed by
/// family, weight and style alone; measured ones also by [shaping] (the
/// fallback chain, variations and features), since those can pick a
/// different `x`.
@immutable
final class _Face {
  const _Face(this.family, this.weight, this.style, [this.shaping = const []]);

  factory _Face.of(TextStyle style) => _Face(
        style.fontFamily,
        style.fontWeight,
        style.fontStyle,
        [
          ...?style.fontFamilyFallback,
          '|',
          ...?style.fontVariations,
          '|',
          ...?style.fontFeatures,
        ],
      );

  final String? family;
  final FontWeight? weight;
  final FontStyle? style;
  final List<Object> shaping;

  @override
  bool operator ==(Object other) =>
      other is _Face &&
      other.family == family &&
      other.weight == weight &&
      other.style == style &&
      listEquals(other.shaping, shaping);

  @override
  int get hashCode =>
      Object.hash(family, weight, style, Object.hashAll(shaping));
}
