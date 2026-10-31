/// Bulleted and numbered lines with a hanging indent.
///
/// A list line's marker sits in a gutter to the left of its words, and every
/// wrapped line starts where the first line's words start, as a typeset list
/// does. Homeric folds the source marker (`- `, `  1. `) out of the line with
/// [HomericListHang.hide]; the host lays the line out with [HomericListLine],
/// which draws the marker in the gutter, so wrapped lines line up under the
/// words, not under the bullet.
///
/// The marker shows as typed while the caret sits inside it, so it can be
/// edited; the line then reads as plain source until the caret leaves.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart' hide Decoration;

import '../decoration/decoration.dart';
import '../editing/markdown_list_indent.dart';
import '../model/block.dart';
import '../render/letter_metrics.dart';
import 'block_indent.dart';
import 'checklists.dart';
import 'list_glyphs.dart';
import 'syntax_decorations.dart' show HomericChecklistSpec;

/// Replacement spec for the folded marker of a hung list line.
final class HomericListHangSpec {
  const HomericListHangSpec._();

  /// The one instance every hung marker's hide carries.
  static const instance = HomericListHangSpec._();
}

/// A list line laid out with its marker in a gutter.
@immutable
final class HomericListHang {
  /// A hung line in [blockId], [depth] levels deep, showing [mark].
  const HomericListHang({
    required this.blockId,
    required this.depth,
    required this.mark,
    required this.prefixEnd,
    required this.kind,
    this.checklist,
  }) : indent = false;

  /// An indented paragraph in [blockId], [depth] levels in: no marker, its
  /// folded indent ending at [prefixEnd], its words [depth] steps in.
  const HomericListHang.indent({
    required this.blockId,
    required this.depth,
    required this.prefixEnd,
  })  : mark = '',
        kind = HomericMarkdownListKind.bullet,
        checklist = null,
        indent = true;

  /// The block the line is.
  final String blockId;

  /// Nesting: 0 for a top-level item, 1 under it, and so on.
  final int depth;

  /// What the gutter shows: ● ◯ □ by depth, or the item's number.
  final String mark;

  /// End of the folded source (indent, marker and its space).
  final int prefixEnd;

  /// Bullet or numbered; a to-do counts as a bullet.
  final HomericMarkdownListKind kind;

  /// A to-do line's box: where its marker is and whether it is ticked.
  /// Null for a bullet or a number.
  final HomericChecklistSpec? checklist;

  /// Whether this is an indented paragraph rather than a list line: it
  /// has no marker, and its words sit [depth] steps in, where a list
  /// line's sit `depth + 1` ([HomericBlockIndent]).
  final bool indent;

