/// Buttons for the format bar across the top of the desktop selection menu
/// ([HomericEditableDocument.selectionFormatBarBuilder]).
///
/// Each button does what its typed marker or shortcut does, so the menu
/// teaches the syntax: its tooltip names the button, says what it does to
/// the words and shows what typing does the same. A button over words that
/// already carry its marker shows pressed and takes the marker off.
library;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../editing/context_menu.dart' show homericMenuShortcut;
import '../editing/editable_document.dart';
import '../editing/editor_controller.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'block_indent.dart';
import 'note_marks.dart';
import 'syntax_decorations.dart';
import 'typed_wraps.dart';
import 'wrap_shortcuts.dart';

/// The standard format bar buttons.
abstract final class HomericFormatBar {
  /// Bold, Italic, Strikethrough, Highlight, Aside (and with [quote],
  /// Quote), then Code (and with [comment], Comment out), then Link, Note
  /// and Footnote, for [selection] in [controller].
  ///
  /// Link and Note need [wraps] (they do what typing `[[` and `{{` over the
  /// words does, so the host's own link menu or note composer follows);
  /// Footnote needs [onFootnote]. Switch any of the rest off with its flag.
  ///
  /// With [indents], Outdent and Indent end the bar, a group of their own:
  /// they move the whole line ([HomericBlockIndent]), paragraph or list
  /// item, so they work with only a caret. [indentTypes] are the block
  /// types that indent as paragraphs.
  static List<HomericFormatAction> standard(
    HomericEditorController controller,
    HomericSelection selection, {
    HomericTypedWrapsSession? wraps,
    bool highlight = true,
    bool aside = true,
    bool code = true,
    bool quote = false,
    bool comment = false,
    bool link = true,
    bool note = true,
    VoidCallback? onFootnote,
    String? footnoteShortcut,
    bool indents = false,
    Set<String> indentTypes = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? indentFilter,
  }) {
    final words = !selection.isCollapsed;
    HomericFormatAction? typed(
            HomericFormatAction Function() build, String t) =>
        wraps != null && wraps.feature.pairs.containsKey(t) ? build() : null;
    return <HomericFormatAction>[
      HomericFormatBar.bold(controller, selection),
      HomericFormatBar.italic(controller, selection),
      HomericFormatBar.strikethrough(controller, selection),
      if (highlight) HomericFormatBar.highlight(controller, selection),
      if (aside) HomericFormatBar.aside(controller, selection),
      if (quote) HomericFormatBar.quote(controller, selection),
      // Code and Comment out are the quieter tools: a group of their own,
      // last of the styles.
      if (code)
        HomericFormatBar.code(controller, selection)
            .copyWith(startsGroup: quote || comment),
      if (comment)
        HomericFormatBar.comment(controller, selection)
            .copyWith(startsGroup: !code),
      ...<HomericFormatAction?>[
        if (link)
          typed(
              () => HomericFormatBar.link(controller, selection, wraps!), '['),
        if (note)
          typed(
              () => HomericFormatBar.note(controller, selection, wraps!), '{'),
      ].whereType<HomericFormatAction>(),
      if (onFootnote != null)
        HomericFormatAction(
          icon: Icons.superscript_rounded,
          glyph: const HomericFootnoteGlyph(),
          label: 'Footnote',
          description: 'Adds a numbered note after the words, kept at the '
              'foot of the page.',
          syntax: 'words^[note]',
          shortcut: footnoteShortcut,
          onPressed: words ? onFootnote : null,
        ),
      if (indents) ...[
        HomericFormatBar.outdent(
          controller,
          selection,
          types: indentTypes,
          accepts: indentFilter,
        ).copyWith(startsGroup: true),
        HomericFormatBar.indent(
          controller,
          selection,
          types: indentTypes,
          accepts: indentFilter,
        ),
      ],
    ]._groupedAfter(const <String>{'Link', 'Note', 'Footnote'});
  }

  /// Tab: the line one step in, under the line above.
  static HomericFormatAction indent(
    HomericEditorController controller,
    HomericSelection selection, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) =>
      _indent(controller, selection,
          outdent: false, types: types, accepts: accepts);

  /// Shift-Tab: the line one step back toward the margin.
  static HomericFormatAction outdent(
    HomericEditorController controller,
    HomericSelection selection, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) =>
      _indent(controller, selection,
          outdent: true, types: types, accepts: accepts);

