/// A highlight drawn the way a felt marker draws it: one stroke per line,
/// a little wider than the words, with a wavering top and bottom edge,
/// chisel-cut ends, a slight tilt and a darker patch where the pen went
/// back over itself.
///
/// The wobble comes from [MarkerStrokeSpec.seed] and the distance along
/// the stroke, never from its position, size or the clock: a stroke keeps
/// its shape while the page scrolls or repaints, and a stroke that grows
/// (a word typed at its end, a wider window) carries on from where it was.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';

/// Spec for [markerStrokePainter]: the ink [color] and a [seed] that
/// tells two strokes of the same size apart.
@immutable
final class MarkerStrokeSpec {
  /// Creates a marker stroke in [color].
  const MarkerStrokeSpec(this.color, {this.seed = 0});

  /// The ink. Its alpha is the stroke's: where the pen doubles back the
  /// patch paints over it again, a shade deeper.
  final Color color;

  /// Mixed into the wobble. Hosts pass something stable about the marked
  /// words, such as their length.
  final int seed;

  @override
  bool operator ==(Object other) =>
      other is MarkerStrokeSpec && other.color == color && other.seed == seed;

  @override
  int get hashCode => Object.hash(color, seed);

  @override
  String toString() => 'MarkerStrokeSpec($color, seed: $seed)';
}

/// The two shapes one stroke paints over [rect]: the [body], and the
/// shorter [overlap] where the pen went back over it (null on a stroke too
/// short to double back on).
typedef MarkerStrokeShape = ({Path body, Path? overlap});

/// The marker shape over one line's [rect], the glyphs' ink box.
///
/// The same [seed] always gives the same stroke: moving [rect] moves it,
/// and widening [rect] carries the stroke on further without reshaping
/// what was already drawn.
MarkerStrokeShape markerStrokeShape(Rect rect, {int seed = 0}) {
  final random = math.Random(_mix(seed));
  double spread(double amount) => (random.nextDouble() * 2 - 1) * amount;

  final h = rect.height;
  // From just under the line's top to just under the baseline: a marker
  // covers the letters' bodies, not the whole line box.
  final top = rect.top + h * (0.2 + spread(0.025));
  final bottom = rect.bottom - h * (0.1 + spread(0.025));
  final band = bottom - top;
  // Ends run past the words, a little further on the side the pen leaves.
  final left = rect.left - 1.5 - random.nextDouble() * 2.5;
  final right = rect.right + 1.5 + random.nextDouble() * 2.5;
  final width = right - left;
  // About a degree of tilt from where the pen lands, drifting no more than
  // a sixth of the band, so a long line levels out instead of climbing.
  final slope = math.tan(spread(1.1) * math.pi / 180);
  // Starts a twelfth of the band off centre, so its drift stays centred.
  final lift = slope.sign * band / 12;
  double tilt(double x) =>
      (slope * (x - left)).clamp(-band / 6, band / 6).toDouble() - lift;
  // The chisel tip, held at an angle: the top edge sits a little to the
  // right of the bottom one, so both ends are cut on a slant.
  final slant = math.min(math.min(band * 0.32, 6.0), width * 0.2);
  // Where the pen doubles back: over the start or the end, for 40 to 60
  // pixels (at most a third of a short stroke), a little narrower.
  final reachPx = 40 + random.nextDouble() * 20;
  final atStart = random.nextBool();
  final inset = 0.12 + random.nextDouble() * 0.1;
  final insetTop = inset * (random.nextBool() ? 1 : 0.4);
  final insetBottom = inset * (random.nextBool() ? 1 : 0.4);
  final bodyNoise = (top: _Noise(random), bottom: _Noise(random));
  final overlapNoise = (top: _Noise(random), bottom: _Noise(random));

  final body = _band(
    left: left,
    right: right,
    top: top,
    bottom: bottom,
    slant: slant,
    tilt: tilt,
    wobble: band * 0.06,
    noise: bodyNoise,
  );

  Path? overlap;
  if (width > 36) {
    final reach = math.min(reachPx, width / 3);
    overlap = _band(
      left: atStart ? left + 0.5 : right - reach,
      right: atStart ? left + reach : right - 0.5,
      top: top + band * insetTop,
      bottom: bottom - band * insetBottom,
      slant: slant * 0.8,
      tilt: tilt,
      wobble: band * 0.05,
      noise: overlapNoise,
    );
  }
  return (body: body, overlap: overlap);
}