  /// The hang for [block], or null when it is not a list line, or holds
  /// [caret] (a caret offset in the block) inside its marker. A to-do hangs
  /// only with [todos]; otherwise its box stays in the line. [glyphs] off
  /// shows • and numbers as typed. With [indents], a paragraph of one of
  /// [indentTypes] indented at least one level hangs too
  /// ([HomericListHang.indent]).
  static HomericListHang? of(
    Block block, {
    int? caret,
    bool glyphs = true,
    bool todos = false,
    bool indents = false,
    Set<String> indentTypes = HomericBlockIndent.defaultTypes,
  }) {
    final text = block.text;
    final firstLine = text.split('\n').first;
    final todo = HomericChecklists.line.firstMatch(firstLine);
    if (todo != null) {
      if (!todos) return null;
      final bodyStart = firstLine.length - (todo.group(3) ?? '').length;
      if (caret != null && caret < bodyStart) return null;
      final markerStart = firstLine.length - firstLine.trimLeft().length;
      final markerEnd = firstLine.lastIndexOf(RegExp(r'\S'), bodyStart - 1) + 1;
      final done = HomericChecklists.isDone(firstLine, todo);
      return HomericListHang(
        blockId: block.id,
        depth: depthOf(firstLine.substring(0, markerStart)),
        mark: done ? '☑' : '☐',
        prefixEnd: bodyStart,
        kind: HomericMarkdownListKind.bullet,
        checklist: HomericChecklistSpec(
          blockId: block.id,
          markerStart: markerStart,
          markerEnd: markerEnd,
          done: done,
        ),
      );
    }
    final match = HomericMarkdownListPrefix.match(text);
    if (match == null) {
      if (!indents) return null;
      final indent =
          HomericBlockIndent.paragraphIndentOf(block, types: indentTypes);
      if (indent == null || indent.level == 0) return null;
      if (caret != null && caret < indent.prefixEnd) return null;
      return HomericListHang.indent(
        blockId: block.id,
        depth: indent.level,
        prefixEnd: indent.prefixEnd,
      );
    }
    if (caret != null && caret < match.prefixEnd) return null;
    final depth = depthOf(text.substring(0, match.indentLength));
    final String mark;
    switch (match.kind) {
      case HomericMarkdownListKind.bullet:
        mark = glyphs ? HomericListGlyphs.bullet(depth) : '•';
      case HomericMarkdownListKind.ordered:
        final value = int.tryParse(match.orderedDigits) ?? 1;
        mark = glyphs
            ? '${HomericListGlyphs.number(value, depth)}.'
            : '${match.orderedDigits}.';
    }
    return HomericListHang(
      blockId: block.id,
      depth: depth,
      mark: mark,
      prefixEnd: match.prefixEnd,
      kind: match.kind,
    );
  }

  /// Levels in a list line's leading [indent]: a tab, or two spaces, each.
  static int depthOf(String indent) =>
      '\t'.allMatches(indent).length +
      ' '.allMatches(indent).length ~/ HomericMarkdownListIndent.unit.length;

  /// Folds the source marker out of the line; [HomericListLine] draws it.
  Decoration get hide => Decoration.replace(
        blockId,
        0,
        prefixEnd,
        replacementLength: 0,
        spec: HomericListHangSpec.instance,
      );

  @override
  bool operator ==(Object other) =>
      other is HomericListHang &&
      other.blockId == blockId &&
      other.depth == depth &&
      other.mark == mark &&
      other.prefixEnd == prefixEnd &&
      other.kind == kind &&
      other.checklist == checklist &&
      other.indent == indent;

  @override
  int get hashCode =>
      Object.hash(blockId, depth, mark, prefixEnd, kind, checklist, indent);
}

/// Lays out a list line: its marker in a gutter, its words (the [child]
/// paragraph) to the right, every wrapped line starting under the first
/// line's words.
///
/// Each level of nesting moves the gutter one [step] to the right, so a
/// nested item's marker sits under its parent's words. The marker is a
/// [HomericListMark]: a number shares the first line's baseline, and a
/// bullet or a to-do's box centres on the middle of its letters.
///
/// An indented paragraph ([HomericListHang.indent]) lays out the same way,
/// with an empty gutter as wide as its indent.
///
/// With [onIndent], a horizontal swipe on the line nests it (right) or
/// takes it out a level (left): the touch path for Tab and Shift-Tab. The
/// line follows the finger a little while it moves.
class HomericListLine extends StatefulWidget {
  /// Lays out [child] as the list line [hang]; with a null [hang], [child]
  /// at full width with no gutter (the same widget tree, so a line can
  /// become a list line without its paragraph losing focus).
  const HomericListLine({
    super.key,
    required this.hang,
    required this.markStyle,
    required this.child,
    this.step,
    this.onIndent,
    this.swipesAtMargin = false,
    this.todoMark,
    this.todoSize,
    this.textScaler,
    this.textHeightBehavior = const TextHeightBehavior(),
  });

  /// The line, or null when [child] is not hung.
  final HomericListHang? hang;

  /// The marker's style: the line's own text style, the one its paragraph
  /// is laid out with, so the marker's line is exactly as tall.
  final TextStyle markStyle;

  /// Width of one level and of the marker's column. Defaults to 1.5 times
  /// [markStyle]'s font size as drawn (after the text scaler).
  final double? step;