  static HomericFormatAction _indent(
    HomericEditorController controller,
    HomericSelection selection, {
    required bool outdent,
    required Set<String> types,
    HomericIndentFilter? accepts,
  }) {
    final possible = HomericBlockIndent.canIndent(
      controller.document,
      selection,
      outdent: outdent,
      types: types,
      accepts: accepts,
    );
    return HomericFormatAction(
      icon: outdent
          ? Icons.format_indent_decrease_rounded
          : Icons.format_indent_increase_rounded,
      label: outdent ? 'Outdent' : 'Indent',
      description: outdent
          ? 'Moves the line a step back toward the margin. Backspace at '
              'the start of its words does the same.'
          : 'Moves the line a step in, under the line above; a list item '
              'nests. A space at the start of its words does the same.',
      shortcut: outdent ? '⇧Tab' : 'Tab',
      actsOnBlock: true,
      onPressed: !possible
          ? null
          : () => HomericBlockIndent.indentSelection(
                controller,
                outdent: outdent,
                types: types,
                accepts: accepts,
              ),
    );
  }

  /// ⌘B: `**words**`.
  static HomericFormatAction bold(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '**',
        icon: Icons.format_bold_rounded,
        label: 'Bold',
        description: 'Gives the words weight, for what must not be missed.',
        shortcut: homericMenuShortcut('B'),
      );

  /// ⌘I: `*words*`.
  static HomericFormatAction italic(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '*',
        icon: Icons.format_italic_rounded,
        label: 'Italic',
        description: 'Leans the words, for stress or a title.',
        shortcut: homericMenuShortcut('I'),
      );

  /// ⇧⌘S: `~~words~~`.
  static HomericFormatAction strikethrough(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '~~',
        icon: Icons.format_strikethrough_rounded,
        label: 'Strikethrough',
        description: 'Crosses the words out and keeps them readable.',
        shortcut: homericMenuShortcut('S', shift: true),
      );

  /// `==words==`.
  static HomericFormatAction highlight(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '==',
        icon: Icons.border_color_outlined,
        glyph: const HomericHighlightGlyph(),
        label: 'Highlight',
        description: 'Marks the words as a pen would, to find them again.',
      );

  /// `++words++`.
  static HomericFormatAction aside(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '++',
        icon: Icons.short_text_rounded,
        glyph: const HomericAsideGlyph(),
        label: 'Aside',
        description: 'Quiets the words into a second voice, said under '
            'your breath.',
      );

  /// ⌘E: `` `words` ``.
  static HomericFormatAction code(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '`',
        icon: Icons.code_rounded,
        label: 'Code',
        description: 'Sets the words in monospace, exactly as typed.',
        shortcut: homericMenuShortcut('E'),
      );

  /// `[[`, keeping the words as the link's text.
  static HomericFormatAction link(
    HomericEditorController controller,
    HomericSelection selection,
    HomericTypedWrapsSession wraps,
  ) =>
      typedWrap(
        controller,
        selection,
        wraps,
        typed: '[',
        icon: Icons.link_rounded,
        label: 'Link',
        description: 'Links the words to another note; they stay as the '
            "link's text.",
        syntax: '[[note|words]]',
      );

  /// `{{`, a note about the words.
  static HomericFormatAction note(
    HomericEditorController controller,
    HomericSelection selection,
    HomericTypedWrapsSession wraps,
  ) =>
      typedWrap(
        controller,
        selection,
        wraps,
        typed: '{',
        icon: Icons.sticky_note_2_outlined,
        label: 'Note',
        description: 'Pins a note to the words, shown beside them in the '
            'margin.',
        syntax: '{{words|note}}',
      );

