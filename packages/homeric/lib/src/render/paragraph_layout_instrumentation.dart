/// Opt-in paragraph-layout instrumentation for local performance benchmarks.
///
/// Production rendering pays one nullable static-field check at each actual
/// `ui.Paragraph.layout` call. Stopwatch allocation, callbacks, and sample
/// bookkeeping exist only while a probe is active.
library;

import 'dart:collection';
import 'dart:ui' as ui;

import 'package:meta/meta.dart';

/// The render path responsible for an actual engine paragraph layout.
enum HomericParagraphLayoutCategory {
  /// Layout of the paragraph that is mounted and painted.
  live,

  /// Intrinsic-size or dry-layout calculation.
  intrinsic,

  /// The one-space fallback used for empty paragraph metrics.
  template,

  /// Deferred paragraph rebuild for a paint-only style change.
  paintRebuild,
}

/// Immutable aggregate from one [HomericParagraphLayoutProbe].
final class HomericParagraphLayoutReport {
  HomericParagraphLayoutReport._(
    Map<HomericParagraphLayoutCategory, int> counts,
    Map<HomericParagraphLayoutCategory, Duration> elapsed,
  )   : counts = UnmodifiableMapView(counts),
        elapsed = UnmodifiableMapView(elapsed);

  /// Actual engine layout calls by path.
  final Map<HomericParagraphLayoutCategory, int> counts;

  /// Cumulative measured engine layout time by path.
  final Map<HomericParagraphLayoutCategory, Duration> elapsed;

  /// Total actual engine layout calls across every path.
  int get totalCount => counts.values.fold(0, (sum, value) => sum + value);

  /// Total cumulative measured engine layout time across every path.
  Duration get totalElapsed => elapsed.values.fold(
        Duration.zero,
        (sum, value) => sum + value,
      );

  /// Count for [category], or zero when that path did not run.
  int countFor(HomericParagraphLayoutCategory category) =>
      counts[category] ?? 0;
}

/// A process-local, explicitly enabled paragraph-layout measurement probe.
///
/// Only one probe may be active. Benchmarks should start immediately before
/// the measured interaction and stop immediately afterward. This is not an
/// application telemetry API.
final class HomericParagraphLayoutProbe {
  HomericParagraphLayoutProbe._();

  static HomericParagraphLayoutProbe? _active;

  final Map<HomericParagraphLayoutCategory, int> _counts = {};
  final Map<HomericParagraphLayoutCategory, Duration> _elapsed = {};
  HomericParagraphLayoutReport? _report;

  /// Whether a benchmark probe is currently collecting measurements.
  static bool get isActive => _active != null;

  /// Starts the sole process-local probe.
  static HomericParagraphLayoutProbe start() {
    if (_active != null) {
      throw StateError('A Homeric paragraph-layout probe is already active.');
    }
    return _active = HomericParagraphLayoutProbe._();
  }

  /// Stops this probe and returns an immutable aggregate.
  ///
  /// Repeated calls return the same report, which makes test and benchmark
  /// cleanup safe.
  HomericParagraphLayoutReport stop() {
    final existing = _report;
    if (existing != null) return existing;
    if (!identical(_active, this)) {
      throw StateError('This Homeric paragraph-layout probe is not active.');
    }
    _active = null;
    return _report = HomericParagraphLayoutReport._(
      Map.of(_counts),
      Map.of(_elapsed),
    );
  }

  /// Executes one actual engine layout and records it only when enabled.
  ///
  /// The paragraph and constraints are passed directly so disabled mode does
  /// not allocate a callback closure at the call site.
  @internal
  static void layout(
    HomericParagraphLayoutCategory category,
    ui.Paragraph paragraph,
    ui.ParagraphConstraints constraints,
  ) {
    final active = _active;
    if (active == null) {
      paragraph.layout(constraints);
      return;
    }
    final stopwatch = Stopwatch()..start();
    try {
      paragraph.layout(constraints);
    } finally {
      stopwatch.stop();
      active._counts.update(category, (count) => count + 1, ifAbsent: () => 1);
      active._elapsed.update(
        category,
        (elapsed) => elapsed + stopwatch.elapsed,
        ifAbsent: () => stopwatch.elapsed,
      );
    }
  }
}