/// A [LayerPainter] that draws a marker stroke over [rect] in
/// [MarkerStrokeSpec.color]. [spec] must be a [MarkerStrokeSpec].
void markerStrokePainter(Canvas canvas, Rect rect, Object? spec) {
  final marker = spec! as MarkerStrokeSpec;
  if (rect.width <= 0 || rect.height <= 0) return;
  final shape = markerStrokeShape(rect, seed: marker.seed);
  final paint = Paint()
    ..color = marker.color
    ..isAntiAlias = true;
  canvas.drawPath(shape.body, paint);
  final overlap = shape.overlap;
  if (overlap != null) {
    canvas.drawPath(
      overlap,
      paint..color = marker.color.withValues(alpha: marker.color.a * 0.45),
    );
  }
}

/// A band from [left] to [right] with wavering edges and rounded,
/// slanted ends.
Path _band({
  required double left,
  required double right,
  required double top,
  required double bottom,
  required double slant,
  required double Function(double x) tilt,
  required double wobble,
  required ({_Noise top, _Noise bottom}) noise,
}) {
  // Points at fixed distances from where each edge starts, then its end:
  // a longer stroke adds points rather than moving the ones it had.
  // Both ends are always there, so even a one-letter stroke is a band.
  Offset at(double x, double y, _Noise noise) =>
      Offset(x, y + tilt(x) + noise.at(x - left) * wobble);
  List<Offset> edge(double from, double to, double y, _Noise noise) => [
        at(from, y, noise),
        for (var x = from + _pointGap; x < to - _pointGap / 2; x += _pointGap)
          at(x, y, noise),
        at(math.max(to, from + 0.5), y, noise),
      ];
  final topEdge = edge(left + slant, right, top, noise.top);
  final bottomEdge = edge(left, right - slant, bottom, noise.bottom);
  // Ink pools where the pen lands and lifts: the ends bulge a touch.
  final bulge = math.min((bottom - top) * 0.22, 4.0);
  final path = Path()..moveTo(topEdge.first.dx, topEdge.first.dy);
  _smoothThrough(path, topEdge);
  final topRight = topEdge.last;
  final bottomRight = bottomEdge.last;
  path.quadraticBezierTo(
    math.max(topRight.dx, bottomRight.dx) + bulge,
    (topRight.dy + bottomRight.dy) / 2,
    bottomRight.dx,
    bottomRight.dy,
  );
  _smoothThrough(path, bottomEdge.reversed.toList());
  final bottomLeft = bottomEdge.first;
  final topLeft = topEdge.first;
  path
    ..quadraticBezierTo(
      math.min(topLeft.dx, bottomLeft.dx) - bulge,
      (topLeft.dy + bottomLeft.dy) / 2,
      topLeft.dx,
      topLeft.dy,
    )
    ..close();
  return path;
}

/// How far apart the points along a stroke's edge are.
const _pointGap = 17.0;

/// Continues [path] (already at `points.first`) through [points] on a
/// smooth curve: each point is a control, the midpoints between are on
/// the line.
void _smoothThrough(Path path, List<Offset> points) {
  for (var i = 1; i < points.length - 1; i++) {
    final mid = Offset.lerp(points[i], points[i + 1], 0.5)!;
    path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(points.last.dx, points.last.dy);
}

/// A smooth wobble along a stroke, between -1 and 1: random heights every
/// [_step] pixels, eased from one to the next, so a point's height depends
/// only on how far along the stroke it is.
final class _Noise {
  _Noise(math.Random random)
      : _knots = List.generate(_count, (_) => random.nextDouble() * 2 - 1);

  static const _step = 34.0;
  static const _count = 64;

  final List<double> _knots;

  double at(double distance) {
    final x = math.max(0.0, distance) / _step;
    final i = x.floor();
    final t = x - i;
    final eased = t * t * (3 - 2 * t);
    final a = _knots[i % _count];
    final b = _knots[(i + 1) % _count];
    return a + (b - a) * eased;
  }
}

/// [seed] scrambled, so nearby seeds draw unrelated strokes.
int _mix(int seed) {
  var h = 0x1fffffff & (seed + 0x9e3779b9);
  h = 0x1fffffff & (h + ((0x0007ffff & h) << 10));
  h ^= h >> 6;
  h = 0x1fffffff & (h + ((0x03ffffff & h) << 3));
  h ^= h >> 11;
  return 0x1fffffff & (h + ((0x00003fff & h) << 15));
}