  /// `> `: the line becomes a quote, or stops being one.
  static HomericFormatAction quote(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      linePrefix(
        controller,
        selection,
        marker: '> ',
        pattern: HomericSyntax.quoteLine,
        icon: Icons.format_quote_rounded,
        glyph: const HomericQuoteGlyph(),
        label: 'Quote',
        description: "Sets the line apart as someone else's words.",
      );

  /// `%% `: the line becomes a note to self, hidden when read, or comes
  /// back.
  static HomericFormatAction comment(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      linePrefix(
        controller,
        selection,
        marker: '%% ',
        pattern: HomericNoteMarks.commentLine,
        icon: Icons.percent_rounded,
        label: 'Comment out',
        description: 'Turns the line into a note to self, kept out of the '
            'text when it is read.',
      );

  /// A button putting [marker] at the start of each line the selection
  /// touches, in paragraphs only, as typing it there does; pressed when
  /// every such line already starts with [pattern], and then it takes the
  /// markers off. It acts on whole lines, so it works with only a caret.
  static HomericFormatAction linePrefix(
    HomericEditorController controller,
    HomericSelection selection, {
    required String marker,
    required RegExp pattern,
    required IconData icon,
    Widget? glyph,
    required String label,
    String? description,
    bool startsGroup = false,
  }) {
    final lines = _prefixLines(controller.document, selection);
    final active =
        lines.isNotEmpty && lines.every((l) => pattern.hasMatch(l.text));
    return HomericFormatAction(
      icon: icon,
      glyph: glyph,
      label: label,
      description: description,
      syntax: '${marker}line',
      startsGroup: startsGroup,
      isStyle: true,
      actsOnBlock: true,
      isActive: active,
      onPressed: lines.isEmpty
          ? null
          : () => _togglePrefix(
                controller,
                controller.selection ?? selection,
                marker,
                pattern,
              ),
    );
  }

  static bool _togglePrefix(
    HomericEditorController controller,
    HomericSelection selection,
    String marker,
    RegExp pattern,
  ) {
    final document = controller.document;
    final lines = _prefixLines(document, selection);
    if (lines.isEmpty) return false;
    final remove = lines.every((l) => pattern.hasMatch(l.text));
    try {
      final tx = Transaction(document);
      // Last line first, so the offsets still to come stay where they were.
      for (final line in lines.reversed) {
        final at = tx.doc.positionAt(line.block, line.start);
        if (remove) {
          final m = pattern.firstMatch(line.text)!;
          tx.deleteRange(at, tx.doc.positionAt(line.block, line.start + m.end));
        } else if (!pattern.hasMatch(line.text)) {
          tx.insertText(at, marker);
        }
      }
      var after = selection.map(tx.mapping);
      // A caret at the start of the line goes after the new marker, where
      // the words begin.
      if (!remove && after.isCollapsed) {
        final caret = tx.doc.resolve(after.head);
        if (caret is InlinePosition) {
          final text = caret.block.text;
          final lineStart = caret.offset == 0
              ? 0
              : text.lastIndexOf('\n', caret.offset - 1) + 1;
          final m = pattern.firstMatch(text.substring(lineStart));
          if (m != null && caret.offset < lineStart + m.end) {
            after = HomericSelection.collapsed(
                after.head + lineStart + m.end - caret.offset);
          }
        }
      }
      return controller.applyPreparedCommand(HomericPreparedCommand(
        stages: <Transaction>[tx],
        selection: after,
      ));
    } on ArgumentError {
      return false;
    }
  }

  /// The lines of paragraphs that [selection] touches: block index, the
  /// line's offset in its block and its text.
  static List<({int block, int start, String text})> _prefixLines(
    Document document,
    HomericSelection selection,
  ) {
    final from = document.resolve(selection.start);
    final to = document.resolve(selection.end);
    if (from is! InlinePosition || to is! InlinePosition) return const [];
    final first = document.indexOfBlockId(from.block.id);
    final last = document.indexOfBlockId(to.block.id);
    if (first == null || last == null) return const [];
    final lines = <({int block, int start, String text})>[];
    for (var index = first; index <= last; index++) {
      final block = document.blocks[index];
      if (block.type != 'paragraph') continue;
      final text = block.text;
      final lo = index == first ? from.offset : 0;
      final hi = index == last ? to.offset : text.length;
      var start = 0;
      for (final line in text.split('\n')) {
        final end = start + line.length;
        // A selection ending at the very start of a line leaves that line
        // be, as the indent buttons do.
        final touched = selection.isCollapsed
            ? lo >= start && lo <= end
            : start < hi && end >= lo && !(start == hi && hi > lo);
        if (touched) lines.add((block: index, start: start, text: line));
        start = end + 1;
      }
    }
    return lines;
  }

  /// A button wrapping the selection in [marker], as
  /// [HomericWrapShortcuts.prepareWrap] does; pressed when it already is.
  static HomericFormatAction wrap(
    HomericEditorController controller,
    HomericSelection selection, {
    required String marker,
    required IconData icon,
    Widget? glyph,
    required String label,
    String? description,
    String? syntax,
    String? shortcut,
    bool startsGroup = false,
  }) {
    final command = HomericWrapShortcuts.prepareWrap(
      controller.document,
      selection,
      marker,
    );
    return HomericFormatAction(
      icon: icon,
      glyph: glyph,
      label: label,
      description: description,
      syntax: syntax ?? '${marker}words${marker.split('').reversed.join()}',
      shortcut: shortcut,
      startsGroup: startsGroup,
      isStyle: true,
      isActive: HomericWrapShortcuts.isWrapped(
        controller.document,
        selection,
        marker,
      ),
      onPressed: command == null
          ? null
          : () {
              final fresh = HomericWrapShortcuts.prepareWrap(
                controller.document,
                controller.selection ?? selection,
                marker,
              );
              if (fresh != null) controller.applyPreparedCommand(fresh);
            },
    );
  }

  /// A button doing what typing [typed] over the words does
  /// ([HomericTypedWrapsSession.prepareMenuWrap]); pressed when the words
  /// already carry the whole pair.
  static HomericFormatAction typedWrap(
    HomericEditorController controller,
    HomericSelection selection,
    HomericTypedWrapsSession wraps, {
    required String typed,
    required IconData icon,
    required String label,
    String? description,
    String? syntax,
    String? shortcut,
    bool startsGroup = false,
  }) {
    final possible = wraps.canMenuWrap(selection, typed);
    return HomericFormatAction(
      icon: icon,
      label: label,
      description: description,
      syntax: syntax,
      shortcut: shortcut,
      startsGroup: startsGroup,
      isActive: wraps.isWrapped(selection, typed),
      onPressed: !possible
          ? null
          : () {
              final command = wraps.prepareMenuWrap(
                controller.selection ?? selection,
                typed,
              );
              if (command != null) controller.applyPreparedCommand(command);
            },
    );
  }
}

extension on List<HomericFormatAction> {
  /// The same buttons, a rule before the first of [labels].
  List<HomericFormatAction> _groupedAfter(Set<String> labels) {
    var marked = false;
    return <HomericFormatAction>[
      for (final action in this)
        if (!marked && labels.contains(action.label) && (marked = true))
          action.copyWith(startsGroup: true)
        else
          action,
    ];
  }
}

/// The Footnote button's mark: a letter with a raised 1 after it, `a¹`, the
/// way a footnote's number sits after the words it belongs to.
///
/// Drawn rather than taken from an icon font: the nearest icons read as
/// something else (a numbered list, or a superscript `x²` for math). Sized
/// and inked by the surrounding [IconTheme], like an [Icon], on the same
/// 24-unit grid and stroke weight as the rounded icons beside it.
class HomericFootnoteGlyph extends StatelessWidget {
  /// Creates the mark, [size] square in [color] (else the [IconTheme]'s).
  const HomericFootnoteGlyph({super.key, this.size, this.color});

  /// Its width and height; the [IconTheme]'s size when null.
  final double? size;

  /// Its ink; the [IconTheme]'s colour when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? 24;
    final ink = color ?? theme.color ?? const Color(0xFF000000);
    return Semantics(
      excludeSemantics: true,
      // Centred, as an Icon draws its glyph, when the button hands it tight
      // constraints larger than the mark.
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox.square(
          dimension: side,
          child: CustomPaint(
            painter: _FootnoteGlyphPainter(
              ink.withValues(alpha: ink.a * (theme.opacity ?? 1)),
            ),
          ),
        ),
      ),
    );
  }
}

