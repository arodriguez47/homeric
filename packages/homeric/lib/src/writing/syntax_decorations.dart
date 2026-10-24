/// Live preview for typed syntax: the decorations that fold markdown and
/// the writing layer away until the caret reaches them.
///
/// [HomericSyntax] reads one block's text and returns [Decoration]s whose
/// specs are the types in this file: [HomericMarkSpec] for styled runs,
/// and slot payloads ([HomericFootnoteSpec], [HomericWikiLinkSpec],
/// [HomericChecklistSpec] and the rest) for what the host draws in place.
/// The host keeps its look: it maps a [HomericMarkKind] to a text style in
/// its run style resolver and builds each slot in its slot builder. Each
/// form can be switched off.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart' hide Decoration;

import '../decoration/decoration.dart';
import '../decoration/markdown_mark_visibility.dart';
import '../editing/markdown_inline.dart';
import '../editing/markdown_list_indent.dart';
import '../model/block.dart';
import '../render/homeric_paragraph.dart' show HomericGluedSlot;
import '../render/paint_layers.dart';
import '../render/paragraph_geometry.dart';
import '../view/view_text.dart' show ReplacementContent;
import 'checklists.dart';
import 'divider.dart';
import 'list_glyphs.dart';
import 'list_hang.dart';
import 'marker_stroke.dart';
import 'note_marks.dart';
import 'tags.dart';
import 'wiki_links.dart';

/// What a styled run is.
enum HomericMarkKind {
  /// `**bold**` or a bold attribute.
  bold,

  /// `*italic*` or an italic attribute.
  italic,

  /// `` `code` `` or a code attribute.
  code,

  /// A markdown `[label](url)` link, or the words of a `[[link]]` being
  /// edited.
  link,

  /// The passage of a `{{passage|note}}` annotation.
  annotation,

  /// `==highlight==`.
  highlight,

  /// An ATX heading's text; [HomericMarkSpec.headingLevel] says which.
  heading,

  /// An inline `#tag`.
  tag,

  /// `++aside++`: the writer's second voice, muted in place.
  comment,

  /// The words of a `%% line`: a note to self, kept out of the text. Hosts
  /// set it apart from prose and from a [quote].
  commentLine,

  /// The words of a `> ` line: someone else's words, quoted.
  quote,

  /// `~~struck~~`, and a ticked to-do's words.
  strike,

  /// The note of a `[^id]: note` line.
  footnote,

  /// The first letter of a `^^` paragraph, set as a large initial.
  dropCap,
}

/// The spec of a styled run.
@immutable
class HomericMarkSpec {
  /// Creates a spec of [kind].
  const HomericMarkSpec(this.kind, {this.href, this.headingLevel});

  /// What the run is.
  final HomericMarkKind kind;

  /// A link's destination.
  final String? href;

  /// A heading's level, 1 to 6.
  final int? headingLevel;

  @override
  bool operator ==(Object other) =>
      other is HomericMarkSpec &&
      other.kind == kind &&
      other.href == href &&
      other.headingLevel == headingLevel;

  @override
  int get hashCode => Object.hash(kind, href, headingLevel);
}

/// Which syntax a host reads, and the decorations for a block.
@immutable
final class HomericSyntax {
  /// Creates a reader with every form on unless switched off.
  const HomericSyntax({
    this.markdown = true,
    this.wikiLinks = true,
    this.tags = true,
    this.checklists = true,
    this.dividers = true,
    this.comments = true,
    this.annotations = true,
    this.footnotes = true,
    this.strike = true,
    this.dropCaps = true,
    this.images = true,
    this.listGlyphs = true,
    this.hangingLists = false,
  });

  /// Every form.
  static const all = HomericSyntax();

  /// A quote line's marker: `> ` at the start of a line, or a lone `>`
  /// that keeps a blank line inside a quote.
  static final RegExp quoteLine = RegExp(r'^>(?: |$)');

  /// Whether every line of [text] is quoted, so a host can draw the
  /// paragraph as a block quote.
  static bool isQuote(String text) =>
      text.isNotEmpty && text.split('\n').every(quoteLine.hasMatch);

  /// Whether every line of [text] is a `%%` comment, so a host can set the
  /// paragraph apart as a note to self.
  static bool isCommentLines(String text) =>
      text.isNotEmpty &&
      text.split('\n').every(HomericNoteMarks.commentLine.hasMatch);

  /// Markdown: `**bold**`, `*italic*`, `` `code` ``, `# headings`, `> `
  /// quotes, `==highlight==`, `[label](url)` links, list markers, and
  /// styles carried as run attributes.
  final bool markdown;

