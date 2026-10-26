/// Focus dimming for a writing surface: paragraph, line or sentence.
library;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import '../editing/editable_paragraph.dart' show HomericEditableBlockGeometry;
import '../editing/editor_controller.dart';
import '../model/block.dart';
import '../model/document.dart';
import '../model/selection.dart';
import '../render/paint_layers.dart';
import '../render/paragraph_geometry.dart';
import 'sentences.dart';

/// What stays bright while the rest of the text dims.
enum HomericFocusGranularity {
  /// No dimming.
  off,

  /// The paragraph holding the caret.
  paragraph,

  /// The visual lines the selection touches.
  line,

  /// The sentences the selection touches.
  sentence;

  /// The toolbar and keyboard cycle order: off, paragraph, line,
  /// sentence, off.
  HomericFocusGranularity get next => switch (this) {
        HomericFocusGranularity.off => HomericFocusGranularity.paragraph,
        HomericFocusGranularity.paragraph => HomericFocusGranularity.line,
        HomericFocusGranularity.line => HomericFocusGranularity.sentence,
        HomericFocusGranularity.sentence => HomericFocusGranularity.off,
      };
}

/// Focus dimming: everything but the paragraph, line or sentence being
/// written fades back, as a paint-only wash.
///
/// The editor owns canonical document positions and current visual-line
/// geometry, so this reads them directly. A host listens to the controller
/// in each mounted row, adds [paintLayersFor] to the row's paint layers
/// and, for line focus, calls [observeGeometry] from its overlay builder.
/// Animation ticks update paint layers without changing paragraph shaping
/// inputs.
final class HomericFocusDimController extends ChangeNotifier {
  /// Creates a controller animating on [vsync], starting at
  /// [initialGranularity].
  HomericFocusDimController({
    required TickerProvider vsync,
    HomericFocusGranularity initialGranularity = HomericFocusGranularity.off,
    double strength = homericFocusDimDefaultStrength,
  })  : _granularity = initialGranularity,
        _strength = _validStrength(strength),
        _fromAmount = initialGranularity == HomericFocusGranularity.off ? 0 : 1,
        _toAmount = initialGranularity == HomericFocusGranularity.off ? 0 : 1,
        _paintGranularity = initialGranularity,
        _animation = AnimationController(
          vsync: vsync,
          duration: HomericFocusDimController.duration,
          value: 1,
        ) {
    _animation
      ..addListener(notifyListeners)
      ..addStatusListener(_onAnimationStatus);
  }

  /// How long dimming takes to come and go: short enough to follow the
  /// caret, long enough not to flash. Typewriter scrolling can reuse it so
  /// focus and recentring stay together when one caret move does both.
  static const Duration duration = Duration(milliseconds: 200);

  /// The easing of dimming in and out.
  static const Curve curve = Curves.easeOutQuint;

  final AnimationController _animation;
  final Map<String, _HomericLineWitness> _lineWitnesses =
      <String, _HomericLineWitness>{};
  final Map<String, BlockTextRange?> _lastActiveRanges =
      <String, BlockTextRange?>{};
  Map<String, BlockTextRange?> _outgoingActiveRanges = const {};
  int? _lastDocumentRevision;
  int? _outgoingDocumentRevision;
  final Map<({Color foreground, Color background}), double> _washOpacities =
      <({Color foreground, Color background}), double>{};
  double _strength;
  HomericFocusGranularity _granularity;
  HomericFocusGranularity _paintGranularity;
  double _fromAmount;
  double _toAmount;
  int _lineNotifyGeneration = 0;
  bool _disposed = false;

  /// The focus chosen; dimming may still be fading out after [off].
  HomericFocusGranularity get granularity => _granularity;

  /// How far dimming has come in, 0 to 1.
  double get amount =>
      _fromAmount +
      (_toAmount - _fromAmount) *
          HomericFocusDimController.curve.transform(_animation.value);

  /// Whether dimming is coming in or going out.
  bool get isAnimating => _animation.isAnimating;