  /// Called with `false` for a swipe right (nest) and `true` for a swipe
  /// left (out a level). Null turns swiping off.
  final ValueChanged<bool>? onIndent;

  /// Whether a line that isn't hung (a paragraph at the margin) swipes
  /// right to indent too. A host turns it on for the line being written
  /// in, so a swipe elsewhere keeps its own meaning.
  final bool swipesAtMargin;

  /// Builds a to-do line's box ([HomericListHang.checklist]), which
  /// [HomericListMark.box] centres on the line's letters. Without it a
  /// to-do shows a plain drawn box.
  final Widget Function(BuildContext context, HomericListHang hang)? todoMark;

  /// The box [todoMark] draws. Defaults to a square 0.8 of the line's text
  /// size, at the system text size.
  final Size? todoSize;

  /// The paragraph's text scaler, when the host gives it one; otherwise
  /// the system text size, as the paragraph's own.
  final TextScaler? textScaler;

  /// The paragraph's line-height behaviour.
  final TextHeightBehavior textHeightBehavior;

  /// The paragraph.
  final Widget child;

  /// Width of one level for [style] at [textScaler]'s size: 1.5 times its
  /// font size as drawn, so the gutter keeps its proportion to the words
  /// at every text size.
  static double stepFor(
    TextStyle style, {
    TextScaler textScaler = TextScaler.noScaling,
  }) =>
      textScaler.scale(style.fontSize ?? 14) * 1.5;

  /// How far [hang]'s words sit from the line's left edge: a list line's
  /// one step past its depth, for its marker; an indented paragraph's at
  /// its depth.
  static double gutterFor(HomericListHang hang, double step) =>
      (hang.depth + (hang.indent ? 0 : 1)) * step;

  /// How far a swipe travels before it counts.
  static const double swipeDistance = 36;

  @override
  State<HomericListLine> createState() => _HomericListLineState();
}

/// Below the paragraph's own touch slop (18), so a sideways swipe on a list
/// line is the line's.
const double _swipeSlop = 8;

/// A flick fast enough to count however short it is.
const double _flingVelocity = 600;

class _HomericListLineState extends State<HomericListLine> {
  double _drag = 0;