class _FootnoteGlyphPainter extends CustomPainter {
  _FootnoteGlyphPainter(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // One path per letter, so where the bowl meets the stem a half-ink
    // stroke does not darken twice.
    final a = Path()
      ..addOval(Rect.fromCircle(center: const Offset(9, 14.6), radius: 4.7))
      ..moveTo(13.7, 9.9)
      ..lineTo(13.7, 19.3);
    final one = Path()
      ..moveTo(16.9, 6.4)
      ..lineTo(19.1, 4.4)
      ..lineTo(19.1, 11.6);
    canvas
      ..drawPath(a, pen)
      ..drawPath(one, pen..strokeWidth = 1.8);
  }

  @override
  bool shouldRepaint(_FootnoteGlyphPainter old) => old.ink != ink;
}

/// The Highlight button's mark: the pen, with the stroke it leaves drawn in
/// the highlighter's yellow, so it reads as "highlight", not "edit".
///
/// Sized and inked by the surrounding [IconTheme], like an [Icon]; the
/// yellow fades with the ink when the button is disabled.
class HomericHighlightGlyph extends StatelessWidget {
  /// Creates the mark, [size] square, its pen in [color] (else the
  /// [IconTheme]'s).
  const HomericHighlightGlyph({super.key, this.size, this.color});

  /// Its width and height; the [IconTheme]'s size when null.
  final double? size;

  /// The pen's ink; the [IconTheme]'s colour when null.
  final Color? color;