  /// How far the rest of the text fades, from 0 (not at all) to 1 (as
  /// faint as still reads); [homericFocusDimDefaultStrength] by default.
  /// See [homericFocusWashOpacity].
  double get strength => _strength;

  /// Changes [strength] at once, without fading: the writer is choosing it
  /// and should see each step as it lands.
  set strength(double value) {
    final next = _validStrength(value);
    if (_disposed || next == _strength) return;
    _strength = next;
    _washOpacities.clear();
    notifyListeners();
  }

  /// Moves to the [HomericFocusGranularity.next] focus.
  void cycle() => setGranularity(_granularity.next);

  /// Chooses [granularity], fading the dimming in or out.
  void setGranularity(HomericFocusGranularity granularity) {
    if (_disposed || _granularity == granularity) return;
    _granularity = granularity;
    if (granularity != HomericFocusGranularity.off) {
      _paintGranularity = granularity;
      _outgoingActiveRanges = const {};
      _outgoingDocumentRevision = null;
      if (granularity != HomericFocusGranularity.line) _lineWitnesses.clear();
    } else {
      _outgoingActiveRanges = Map<String, BlockTextRange?>.unmodifiable(
        _lastActiveRanges,
      );
      _outgoingDocumentRevision = _lastDocumentRevision;
    }
    final target = granularity == HomericFocusGranularity.off ? 0.0 : 1.0;
    final current = amount;
    if (current == target) {
      notifyListeners();
      return;
    }
    _animation.stop();
    _fromAmount = current;
    _toAmount = target;
    _animation.value = 0;
    _animation.forward();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (_disposed || status != AnimationStatus.completed || _toAmount != 0) {
      return;
    }
    _paintGranularity = HomericFocusGranularity.off;
    _outgoingActiveRanges = const {};
    _outgoingDocumentRevision = null;
    _lineWitnesses.clear();
    notifyListeners();
  }

  /// Records the current visual-line union for this selected block.
  ///
  /// Geometry arrives while the paragraph overlay is building, so the cache
  /// updates immediately but its repaint notification is coalesced to the
  /// next frame. A stale geometry generation returns no range and cannot
  /// replace a current witness.
  void observeGeometry({
    required HomericEditableBlockGeometry geometry,
    required Block block,
    required Document document,
    required HomericSelection? selection,
  }) {
    if (_disposed || _granularity != HomericFocusGranularity.line) return;
    final local = _localSelectionForBlock(document, selection, block.id);
    if (local == null) return;
    final lastOffset = local.end == local.start
        ? local.end
        : (local.end - 1).clamp(local.start, block.contentLength);
    final affinity = selection?.isCollapsed == true
        ? selection!.affinity
        : HomericCaretAffinity.downstream;
    final first = geometry.lineBoundaryAt(local.start, affinity: affinity);
    final last = geometry.lineBoundaryAt(lastOffset, affinity: affinity);
    if (first == null || last == null) return;
    final next = _HomericLineWitness(
      documentRevision: geometry.documentRevision,
      range: BlockTextRange(first.start, last.end),
    );
    if (_lineWitnesses[block.id] == next) return;
    _lineWitnesses[block.id] = next;
    final generation = ++_lineNotifyGeneration;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_disposed || generation != _lineNotifyGeneration) return;
      notifyListeners();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  /// The washes that dim [block] around its focused range, drawn in
  /// [backgroundColor] over text in [foregroundColor].
  List<PaintLayer> paintLayersFor({
    required Block block,
    required HomericEditorController editor,
    required Color foregroundColor,
    required Color backgroundColor,
  }) {
    if (_disposed ||
        _paintGranularity == HomericFocusGranularity.off ||
        amount <= 0 ||
        (_granularity != HomericFocusGranularity.off &&
            editor.selection == null)) {
      return const <PaintLayer>[];
    }
    final fadingOut = _granularity == HomericFocusGranularity.off;
    if (fadingOut && _outgoingDocumentRevision != editor.documentRevision) {
      return const <PaintLayer>[];
    }
    if (!fadingOut && _lastDocumentRevision != editor.documentRevision) {
      _lastDocumentRevision = editor.documentRevision;
      _lastActiveRanges.removeWhere(
        (blockId, _) => editor.document.indexOfBlockId(blockId) == null,
      );
      _lineWitnesses.removeWhere(
        (blockId, _) => editor.document.indexOfBlockId(blockId) == null,
      );
    }
    if (fadingOut && !_outgoingActiveRanges.containsKey(block.id)) {
      return const <PaintLayer>[];
    }
    final active = fadingOut
        ? _outgoingActiveRanges[block.id]
        : _activeRangeFor(block, editor);
    if (!fadingOut) _lastActiveRanges[block.id] = active;
    final ranges = active == null
        ? <BlockTextRange>[
            BlockTextRange(0, block.contentLength),
          ]
        : <BlockTextRange>[
            if (active.start > 0) BlockTextRange(0, active.start),
            if (active.end < block.contentLength)
              BlockTextRange(active.end, block.contentLength),
          ];
    final maximumOpacity = _maximumWashOpacity(
      foregroundColor,
      backgroundColor,
    );
    final color = backgroundColor.withValues(
      alpha: amount * maximumOpacity,
    );
    return <PaintLayer>[
      for (final range in ranges)
        if (range.start < range.end)
          PaintLayer(
            range: DocRange(
              DocOffset(range.start),
              DocOffset(range.end),
            ),
            band: PaintBand.overlay,
            painter: solidWashPainter,
            spec: SolidWashSpec(color),
          ),
    ];
  }