  @override
  void didUpdateWidget(HomericListLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hang == null && !widget.swipesAtMargin) _drag = 0;
  }

  Widget _mark(BuildContext context, HomericListHang hang) {
    final scaler = widget.textScaler;
    final behavior = widget.textHeightBehavior;
    if (hang.checklist != null) {
      final size = widget.todoSize ??
          Size.square(
            (scaler ?? HomericListMark._scalerOf(context))
                    .scale(widget.markStyle.fontSize ?? 14) *
                0.8,
          );
      return HomericListMark.box(
        style: widget.markStyle,
        size: size,
        textScaler: scaler,
        textHeightBehavior: behavior,
        child: widget.todoMark?.call(context, hang) ??
            _PlainBox(done: hang.checklist!.done, style: widget.markStyle),
      );
    }
    return switch (hang.kind) {
      HomericMarkdownListKind.bullet => HomericListMark.bullet(
          depth: hang.depth,
          style: widget.markStyle,
          textScaler: scaler,
          textHeightBehavior: behavior,
        ),
      HomericMarkdownListKind.ordered => HomericListMark.label(
          hang.mark,
          style: widget.markStyle,
          textScaler: scaler,
          textHeightBehavior: behavior,
        ),
    };
  }

  // The tree has one shape whether or not the line is hung, so a paragraph
  // that becomes a list line as `- ` is typed keeps its state and focus.
  @override
  Widget build(BuildContext context) {
    final hang = widget.hang;
    final step = widget.step ??
        HomericListLine.stepFor(
          widget.markStyle,
          textScaler: widget.textScaler ?? HomericListMark._scalerOf(context),
        );
    final gutter = hang == null ? 0.0 : HomericListLine.gutterFor(hang, step);
    final todo = hang?.checklist != null;
    final bullet = hang?.kind == HomericMarkdownListKind.bullet && !todo;
    final onIndent =
        hang == null && !widget.swipesAtMargin ? null : widget.onIndent;
    // At the margin there is nowhere left to go.
    final reach = hang == null ? 0.0 : -step;
    final line = Transform.translate(
      offset: Offset(_drag, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: gutter,
            child: hang == null || hang.indent
                ? null
                : Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: hang.depth * step,
                      end: step * (bullet ? 0.3 : (todo ? 0.27 : 0.2)),
                    ),
                    child: Align(
                      // As tall as the mark, whatever room the row has.
                      heightFactor: 1,
                      alignment: bullet
                          ? Alignment.center
                          : AlignmentDirectional.centerEnd,
                      child: KeyedSubtree(
                        key: const ValueKey<String>('homeric-list-mark'),
                        child: _mark(context, hang),
                      ),
                    ),
                  ),
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        if (onIndent != null)
          HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<
              HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(
              supportedDevices: const <PointerDeviceKind>{
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
              },
            ),
            (recognizer) {
              // Claims a sideways move before the paragraph's own drag does
              // (it would select text): on a phone, text is selected by a
              // long press, and a vertical move still scrolls.
              recognizer
                ..gestureSettings = const DeviceGestureSettings(
                  touchSlop: _swipeSlop,
                )
                ..dragStartBehavior = DragStartBehavior.down
                ..onUpdate = (details) {
                  // Follows the finger, up to one level either way.
                  setState(() {
                    _drag = (_drag + details.delta.dx).clamp(reach, step);
                  });
                }
                ..onEnd = (details) {
                  final travelled = _drag;
                  final fling = details.primaryVelocity ?? 0;
                  setState(() => _drag = 0);
                  final distance =
                      math.min(HomericListLine.swipeDistance, step);
                  if (travelled >= distance || fling > _flingVelocity) {
                    onIndent(false);
                  } else if (travelled <= -distance ||
                      fling < -_flingVelocity) {
                    onIndent(true);
                  }
                }
                ..onCancel = () {
                  setState(() => _drag = 0);
                };
            },
          ),
      },
      child: line,
    );
  }
}

/// A list line's marker, for a [Row] that lines it up with its words by
/// baseline ([CrossAxisAlignment.baseline]).
///
/// It is laid out as one line of [style] exactly as the words' paragraph
/// lays out its first line: the same text size (the system's, unless
/// [textScaler] says otherwise), the same leading, and none of the
/// surrounding [DefaultTextStyle], so sharing the baseline never makes the
/// row taller than the words' own line. A number sits on that baseline as
/// text; a bullet or a box centres on the middle of the line's lower-case
/// letters, half an x-height above the baseline
/// ([HomericLetterMetrics]), whatever the face, size or line height.
class HomericListMark extends StatelessWidget {
  /// A drawn bullet: a dot, a ring, then a small square, by [depth].
  const HomericListMark.bullet({
    super.key,
    required int depth,
    required this.style,
    this.textScaler,
    this.textHeightBehavior = const TextHeightBehavior(),
  })  : _depth = depth,
        _label = null,
        _child = null,
        _size = null;

  /// A number or other [label] set as text on the line's baseline.
  const HomericListMark.label(
    String label, {
    super.key,
    required this.style,
    this.textScaler,
    this.textHeightBehavior = const TextHeightBehavior(),
  })  : _label = label,
        _depth = 0,
        _child = null,
        _size = null;

  /// [child], [size] big, centred on the line's letters: a to-do's box.
  const HomericListMark.box({
    super.key,
    required Widget child,
    required Size size,
    required this.style,
    this.textScaler,
    this.textHeightBehavior = const TextHeightBehavior(),
  })  : _child = child,
        _size = size,
        _depth = 0,
        _label = null;

  /// The words' text style.
  final TextStyle style;

  /// The words' text scaler; null for the system text size.
  final TextScaler? textScaler;

  /// The words' line-height behaviour.
  final TextHeightBehavior textHeightBehavior;