  /// The stroke's yellow.
  static const Color yellow = Color(0xFFF2C94C);

  @override
  Widget build(BuildContext context) => _glyph(
        context,
        size,
        color,
        (ink) => _HighlightGlyphPainter(ink),
        // The pen sits above the stroke it leaves.
        under: (side, ink) => Align(
          alignment: const Alignment(0, -1),
          child: Icon(Icons.edit_outlined, size: side * 0.8, color: ink),
        ),
      );
}

/// The Aside button's mark: a small letter in parentheses, `(a)`, words
/// said in passing.
class HomericAsideGlyph extends StatelessWidget {
  /// Creates the mark, [size] square in [color] (else the [IconTheme]'s).
  const HomericAsideGlyph({super.key, this.size, this.color});

  /// Its width and height; the [IconTheme]'s size when null.
  final double? size;

  /// Its ink; the [IconTheme]'s colour when null.
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      _glyph(context, size, color, (ink) => _AsideGlyphPainter(ink));
}

/// The Quote button's mark: a letter behind a quote's rule, `|a`, as a
/// quote sits in the text.
class HomericQuoteGlyph extends StatelessWidget {
  /// Creates the mark, [size] square in [color] (else the [IconTheme]'s).
  const HomericQuoteGlyph({super.key, this.size, this.color});

  /// Its width and height; the [IconTheme]'s size when null.
  final double? size;

  /// Its ink; the [IconTheme]'s colour when null.
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      _glyph(context, size, color, (ink) => _QuoteGlyphPainter(ink));
}

/// A drawn mark [size] square (else the [IconTheme]'s), inked [color] (else
/// the [IconTheme]'s), centred as an [Icon] is; [under] draws an icon
/// beneath the painted strokes.
Widget _glyph(
  BuildContext context,
  double? size,
  Color? color,
  CustomPainter Function(Color ink) painter, {
  Widget Function(double side, Color ink)? under,
}) {
  final theme = IconTheme.of(context);
  final side = size ?? theme.size ?? 24;
  final base = color ?? theme.color ?? const Color(0xFF000000);
  final ink = base.withValues(alpha: base.a * (theme.opacity ?? 1));
  return Semantics(
    excludeSemantics: true,
    child: Center(
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox.square(
        dimension: side,
        child: CustomPaint(
          foregroundPainter: painter(ink),
          child: under?.call(side, ink),
        ),
      ),
    ),
  );
}

Paint _pen(Color ink, [double width = 2.1]) => Paint()
  ..color = ink
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

class _HighlightGlyphPainter extends CustomPainter {
  _HighlightGlyphPainter(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    // Toolbars ink their icons at about half; the yellow keeps full
    // strength there and fades only as a disabled button's ink does.
    final strength = (ink.a * 2).clamp(0.0, 1.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(3, 20, 21, 23.4),
        const Radius.circular(1.7),
      ),
      Paint()
        ..color =
            HomericHighlightGlyph.yellow.withValues(alpha: 0.95 * strength),
    );
  }

  @override
  bool shouldRepaint(_HighlightGlyphPainter old) => old.ink != ink;
}

class _AsideGlyphPainter extends CustomPainter {
  _AsideGlyphPainter(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final parens = Path()
      ..moveTo(7, 4.5)
      ..quadraticBezierTo(2.6, 12, 7, 19.5)
      ..moveTo(17, 4.5)
      ..quadraticBezierTo(21.4, 12, 17, 19.5);
    final a = Path()
      ..addOval(Rect.fromCircle(center: const Offset(11.1, 13.6), radius: 3.1))
      ..moveTo(14.2, 10.5)
      ..lineTo(14.2, 16.7);
    canvas
      ..drawPath(parens, _pen(ink, 1.9))
      ..drawPath(a, _pen(ink, 1.9));
  }

  @override
  bool shouldRepaint(_AsideGlyphPainter old) => old.ink != ink;
}

class _QuoteGlyphPainter extends CustomPainter {
  _QuoteGlyphPainter(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final rule = Path()
      ..moveTo(4.6, 4.6)
      ..lineTo(4.6, 19.4);
    final a = Path()
      ..addOval(Rect.fromCircle(center: const Offset(13.2, 14.6), radius: 4.7))
      ..moveTo(17.9, 9.9)
      ..lineTo(17.9, 19.3);
    canvas
      ..drawPath(rule, _pen(ink, 2.6))
      ..drawPath(a, _pen(ink));
  }

  @override
  bool shouldRepaint(_QuoteGlyphPainter old) => old.ink != ink;
}