  double _maximumWashOpacity(Color foreground, Color background) {
    final key = (foreground: foreground, background: background);
    final cached = _washOpacities[key];
    if (cached != null) return cached;
    final resolved = homericFocusWashOpacity(
      foreground: foreground,
      background: background,
      strength: _strength,
    );
    if (_washOpacities.length == 8) {
      _washOpacities.remove(_washOpacities.keys.first);
    }
    _washOpacities[key] = resolved;
    return resolved;
  }

  BlockTextRange? _activeRangeFor(
    Block block,
    HomericEditorController editor,
  ) {
    final local =
        _localSelectionForBlock(editor.document, editor.selection, block.id);
    if (local == null) return null;
    switch (_paintGranularity) {
      case HomericFocusGranularity.off:
        return null;
      case HomericFocusGranularity.paragraph:
        return BlockTextRange(0, block.contentLength);
      case HomericFocusGranularity.line:
        final witness = _lineWitnesses[block.id];
        if (witness == null ||
            witness.documentRevision != editor.documentRevision) {
          return BlockTextRange(0, block.contentLength);
        }
        return witness.range;
      case HomericFocusGranularity.sentence:
        final touched = _sentenceRangesTouchedBy(
          block.text,
          local.start,
          local.end,
        );
        return touched ?? BlockTextRange(0, block.contentLength);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lineNotifyGeneration++;
    _animation.removeListener(notifyListeners);
    _animation.removeStatusListener(_onAnimationStatus);
    _animation.dispose();
    super.dispose();
  }
}

/// The [HomericFocusDimController.strength] dimming starts at: the rest of
/// the text fades as far as it can while still reading at WCAG AA contrast.
const double homericFocusDimDefaultStrength = 0.5;

/// The background wash that dims text by [strength], 0 to 1.
///
/// A range overlay is the only current Homeric paint-only primitive that can
/// follow arbitrary canonical line/sentence boundaries without reshaping the
/// paragraph. The wash is therefore solved against the *actual* foreground
/// and surface colors rather than hard-coded: low-contrast palettes dim
/// less, and warm Zen uses its own fixed text/background pair.
///
/// Up to [homericFocusDimDefaultStrength] the wash grows toward 0.38 and
/// never takes dimmed text below 4.5:1 (WCAG AA). Past it the writer has
/// asked for more than AA allows, so the wash grows on to 0.85 and the floor
/// eases down to 1.6:1, faint but still there to read. [desiredOpacity] and
/// [minimumContrast], when given, override what [strength] picks.
double homericFocusWashOpacity({
  required Color foreground,
  required Color background,
  double strength = homericFocusDimDefaultStrength,
  double? desiredOpacity,
  double? minimumContrast,
}) {
  final s = _validStrength(strength);
  const base = homericFocusDimDefaultStrength;
  final beyond = s <= base ? 0.0 : (s - base) / (1 - base);
  desiredOpacity ??=
      s <= base ? 0.38 * s / base : 0.38 + (0.85 - 0.38) * beyond;
  minimumContrast ??= 4.5 - (4.5 - 1.6) * beyond;
  if (desiredOpacity <= 0) return 0;
  double contrastAt(double opacity) {
    final composited = Color.alphaBlend(
      background.withValues(alpha: opacity),
      foreground,
    );
    final foregroundLuminance = composited.computeLuminance();
    final backgroundLuminance = background.computeLuminance();
    final lighter = foregroundLuminance > backgroundLuminance
        ? foregroundLuminance
        : backgroundLuminance;
    final darker = foregroundLuminance > backgroundLuminance
        ? backgroundLuminance
        : foregroundLuminance;
    return (lighter + 0.05) / (darker + 0.05);
  }

  if (contrastAt(desiredOpacity) >= minimumContrast) return desiredOpacity;
  var lower = 0.0;
  var upper = desiredOpacity;
  for (var index = 0; index < 18; index++) {
    final midpoint = (lower + upper) / 2;
    if (contrastAt(midpoint) >= minimumContrast) {
      lower = midpoint;
    } else {
      upper = midpoint;
    }
  }
  return lower;
}

/// [strength] within 0 to 1; a NaN reads as the default.
double _validStrength(double strength) =>
    strength.isNaN ? homericFocusDimDefaultStrength : strength.clamp(0.0, 1.0);

({int start, int end})? _localSelectionForBlock(
  Document document,
  HomericSelection? selection,
  String blockId,
) {
  if (selection == null) return null;
  final index = document.indexOfBlockId(blockId);
  if (index == null) return null;
  final block = document.blocks[index];
  final blockStart = document.positionAt(index, 0);
  final blockEnd = document.positionAt(index, block.contentLength);
  if (selection.isCollapsed) {
    if (selection.head < blockStart || selection.head > blockEnd) return null;
    final offset = (selection.head - blockStart).clamp(0, block.contentLength);
    return (start: offset, end: offset);
  }
  if (selection.end < blockStart || selection.start > blockEnd) return null;
  return (
    start: (selection.start - blockStart).clamp(0, block.contentLength),
    end: (selection.end - blockStart).clamp(0, block.contentLength),
  );
}

BlockTextRange? _sentenceRangesTouchedBy(
  String text,
  int localStart,
  int localEnd,
) {
  final sentences = homericSentences(text);
  if (sentences.isEmpty) return const BlockTextRange(0, 0);
  final touched = sentences.where((range) {
    final overlaps = localStart < range.end && localEnd > range.start;
    final caretAtBoundary = localStart == localEnd &&
        localStart >= range.start &&
        localStart <= range.end;
    return overlaps || caretAtBoundary;
  }).toList();
  if (touched.isEmpty) return null;
  if (localStart == localEnd && touched.length > 1) {
    final exact = touched.where((range) => range.start == localStart).toList();
    if (exact.isNotEmpty) {
      return BlockTextRange(exact.first.start, exact.first.end);
    }
  }
  return BlockTextRange(touched.first.start, touched.last.end);
}

@immutable
final class _HomericLineWitness {
  const _HomericLineWitness({
    required this.documentRevision,
    required this.range,
  });

  final int documentRevision;
  final BlockTextRange range;

  @override
  bool operator ==(Object other) =>
      other is _HomericLineWitness &&
      documentRevision == other.documentRevision &&
      range == other.range;

  @override
  int get hashCode => Object.hash(documentRevision, range);
}