  /// `[[links]]`, folded to a slot ([HomericWikiLinkSpec]).
  final bool wikiLinks;

  /// Inline `#tags`.
  final bool tags;

  /// To-do lines, with a box slot ([HomericChecklistSpec]).
  final bool checklists;

  /// `---` alone in a paragraph, drawn as a rule ([HomericDividerSpec]).
  final bool dividers;

  /// `++aside++` and `%% line` comments.
  final bool comments;

  /// `{{passage}}` and `{{passage|note}}`.
  final bool annotations;

  /// `^[note]`, `[^id]` and `[^id]: note`, as numbered markers
  /// ([HomericFootnoteSpec]).
  final bool footnotes;

  /// `~~struck~~`.
  final bool strike;

  /// `^^` drop caps.
  final bool dropCaps;

  /// `(img src|caption)` pictures ([HomericImageSpec]).
  final bool images;

  /// List markers by depth ([HomericListGlyphs]): ● ◯ □ and 1 / a / I.
  /// Off, a bullet shows as • and a number as typed.
  final bool listGlyphs;

  /// List lines with a hanging indent ([HomericListHang]): the marker is
  /// folded out of the line for the host to draw in a gutter with
  /// [HomericListLine], so wrapped lines start under the words. Off, the
  /// marker shows in the line. A host that turns this on lays list lines
  /// out with [HomericListLine], or their markers go missing.
  final bool hangingLists;

  /// The decorations for [block].
  ///
  /// A `[[link]]`, `{{annotation}}`, `++aside++` or `~~strike~~` holding
  /// [caret] (a caret offset in this block), or just after it, shows its
  /// whole source so it can be edited. [noteMarkers] puts the small mark
  /// after an annotated passage; off when its note is shown as a sidenote
  /// instead.
  ///
  /// With [dropCap], a `^^` initial is sunk into the first two lines
  /// instead of raised above the first.
  Iterable<Decoration> decorationsFor(
    Block block, {
    int? caret,
    bool noteMarkers = true,
    HomericDropCapLayout? dropCap,
  }) {
    // `---` alone: a divider in place of its source, which shows with the
    // caret on the line.
    if (dividers &&
        caret == null &&
        block.type == 'paragraph' &&
        HomericDivider.isLine(block.text)) {
      return [
        markdownMarkHideReplacement(block.id, 0, block.text.length),
        Decoration.widget(block.id, 0, spec: const HomericDividerSpec()),
      ];
    }
    final scan = HomericMarkScan(block.text);
    final layer = _layerDecorations(
      this,
      block,
      scan,
      caret: caret,
      noteMarkers: noteMarkers,
      dropCap: dropCap,
    ).toList();
    final rest = <Decoration>[
      if (markdown) ...[
        ..._attributeMarkDecorations(block),
        ..._markdownBlockDecorations(block),
        ..._markdownMarkDecorations(block),
        ..._listMarkDecorations(
          block,
          glyphs: listGlyphs,
          hang: hangingLists ? listHangFor(block, caret: caret) : null,
          caret: hangingLists ? caret : null,
        ),
        ..._linkMarkDecorations(block),
      ],
      if (wikiLinks) ..._wikiLinkMarkDecorations(block, caret: caret),
      if (tags) ..._tagMarkDecorations(block),
      if (checklists) ..._checklistDecorations(block, caret: caret),
    ];
    final folded = [
      if (annotations || footnotes) ...scan.foldedSpans,
      // An image's source is folded into its picture.
      if (images)
        for (final m in scan.images) (m.start, m.end),
    ];
    return _withoutOverlappingHides([
      ...layer,
      // A footnote's or annotation's note is folded out of the line; marks
      // written inside it must not paint or open slots there.
      if (folded.isEmpty)
        ...rest
      else
        for (final d in rest) ..._outsideFolded(d, folded),
    ]);
  }

  /// The hanging-indent layout for [block] when [hangingLists] is on and
  /// [block] is a list line whose marker does not hold [caret]; null
  /// otherwise. The host passes it to [HomericListLine].
  HomericListHang? listHangFor(Block block, {int? caret}) =>
      markdown && hangingLists
          ? HomericListHang.of(block, caret: caret, glyphs: listGlyphs)
          : null;

  /// Homeric refuses a paragraph whose hidden ranges overlap, so where two
  /// marks claim the same characters (`[[a **b]] c**`) the outer, earlier
  /// one wins and the other's hides, slots and styles inside it are
  /// dropped. For hosts that add decorations of their own.
  static List<Decoration> withoutOverlappingHides(
    List<Decoration> decorations,
  ) =>
      _withoutOverlappingHides(decorations);