  final int _depth;
  final String? _label;
  final Widget? _child;
  final Size? _size;

  /// A bullet's nesting depth (0 for a label or a box).
  int get depth => _depth;

  /// A label's text; null for a bullet or a box.
  String? get label => _label;

  static TextScaler _scalerOf(BuildContext context) =>
      MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;

  /// [style] as the words' paragraph reads it: nothing inherited, so the
  /// leading is the face's own unless [style] sets it.
  static TextStyle _line(TextStyle style) => style.copyWith(inherit: false);

  @override
  Widget build(BuildContext context) {
    final scaler = textScaler ?? _scalerOf(context);
    final color = style.color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFF000000);
    final line = _line(style).copyWith(color: color);
    final label = _label;
    if (label != null) {
      return Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: line,
        textScaler: scaler,
        textHeightBehavior: textHeightBehavior,
      );
    }
    return ListenableBuilder(
      listenable: HomericLetterMetrics.changes,
      builder: (context, _) {
        final probe = TextPainter(
          text: TextSpan(text: 'x', style: line),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          textHeightBehavior: textHeightBehavior,
        )..layout();
        final baseline =
            probe.computeDistanceToActualBaseline(TextBaseline.alphabetic);
        final xWidth = probe.width;
        probe.dispose();
        final mid = baseline -
            HomericLetterMetrics.midlineAboveBaseline(line, textScaler: scaler);
        final fontSize = scaler.scale(style.fontSize ?? 14);
        final size = _size ?? Size.square(fontSize * 0.3);
        final mark = _child ??
            CustomPaint(
              painter: _BulletPainter(shape: _depth % 3, color: color),
            );
        final body = SizedBox(
          width: math.max(xWidth, size.width),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Sets the line's height and baseline; never seen.
              ExcludeSemantics(
                child: Text(
                  'x',
                  style: line.copyWith(color: const Color(0x00000000)),
                  textScaler: scaler,
                  textHeightBehavior: textHeightBehavior,
                ),
              ),
              // Centred across the column it is given as well as on the
              // letters.
              Positioned(
                left: (math.max(xWidth, size.width) - size.width) / 2,
                width: size.width,
                top: mid - size.height / 2,
                height: size.height,
                child: mark,
              ),
            ],
          ),
        );
        return _child == null
            ? Semantics(
                label: HomericListGlyphs.bullet(_depth),
                child: body,
              )
            : body;
      },
    );
  }
}

/// A to-do's box when the host draws none: a rounded square, filled and
/// ticked when done.
class _PlainBox extends StatelessWidget {
  const _PlainBox({required this.done, required this.style});

  final bool done;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Semantics(
        checked: done,
        child: CustomPaint(
          painter: _PlainBoxPainter(
            done: done,
            color: style.color ??
                DefaultTextStyle.of(context).style.color ??
                const Color(0xFF000000),
          ),
        ),
      );
}

class _PlainBoxPainter extends CustomPainter {
  _PlainBoxPainter({required this.done, required this.color});

  final bool done;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      Radius.circular(size.width * 0.2),
    );
    canvas.drawRRect(
      box,
      Paint()
        ..color = color
        ..style = done ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_PlainBoxPainter old) =>
      old.done != done || old.color != color;
}

class _BulletPainter extends CustomPainter {
  _BulletPainter({required this.shape, required this.color});

  final int shape;
  final Color color;

  @override
  void paint(Canvas canvas, Size box) {
    final size = box.shortestSide;
    final center = box.center(Offset.zero);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    switch (shape) {
      case 1:
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = size * 0.18;
        canvas.drawCircle(center, size / 2 - paint.strokeWidth / 2, paint);
      case 2:
        final side = size * 0.86;
        canvas.drawRect(
          Rect.fromCenter(center: center, width: side, height: side),
          paint,
        );
      default:
        canvas.drawCircle(center, size / 2, paint);
    }
  }

  @override
  bool shouldRepaint(_BulletPainter old) =>
      old.shape != shape || old.color != color;
}
