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
import 'checklists.dart';
import 'list_glyphs.dart';

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
  });

  /// The block the line is.
  final String blockId;

  /// Nesting: 0 for a top-level item, 1 under it, and so on.
  final int depth;

  /// What the gutter shows: ● ◯ □ by depth, or the item's number.
  final String mark;

  /// End of the folded source (indent, marker and its space).
  final int prefixEnd;

  /// Bullet or numbered.
  final HomericMarkdownListKind kind;

  /// The hang for [block], or null when it is not a list line, is a to-do
  /// (its box stays in the line), or holds [caret] (a caret offset in the
  /// block) inside its marker. [glyphs] off shows • and numbers as typed.
  static HomericListHang? of(
    Block block, {
    int? caret,
    bool glyphs = true,
  }) {
    final text = block.text;
    final match = HomericMarkdownListPrefix.match(text);
    if (match == null) return null;
    final firstLine = text.split('\n').first;
    if (HomericChecklists.line.hasMatch(firstLine)) return null;
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
      other.kind == kind;

  @override
  int get hashCode => Object.hash(blockId, depth, mark, prefixEnd, kind);
}

/// Lays out a list line: its marker in a gutter, its words (the [child]
/// paragraph) to the right, every wrapped line starting under the first
/// line's words.
///
/// Each level of nesting moves the gutter one [step] to the right, so a
/// nested item's marker sits under its parent's words. The marker shares
/// the first line's baseline.
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
  });

  /// The line, or null when [child] is not hung.
  final HomericListHang? hang;

  /// The marker's style; the line's own text style, usually.
  final TextStyle markStyle;

  /// Width of one level and of the marker's column. Defaults to 1.5 times
  /// [markStyle]'s font size.
  final double? step;

  /// Called with `false` for a swipe right (nest) and `true` for a swipe
  /// left (out a level). Null turns swiping off.
  final ValueChanged<bool>? onIndent;

  /// The paragraph.
  final Widget child;

  /// Width of one level for [style]: 1.5 times its font size.
  static double stepFor(TextStyle style) => (style.fontSize ?? 14) * 1.5;

  /// How far [hang]'s words sit from the line's left edge.
  static double gutterFor(HomericListHang hang, double step) =>
      (hang.depth + 1) * step;

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
    if (widget.hang == null) _drag = 0;
  }

  // The tree has one shape whether or not the line is hung, so a paragraph
  // that becomes a list line as `- ` is typed keeps its state and focus.
  @override
  Widget build(BuildContext context) {
    final hang = widget.hang;
    final step = widget.step ?? HomericListLine.stepFor(widget.markStyle);
    final gutter = hang == null ? 0.0 : HomericListLine.gutterFor(hang, step);
    final bullet = hang?.kind == HomericMarkdownListKind.bullet;
    final onIndent = hang == null ? null : widget.onIndent;
    final line = Transform.translate(
      offset: Offset(_drag, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: gutter,
            child: hang == null
                ? null
                : Padding(
                    padding: EdgeInsets.only(
                      left: hang.depth * step,
                      right: step * (bullet ? 0.3 : 0.2),
                    ),
                    child: Align(
                      alignment:
                          bullet ? Alignment.center : Alignment.centerRight,
                      child: KeyedSubtree(
                        key: const ValueKey<String>('homeric-list-mark'),
                        child: bullet
                            ? _Bullet(
                                depth: hang.depth, style: widget.markStyle)
                            : Text(
                                hang.mark,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.visible,
                                style: widget.markStyle,
                              ),
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
                    _drag = (_drag + details.delta.dx).clamp(-step, step);
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

/// A bullet drawn rather than typed, so it never depends on the font
/// having ● ◯ □: a dot, a ring, then a small square, by depth. It shares the
/// line's baseline through an invisible letter and sits on the middle of
/// the lower-case letters.
class _Bullet extends StatelessWidget {
  const _Bullet({required this.depth, required this.style});

  final int depth;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final fontSize = style.fontSize ?? 14;
    final color = style.color ?? DefaultTextStyle.of(context).style.color;
    return Semantics(
      label: HomericListGlyphs.bullet(depth),
      child: Stack(
        children: [
          // Sets the line's baseline and height; never seen.
          ExcludeSemantics(
            child: Text(
              'x',
              style: style.copyWith(color: const Color(0x00000000)),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _BulletPainter(
                shape: depth % 3,
                color: color ?? const Color(0xFF000000),
                style: style,
                size: fontSize * 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletPainter extends CustomPainter {
  _BulletPainter({
    required this.shape,
    required this.color,
    required this.style,
    required this.size,
  });

  final int shape;
  final Color color;
  final TextStyle style;
  final double size;

  @override
  void paint(Canvas canvas, Size box) {
    final probe = TextPainter(
      text: TextSpan(text: 'x', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final baseline =
        probe.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    final xHeight = (style.fontSize ?? 14) * 0.46;
    probe.dispose();
    // On the middle of an x.
    final center = Offset(box.width / 2, baseline - xHeight / 2);
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
      old.shape != shape ||
      old.color != color ||
      old.style != style ||
      old.size != size;
}