  /// The marker [spec] points at in [text], ticked or unticked. Null when
  /// [text] no longer holds that marker.
  static String? toggledChecklistMarker(
    String text,
    HomericChecklistSpec spec,
  ) {
    if (spec.markerEnd > text.length) return null;
    return HomericChecklists.toggled(
      text.substring(spec.markerStart, spec.markerEnd),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomericSyntax &&
      other.markdown == markdown &&
      other.wikiLinks == wikiLinks &&
      other.tags == tags &&
      other.checklists == checklists &&
      other.dividers == dividers &&
      other.comments == comments &&
      other.annotations == annotations &&
      other.footnotes == footnotes &&
      other.strike == strike &&
      other.dropCaps == dropCaps &&
      other.images == images &&
      other.listGlyphs == listGlyphs &&
      other.hangingLists == hangingLists;

  @override
  int get hashCode => Object.hash(
        markdown,
        wikiLinks,
        tags,
        checklists,
        dividers,
        comments,
        annotations,
        footnotes,
        strike,
        dropCaps,
        images,
        listGlyphs,
        hangingLists,
      );
}

/// Colours for the paint layers under and over styled runs.
@immutable
final class HomericSyntaxPaint {
  /// Creates the paint with these colours.
  const HomericSyntaxPaint({
    this.annotationUnderline = const Color(0x992F6F66),
    this.tagWash = const Color(0x2E5FA89C),
    this.highlightWash = const Color(0x55E8C547),
  });

  /// The soft underline under an annotated passage.
  final Color annotationUnderline;

  /// The pill behind an inline `#tag`.
  final Color tagWash;

  /// The marker ink behind `==highlight==`, drawn as a hand-drawn stroke
  /// ([markerStrokePainter]) rather than a flat box.
  final Color highlightWash;

  /// Annotation underlines, tag pills and highlight strokes for the
  /// [HomericMarkSpec] runs in [decorations].
  List<PaintLayer> layersFor(Iterable<Decoration> decorations) {
    final layers = <PaintLayer>[];
    final all = decorations.toList();
    // Hidden text: a highlight split around a folded note continues the
    // same mark when only hidden text lies between its pieces.
    final hidden = [
      for (final d in all)
        if (d.kind == DecorationKind.replace) (d.start, d.end),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var highlights = -1;
    int? lastHighlightEnd;
    for (final decoration in all) {
      final spec = decoration.spec;
      if (spec is! HomericMarkSpec) continue;
      final range = DocRange(
        DocOffset(decoration.start),
        DocOffset(decoration.end),
      );
      switch (spec.kind) {
        case HomericMarkKind.annotation:
          // Quiet: a soft underline, no wash.
          layers.add(
            PaintLayer(
              range: range,
              band: PaintBand.overlay,
              painter: underlinePainter,
              spec: UnderlineSpec(annotationUnderline),
            ),
          );
        case HomericMarkKind.tag:
          layers.add(
            PaintLayer(
              range: range,
              band: PaintBand.underlay,
              painter: tagPillPainter,
              spec: SolidWashSpec(tagWash),
            ),
          );
        case HomericMarkKind.highlight:
          final last = lastHighlightEnd;
          if (last == null || !_allHidden(last, decoration.start, hidden)) {
            highlights++;
          }
          lastHighlightEnd = decoration.end;
          layers.add(
            PaintLayer(
              range: range,
              band: PaintBand.underlay,
              painter: markerStrokePainter,
              fit: PaintLayerFit.inkLine,
              // Each highlight in a block keeps its own stroke while its
              // words are edited: the seed is which one it is, not what
              // it says.
              spec: MarkerStrokeSpec(
                highlightWash,
                seed: _stableHash(decoration.blockId) + 7919 * highlights,
              ),
            ),
          );
        default:
          break;
      }
    }
    return layers;
  }

  /// A rounded wash a little wider than a tag's text.
  static void tagPillPainter(Canvas canvas, Rect rect, Object? spec) {
    final color = spec is SolidWashSpec ? spec.color : const Color(0x2E5FA89C);
    final pill = Rect.fromLTRB(
      rect.left - 3,
      rect.top + rect.height * 0.12,
      rect.right + 3,
      rect.bottom - rect.height * 0.08,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pill, Radius.circular(pill.height / 2.4)),
      Paint()..color = color,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomericSyntaxPaint &&
      other.annotationUnderline == annotationUnderline &&
      other.tagWash == tagWash &&
      other.highlightWash == highlightWash;

  @override
  int get hashCode => Object.hash(annotationUnderline, tagWash, highlightWash);
}

/// Whether every offset from [start] to [end] lies inside one of the
/// sorted [hidden] ranges.
bool _allHidden(int start, int end, List<(int, int)> hidden) {
  var at = start;
  for (final (from, to) in hidden) {
    if (at >= end) break;
    if (from > at) return false;
    if (to > at) at = to;
  }
  return at >= end;
}

/// [text] hashed the same way on every run and platform (FNV-1a).
int _stableHash(String text) {
  var h = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// [d] with the folded spans taken out. A style that runs across a fold,
/// such as a heading's, keeps the text either side; a hide or a slot
/// inside one goes.
Iterable<Decoration> _outsideFolded(
  Decoration d,
  List<(int, int)> folded,
) sync* {
  final hits = [
    for (final r in folded)
      if (d.end > r.$1 && d.start < r.$2) r,
  ];
  if (hits.isEmpty) {
    yield d;
    return;
  }
  if (d.kind != DecorationKind.inline) return;
  hits.sort((a, b) => a.$1.compareTo(b.$1));
  var from = d.start;
  for (final (start, end) in hits) {
    if (start > from) {
      yield Decoration.inline(d.blockId, from, start, spec: d.spec);
    }
    if (end > from) from = end;
  }
  if (from < d.end) {
    yield Decoration.inline(d.blockId, from, d.end, spec: d.spec);
  }
}

/// Homeric refuses a paragraph whose hidden ranges overlap, so where two
/// marks claim the same characters (`[[a **b]] c**`) the outer, earlier
/// one wins and the other's hides, slots and styles inside it are dropped.
List<Decoration> _withoutOverlappingHides(List<Decoration> decorations) {
  final replaces =
      decorations.where((d) => d.kind == DecorationKind.replace).toList()
        ..sort(
          (a, b) => a.start != b.start
              ? a.start.compareTo(b.start)
              : b.end.compareTo(a.end),
        );
  final kept = <Decoration>[];
  for (final d in replaces) {
    if (kept.isEmpty || d.start >= kept.last.end) kept.add(d);
  }
  if (kept.length == replaces.length) return decorations;
  final keptSet = kept.toSet();
  return [
    for (final d in decorations)
      if (d.kind == DecorationKind.replace)
        if (keptSet.contains(d)) d else ...const <Decoration>[]
      else if (!kept.any(
        (h) => d.kind == DecorationKind.widget
            ? d.start > h.start && d.start < h.end
            : d.start >= h.start && d.end <= h.end && d.end > d.start,
      ))
        d,
  ];
}

/// Widget-slot payload for a footnote marker; the host looks its number up
/// by [key] so markers renumber as footnotes come and go elsewhere.
class HomericFootnoteSpec implements HomericGluedSlot {
  const HomericFootnoteSpec(this.key, {this.definition = false});
  final String key;

  /// The marker that opens a `[^id]: note` line rather than a reference.
  final bool definition;

  @override
  bool operator ==(Object other) =>
      other is HomericFootnoteSpec &&
      other.key == key &&
      other.definition == definition;

  @override
  int get hashCode => Object.hash(key, definition);
}

/// Widget-slot payload for an annotation's note, shown beside its passage.
class HomericAnnotationNoteSpec implements HomericGluedSlot {
  const HomericAnnotationNoteSpec(this.note);
  final String note;

  @override
  bool operator ==(Object other) =>
      other is HomericAnnotationNoteSpec && other.note == note;

  @override
  int get hashCode => note.hashCode;
}

/// Where a sunk initial sits in its paragraph, measured from the laid-out
/// text: the line-two offset gets an indent the letter's width, and
/// [fill] tops up line one so that indent can't ride up onto it.
@immutable
class HomericDropCapLayout {
  const HomericDropCapLayout({
    required this.indent,
    double? indentTwo,
    this.lineTwo,
    this.fill = 0,
  }) : indentTwo = indentTwo ?? indent;

  /// Line one's room for the letter: its width there plus a gap.
  final double indent;

  /// Line two's room, which differs where the letter's shape does.
  final double indentTwo;

  /// Where the second line starts, once the text has been laid out.
  final int? lineTwo;
  final double fill;

  @override
  bool operator ==(Object other) =>
      other is HomericDropCapLayout &&
      other.indent == indent &&
      other.indentTwo == indentTwo &&
      other.lineTwo == lineTwo &&
      other.fill == fill;

  @override
  int get hashCode => Object.hash(indent, indentTwo, lineTwo, fill);
}

/// Widget-slot payload for a `---` divider line.
@immutable
class HomericDividerSpec {
  const HomericDividerSpec();

  @override
  bool operator ==(Object other) => other is HomericDividerSpec;

  @override
  int get hashCode => (HomericDividerSpec).hashCode;
}

/// An empty slot [width] wide: room beside a sunk initial.
@immutable
class HomericGapSpec {
  const HomericGapSpec(this.width);
  final double width;

  @override
  bool operator ==(Object other) =>
      other is HomericGapSpec && other.width == width;

  @override
  int get hashCode => width.hashCode;
}

/// Widget-slot payload for an `(img src|caption)` mark: the picture, shown
/// large when it has its paragraph to itself and small inside a line.
@immutable
class HomericImageSpec {
  const HomericImageSpec({
    required this.blockId,
    required this.start,
    required this.end,
    required this.src,
    this.caption,
    this.alone = false,
  });
  final String blockId;

  /// The mark's source range in its block, so the host can rewrite it.
  final int start;
  final int end;
  final String src;
  final String? caption;
  final bool alone;

  @override
  bool operator ==(Object other) =>
      other is HomericImageSpec &&
      other.blockId == blockId &&
      other.start == start &&
      other.end == end &&
      other.src == src &&
      other.caption == caption &&
      other.alone == alone;

  @override
  int get hashCode => Object.hash(blockId, start, end, src, caption, alone);
}

/// The writing layer ([homericStripMarks] lists the forms). Each form
/// folds its syntax away in live preview; the caret reveals it.
Iterable<Decoration> _layerDecorations(
  HomericSyntax on,
  Block block,
  HomericMarkScan scan, {
  int? caret,
  required bool noteMarkers,
  HomericDropCapLayout? dropCap,
}) sync* {
  final id = block.id;
  // A mark folded in two places (its opening and its close) would only
  // reveal the half the caret touches; with the caret in it, it shows all.
  bool editing(RegExpMatch m) =>
      caret != null && caret >= m.start && caret <= m.end;

  // `%% line`: the whole line is comment.
  for (final line in on.comments ? scan.commentLines : const <Never>[]) {
    yield markdownMarkHideReplacement(id, line.start, line.bodyStart);
    if (line.bodyStart < line.end) {
      yield Decoration.inline(
        id,
        line.bodyStart,
        line.end,
        spec: const HomericMarkSpec(HomericMarkKind.commentLine),
      );
    }
  }

  // `^^` opening a paragraph: its first letter as a large initial. Sunk,
  // the letter is drawn beside the text and its source folds away; with
  // the caret on it, it rises above the first line to be edited.
  for (final m in on.dropCaps ? scan.dropCaps : const <Never>[]) {
    final onInitial = caret != null && caret >= m.start && caret <= m.letterEnd;
    if (dropCap != null && !onInitial) {
      yield markdownMarkHideReplacement(id, m.start, m.letterEnd);
      yield Decoration.widget(id, m.start,
          spec: HomericGapSpec(dropCap.indent));
      final lineTwo = dropCap.lineTwo;
      // The layout is measured after each frame, so right after an edit
      // it can name an offset the shortened text no longer has.
      if (lineTwo != null &&
          lineTwo > m.letterEnd &&
          lineTwo < block.text.length) {
        if (dropCap.fill > 0) {
          yield Decoration.widget(id, lineTwo,
              spec: HomericGapSpec(dropCap.fill));
        }
        yield Decoration.widget(
          id,
          lineTwo,
          spec: HomericGapSpec(dropCap.indentTwo),
        );
      }
      continue;
    }
    if (!onInitial) {
      yield markdownMarkHideReplacement(id, m.start, m.end);
    }
    yield Decoration.inline(
      id,
      m.end,
      m.letterEnd,
      spec: const HomericMarkSpec(HomericMarkKind.dropCap),
    );
  }

  // `++aside++` and `~~struck~~`.
  for (final (matches, kind) in [
    if (on.comments) (scan.asides, HomericMarkKind.comment),
    if (on.strike) (scan.strikes, HomericMarkKind.strike),
  ]) {
    for (final m in matches) {
      if (!editing(m)) {
        yield markdownMarkHideReplacement(id, m.start, m.start + 2);
        yield markdownMarkHideReplacement(id, m.end - 2, m.end);
      }
      yield Decoration.inline(
        id,
        m.start + 2,
        m.end - 2,
        spec: HomericMarkSpec(kind),
      );
    }
  }

  // `{{passage}}` / `{{passage|note}}`.
  for (final m in on.annotations ? scan.annotations : const <Never>[]) {
    final passageEnd = m.start + 2 + m.group(1)!.length;
    final open = editing(m);
    if (!open) {
      yield markdownMarkHideReplacement(id, m.start, m.start + 2);
      yield markdownMarkHideReplacement(id, passageEnd, m.end);
    }
    yield Decoration.inline(
      id,
      m.start + 2,
      passageEnd,
      spec: const HomericMarkSpec(HomericMarkKind.annotation),
    );
    if (open && passageEnd < m.end - 2) {
      // The `|note` reads quieter than the passage.
      yield Decoration.inline(
        id,
        passageEnd,
        m.end - 2,
        spec: const HomericMarkSpec(HomericMarkKind.comment),
      );
    }
    final note = m.group(2)?.trim() ?? '';
    if (noteMarkers && !open && note.isNotEmpty) {
      yield Decoration.widget(
        id,
        passageEnd,
        spec: HomericAnnotationNoteSpec(note),
      );
    }
  }

  // `(img src|caption)`: the picture in place of its source, which is
  // edited from the picture itself.
  for (final m in on.images ? scan.images : const <Never>[]) {
    yield markdownMarkHideReplacement(id, m.start, m.end);
    final caption = m.group(2)?.trim();
    yield Decoration.widget(
      id,
      m.start,
      spec: HomericImageSpec(
        blockId: id,
        start: m.start,
        end: m.end,
        src: m.group(1)!,
        caption: caption == null || caption.isEmpty ? null : caption,
        alone: block.text.trim() == m.group(0),
      ),
    );
  }

  // `[^id]: note` — the footnote's own line.
  for (final d in on.footnotes ? scan.definitions : const <Never>[]) {
    yield markdownMarkHideReplacement(id, d.start, d.noteStart);
    yield Decoration.widget(
      id,
      d.start,
      spec: HomericFootnoteSpec(homericFootnoteRefKey(d.id), definition: true),
    );
    if (d.noteStart < d.end) {
      yield Decoration.inline(
        id,
        d.noteStart,
        d.end,
        spec: const HomericMarkSpec(HomericMarkKind.footnote),
      );
    }
  }

  // `^[note]` and `[^id]` markers.
  for (final m in on.footnotes ? scan.inlineFootnotes : const <Never>[]) {
    yield markdownMarkHideReplacement(id, m.start, m.end);
    yield Decoration.widget(
      id,
      m.start,
      spec: HomericFootnoteSpec(homericInlineFootnoteKey(id, m.start)),
    );
  }
  for (final m in on.footnotes ? scan.references : const <Never>[]) {
    yield markdownMarkHideReplacement(id, m.start, m.end);
    yield Decoration.widget(
      id,
      m.start,
      spec: HomericFootnoteSpec(homericFootnoteRefKey(m.group(1)!)),
    );
  }
}

/// `#tags` written inline, recognised as you type with the same rule that
/// files them as the note's tags.
Iterable<Decoration> _tagMarkDecorations(Block block) sync* {
  final text = block.text;
  // A heading's own `#` is followed by a space, so it never matches.
  for (final m in HomericTags.pattern.allMatches(text)) {
    final start = m.end - m.group(1)!.length - 1;
    yield Decoration.inline(
      block.id,
      start,
      m.end,
      spec: const HomericMarkSpec(HomericMarkKind.tag),
    );
  }
}

/// ATX headings, blockquotes, `==highlight==`.
Iterable<Decoration> _markdownBlockDecorations(Block block) sync* {
  final text = block.text;

  final headingMatch = RegExp(r'^(#{1,6}) ').firstMatch(text);
  if (headingMatch != null) {
    final level = headingMatch.group(1)!.length;
    yield markdownMarkHideReplacement(block.id, 0, headingMatch.end);
    if (headingMatch.end < text.length) {
      yield Decoration.inline(
        block.id,
        headingMatch.end,
        text.length,
        spec: HomericMarkSpec(HomericMarkKind.heading, headingLevel: level),
      );
    }
  }

  // `> ` lines: each line of a soft-broken quote carries its own marker.
  for (final line in homericLines(text)) {
    final quote = HomericSyntax.quoteLine.firstMatch(line.text);
    if (quote == null) continue;
    final bodyStart = line.start + quote.end;
    final end = line.start + line.text.length;
    yield markdownMarkHideReplacement(block.id, line.start, bodyStart);
    if (bodyStart < end) {
      yield Decoration.inline(
        block.id,
        bodyStart,
        end,
        spec: const HomericMarkSpec(HomericMarkKind.quote),
      );
    }
  }

  for (final m in RegExp(r'==(.+?)==').allMatches(text)) {
    yield markdownMarkHideReplacement(block.id, m.start, m.start + 2);
    yield markdownMarkHideReplacement(block.id, m.end - 2, m.end);
    yield Decoration.inline(
      block.id,
      m.start + 2,
      m.end - 2,
      spec: const HomericMarkSpec(HomericMarkKind.highlight),
    );
  }
}

Iterable<Decoration> _attributeMarkDecorations(Block block) sync* {
  var offset = 0;
  for (final run in block.runs) {
    final start = offset;
    final end = offset + run.length;
    offset = end;
    if (run.length == 0) continue;
    final attrs = run.attributes;
    if (attrs['bold'] == true) {
      yield Decoration.inline(
        block.id,
        start,
        end,
        spec: const HomericMarkSpec(HomericMarkKind.bold),
      );
    }
    if (attrs['italic'] == true) {
      yield Decoration.inline(
        block.id,
        start,
        end,
        spec: const HomericMarkSpec(HomericMarkKind.italic),
      );
    }
    if (attrs['code'] == true) {
      yield Decoration.inline(
        block.id,
        start,
        end,
        spec: const HomericMarkSpec(HomericMarkKind.code),
      );
    }
    if (attrs['aside'] == true) {
      yield Decoration.inline(
        block.id,
        start,
        end,
        spec: const HomericMarkSpec(HomericMarkKind.comment),
      );
    }
    if (attrs['annotation'] == true) {
      yield Decoration.inline(
        block.id,
        start,
        end,
        spec: const HomericMarkSpec(HomericMarkKind.annotation),
      );
    }
    final href = attrs['href'] ?? attrs['link'];
    if (href is String && href.isNotEmpty) {
      yield Decoration.inline(
        block.id,
        start,
        end,
        spec: HomericMarkSpec(HomericMarkKind.link, href: href),
      );
    }
  }
}

/// `**bold**`, `*italic*`, `` `code` `` — hide delimiters + style content.
Iterable<Decoration> _markdownMarkDecorations(Block block) sync* {
  final text = block.text;
  // Bold **...**
  for (final m in RegExp(r'\*\*(.+?)\*\*').allMatches(text)) {
    yield markdownMarkHideReplacement(block.id, m.start, m.start + 2);
    yield markdownMarkHideReplacement(block.id, m.end - 2, m.end);
    yield Decoration.inline(
      block.id,
      m.start + 2,
      m.end - 2,
      spec: const HomericMarkSpec(HomericMarkKind.bold),
    );
  }
  // Italic *...* (not part of **)
  for (final m in RegExp(
    r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)',
  ).allMatches(text)) {
    yield markdownMarkHideReplacement(block.id, m.start, m.start + 1);
    yield markdownMarkHideReplacement(block.id, m.end - 1, m.end);
    yield Decoration.inline(
      block.id,
      m.start + 1,
      m.end - 1,
      spec: const HomericMarkSpec(HomericMarkKind.italic),
    );
  }
  // Code `...`
  for (final m in RegExp(r'`([^`]+)`').allMatches(text)) {
    yield markdownMarkHideReplacement(block.id, m.start, m.start + 1);
    yield markdownMarkHideReplacement(block.id, m.end - 1, m.end);
    yield Decoration.inline(
      block.id,
      m.start + 1,
      m.end - 1,
      spec: const HomericMarkSpec(HomericMarkKind.code),
    );
  }
}

Iterable<Decoration> _listMarkDecorations(
  Block block, {
  required bool glyphs,
  HomericListHang? hang,
  int? caret,
}) sync* {
  if (hang != null) {
    // The marker is drawn in the gutter beside the line.
    yield hang.hide;
    return;
  }
  final match = HomericMarkdownListPrefix.match(block.text);
  if (match == null) return;
  // Hung lines: a marker holding the caret shows exactly as typed.
  if (caret != null && caret < match.prefixEnd) return;
  final mark = glyphs ? _listGlyph(block.text, match) : match.visibleMark;
  // The marker shows as a bullet or number; the space after it stays.
  yield Decoration.replace(
    block.id,
    match.markerStart,
    match.markerEnd,
    replacementLength: mark.length,
    spec: _ListMarkSpec(mark),
  );
}

/// The marker of a list line nested [HomericMarkdownListMatch.indentLength]
/// deep: a tab or two spaces per level.
String _listGlyph(String text, HomericMarkdownListMatch match) {
  final depth = HomericListHang.depthOf(text.substring(0, match.indentLength));
  return switch (match.kind) {
    HomericMarkdownListKind.bullet => HomericListGlyphs.bullet(depth),
    HomericMarkdownListKind.ordered =>
      '${HomericListGlyphs.number(int.tryParse(match.orderedDigits) ?? 1, depth)}.',
  };
}

class _ListMarkSpec implements ReplacementContent {
  const _ListMarkSpec(this.mark);
  final String mark;
  @override
  String get text => mark;
}

Iterable<Decoration> _linkMarkDecorations(Block block) sync* {
  for (final m in HomericMarkdownLink.allMatches(block.text)) {
    // Hide `[` `](url)` chrome; style label as link.
    yield markdownMarkHideReplacement(block.id, m.start, m.start + 1);
    yield markdownMarkHideReplacement(block.id, m.labelEnd, m.end);
    yield Decoration.inline(
      block.id,
      m.start + 1,
      m.labelEnd,
      spec: HomericMarkSpec(HomericMarkKind.link, href: m.url),
    );
  }
}

/// Widget-slot payload for a to-do line's box: where its marker sits in
/// the block, so the host can tick it, and whether it is ticked.
class HomericChecklistSpec {
  const HomericChecklistSpec({
    required this.blockId,
    required this.markerStart,
    required this.markerEnd,
    required this.done,
  });
  final String blockId;

  /// The marker (`[ ]`, `- [x]`, `☐`), without the space after it.
  final int markerStart;
  final int markerEnd;
  final bool done;

  @override
  bool operator ==(Object other) =>
      other is HomericChecklistSpec &&
      other.blockId == blockId &&
      other.markerStart == markerStart &&
      other.markerEnd == markerEnd &&
      other.done == done;

  @override
  int get hashCode => Object.hash(blockId, markerStart, markerEnd, done);
}

/// `[ ] task` / `- [x] done` / `☐ task` lines: the marker becomes a box
/// that ticks on click, and a done line reads struck through. With the
/// caret on the marker it shows as typed, so it can be edited.
Iterable<Decoration> _checklistDecorations(Block block, {int? caret}) sync* {
  final text = block.text;
  var lineStart = 0;
  for (final line in text.split('\n')) {
    final m = HomericChecklists.line.firstMatch(line);
    if (m != null) {
      final body = m.group(3) ?? '';
      final bodyStart = lineStart + line.length - body.length;
      final markerStart = lineStart + line.length - line.trimLeft().length;
      final markerEnd = text.lastIndexOf(RegExp(r'\S'), bodyStart - 1) + 1;
      final editing = caret != null && caret >= lineStart && caret < bodyStart;
      final done = HomericChecklists.isDone(line, m);
      if (!editing && markerEnd > markerStart) {
        // The box opens the hidden marker rather than following it: the
        // two fold into one span, so the caret at the start of the words
        // draws after the box, where typed text goes. A slot right after
        // a hidden span would catch that caret on its near side.
        yield Decoration.widget(
          block.id,
          markerStart,
          spec: HomericChecklistSpec(
            blockId: block.id,
            markerStart: markerStart,
            markerEnd: markerEnd,
            done: done,
          ),
        );
        yield markdownMarkHideReplacement(block.id, markerStart, bodyStart);
      }
      if (done && body.isNotEmpty) {
        yield Decoration.inline(
          block.id,
          bodyStart,
          bodyStart + body.length,
          spec: const HomericMarkSpec(HomericMarkKind.strike),
        );
      }
    }
    lineStart += line.length + 1;
  }
}

/// Widget-slot payload for a `[[note link]]`: the host paints a preview
/// card of the linked note in `slotBuilder`.
class HomericWikiLinkSpec {
  const HomericWikiLinkSpec(this.target, {this.label});
  final String target;
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is HomericWikiLinkSpec &&
      other.target == target &&
      other.label == label;

  @override
  int get hashCode => Object.hash(target, label);
}

/// `[[Note]]` / `[[Note|label]]` — hide the source, show a slot for the
/// host's link.
Iterable<Decoration> _wikiLinkMarkDecorations(Block block, {int? caret}) sync* {
  final text = block.text;
  for (final m in HomericWikiLinks.allMatches(text)) {
    final hasLabel = m.labelStart != m.start + 2;
    // Right after it counts too, so the caret can step back into it.
    if (caret != null && caret > m.start && caret <= m.end) {
      // Being edited: the source shows, the target quieter than the words.
      if (hasLabel) {
        yield Decoration.inline(
          block.id,
          m.start + 2,
          m.labelStart,
          spec: const HomericMarkSpec(HomericMarkKind.comment),
        );
      }
      yield Decoration.inline(
        block.id,
        m.labelStart,
        m.labelEnd,
        spec: const HomericMarkSpec(HomericMarkKind.link),
      );
      continue;
    }
    yield markdownMarkHideReplacement(block.id, m.start, m.labelStart);
    yield markdownMarkHideReplacement(block.id, m.labelStart, m.labelEnd);
    yield markdownMarkHideReplacement(block.id, m.labelEnd, m.end);
    yield Decoration.widget(
      block.id,
      m.labelStart,
      spec: HomericWikiLinkSpec(
        m.target,
        label: hasLabel ? text.substring(m.labelStart, m.labelEnd) : null,
      ),
    );
  }
}
