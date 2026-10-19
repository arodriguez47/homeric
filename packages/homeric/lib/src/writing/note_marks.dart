/// The writing layer as typed syntax: a second voice beside the prose.
///
/// Inline comments, comment lines, annotations and footnotes, kept as
/// literal source so a host can store and sync plain text. Each form is a
/// piece of typed syntax a host folds away until the caret reaches it (see
/// [HomericSyntaxDecorations]):
///
/// - `++aside++` — an inline comment, muted in place.
/// - `%% line` — a whole line of comment.
/// - `{{passage}}` or `{{passage|note}}` — an annotation: the passage is
///   marked and its note shows on hover or tap.
/// - `^[note]` — an inline footnote; `[^id]` with a `[^id]: note` line is
///   the reference form. Both show as a superscript number, numbered in
///   document order.
/// - `~~struck~~` — strikethrough.
/// - `^^` at the start of a paragraph — a drop cap: its first letter is
///   set large in the title face.
/// - `(img name.png)` or `(img https://…|caption)` — an image, shown in
///   place. Typing a bare `(img)` asks for the picture to put there.
///
/// Nothing here touches the UI until the syntax is written: a note without
/// these marks parses to nothing.
library;

/// The patterns of each form, for hosts that need one on its own. Most
/// hosts read a block through [HomericMarkScan], which settles conflicts
/// between forms.
abstract final class HomericNoteMarks {
  /// `^[note]` — the note sits right where it is referenced.
  static final RegExp inlineFootnote = RegExp(r'\^\[([^\[\]\n]+)\]');

  /// `[^id]` that is not itself a `[^id]:` definition.
  static final RegExp footnoteReference = RegExp(
    r'\[\^([^\[\]\s^]+)\](?!:)',
  );

  /// `[^id]: note` at the start of a line.
  static final RegExp footnoteDefinition = RegExp(
    r'^\[\^([^\[\]\s^]+)\]:[ \t]*(.*)$',
  );

  /// `{{passage}}` or `{{passage|note}}`.
  static final RegExp annotation = RegExp(
    r'\{\{([^{}\n|]*[^{}\n|\s][^{}\n|]*)(?:\|([^{}\n]*))?\}\}',
  );

  /// A line that is all comment: `%%` and what follows.
  static final RegExp commentLine = RegExp(r'^%%[ \t]?');

  /// `++aside++`. The aside starts and ends on a non-space, so
  /// `C++ vs C++` stays prose.
  static final RegExp inlineComment = RegExp(r'\+\+(?=\S)(.+?)(?<=\S)\+\+');

  /// `^^` opening a line, then the initial: a letter or digit with any
  /// combining marks, so an accented or astral letter stays whole. An
  /// opening quotation mark before it (group 1) hangs in the margin; the
  /// letter (group 2) still drops.
  static final RegExp dropCap = RegExp(
    '^\\^\\^($_openingQuotes?)([\\p{L}\\p{N}]\\p{M}*)',
    unicode: true,
  );

  /// `~~struck~~`.
  static final RegExp strike = RegExp(r'~~(?=\S)(.+?)(?<=\S)~~');

  /// `(img src)` or `(img src|caption)`. The source is a file name in the
  /// host's image store or an http(s) URL, so it holds no spaces or
  /// brackets.
  static final RegExp imageMark = RegExp(
    r'\(img[ \t]+([^\s()|]+)(?:[ \t]*\|([^()\n]*))?\)',
  );

  /// A bare `(img)`, the cue to pick an image.
  static const imageCue = '(img)';
}

const _openingQuotes = '["\'“‘«„‚]';

final _opensOnLetter = RegExp(
  '^$_openingQuotes?[\\p{L}\\p{N}]',
  unicode: true,
);

/// What a drop cap command does to a paragraph opening with [text]: true
/// adds `^^`, false removes it, null when there's no initial to raise. The
/// command is there for layouts where `^` is a dead key.
bool? homericDropCapToggle(String text) {
  if (HomericNoteMarks.dropCap.hasMatch(text)) return false;
  if (_opensOnLetter.hasMatch(text)) return true;
  return null;
}

/// Code spans and `[[wiki links]]`: text that is never read as layer
/// syntax.
final RegExp _literalPattern = RegExp(r'`[^`\n]+`|\[\[[^\n]*?\]\]');

typedef _Span = (int, int);

bool _overlaps(RegExpMatch m, Iterable<_Span> spans) =>
    spans.any((s) => m.start < s.$2 && m.end > s.$1);

/// One line of a block, with its offset; soft line breaks keep several
/// lines in one block.
typedef HomericLine = ({int start, String text});

Iterable<HomericLine> homericLines(String text) sync* {
  var start = 0;
  for (final line in text.split('\n')) {
    yield (start: start, text: line);
    start += line.length + 1;
  }
}

/// Every layer form found in one block's text, with the conflicts settled:
/// nothing inside a code span or wiki link counts, a `%%` line holds no
/// footnotes or annotations, and marks inside a folded note (an annotation's
/// note, an inline footnote) are part of that note, not marks of their own.
/// Forms never cross each other.
class HomericMarkScan {
  HomericMarkScan(this.text) {
    final literal = [
      for (final m in _literalPattern.allMatches(text)) (m.start, m.end),
    ];
    final commentSpans = <_Span>[];
    for (final line in homericLines(text)) {
      final c = HomericNoteMarks.commentLine.firstMatch(line.text);
      if (c != null) {
        commentLines.add((
          start: line.start,
          bodyStart: line.start + c.end,
          end: line.start + line.text.length,
        ));
        commentSpans.add((line.start, line.start + line.text.length));
        continue;
      }
      final cap = HomericNoteMarks.dropCap.firstMatch(line.text);
      if (cap != null && line.start == 0) {
        dropCaps.add((start: 0, end: 2, letterEnd: cap.end));
      }
      final d = HomericNoteMarks.footnoteDefinition.firstMatch(line.text);
      if (d != null) {
        definitions.add((
          id: d.group(1)!,
          start: line.start,
          noteStart: line.start + line.text.length - d.group(2)!.length,
          end: line.start + line.text.length,
          note: d.group(2)!.trim(),
        ));
      }
    }
    // An image written inside a footnote's or annotation's note is part
    // of that note's text, not a picture of the paragraph.
    final notes = <_Span>[
      for (final m in HomericNoteMarks.annotation.allMatches(text))
        if (m.group(2) != null && !_overlaps(m, [...literal, ...commentSpans]))
          (m.start + 2 + m.group(1)!.length, m.end),
      for (final m in HomericNoteMarks.inlineFootnote.allMatches(text))
        if (!_overlaps(m, [...literal, ...commentSpans])) (m.start, m.end),
    ];
    for (final m in HomericNoteMarks.imageMark.allMatches(text)) {
      if (!_overlaps(m, [...literal, ...commentSpans, ...notes])) {
        images.add(m);
      }
    }
    final blocked = [
      ...literal,
      ...commentSpans,
      for (final m in images) (m.start, m.end),
    ];
    for (final m in HomericNoteMarks.annotation.allMatches(text)) {
      if (!_overlaps(m, blocked)) annotations.add(m);
    }
    final folded = <_Span>[
      for (final m in annotations)
        if (m.group(2) != null) (m.start + 2 + m.group(1)!.length, m.end),
    ];
    for (final m in HomericNoteMarks.inlineFootnote.allMatches(text)) {
      if (!_overlaps(m, [...blocked, ...folded])) inlineFootnotes.add(m);
    }
    folded.addAll([for (final m in inlineFootnotes) (m.start, m.end)]);
    for (final m in HomericNoteMarks.footnoteReference.allMatches(text)) {
      if (!_overlaps(m, [...blocked, ...folded])) references.add(m);
    }
    final taken = [
      ...literal,
      for (final m in images) (m.start, m.end),
      ...folded,
      for (final m in references) (m.start, m.end),
      // An annotation's braces.
      for (final m in annotations) ...[
        (m.start, m.start + 2),
        (m.end - 2, m.end),
      ],
    ];
    for (final m in HomericNoteMarks.inlineComment.allMatches(text)) {
      if (!_overlaps(m, taken)) asides.add(m);
    }
    taken.addAll([for (final m in asides) (m.start, m.end)]);
    for (final m in HomericNoteMarks.strike.allMatches(text)) {
      if (!_overlaps(m, taken)) strikes.add(m);
    }
    foldedSpans = folded;
  }

  final String text;
  final commentLines = <({int start, int bodyStart, int end})>[];
  final definitions =
      <({String id, int start, int noteStart, int end, String note})>[];
  final annotations = <RegExpMatch>[];
  final inlineFootnotes = <RegExpMatch>[];
  final references = <RegExpMatch>[];
  final asides = <RegExpMatch>[];
  final strikes = <RegExpMatch>[];

  /// The `^^` that opens a paragraph with a drop cap; the initial runs
  /// from its `end` to `letterEnd`.
  final dropCaps = <({int start, int end, int letterEnd})>[];

  /// `(img …)` marks; group 1 is the source, group 2 the caption.
  final images = <RegExpMatch>[];

  /// Text folded into a marker: annotation notes and inline footnotes.
  late final List<(int, int)> foldedSpans;
}

/// Whether [offset] in [text] falls inside a code span, a `[[link]]` or
/// any of the layer's marks (comments, asides, strikes, annotations,
/// footnotes), where typed syntax stays literal.
bool homericInsideMark(String text, int offset) {
  bool within(int start, int end) => offset > start && offset < end;
  for (final m in _literalPattern.allMatches(text)) {
    if (within(m.start, m.end)) return true;
  }
  final scan = HomericMarkScan(text);
  for (final m in [
    ...scan.annotations,
    ...scan.inlineFootnotes,
    ...scan.references,
    ...scan.asides,
    ...scan.strikes,
    ...scan.images,
  ]) {
    if (within(m.start, m.end)) return true;
  }
  // A comment line, or a definition, runs to its line's end.
  for (final line in scan.commentLines) {
    if (offset > line.start && offset <= line.end) return true;
  }
  for (final d in scan.definitions) {
    if (offset > d.start && offset <= d.end) return true;
  }
  return false;
}

/// One footnote in a document: what is shown at its marker.
class HomericFootnote {
  const HomericFootnote({required this.key, required this.number, this.text});

  /// `ref:<id>` for `[^id]`, `inline:<block>:<offset>` for `^[note]`.
  final String key;

  /// 1-based, in document order.
  final int number;

  /// The note, or null for a reference with no definition yet.
  final String? text;
}

/// Footnote key for a `[^id]` reference or `[^id]:` definition.
String homericFootnoteRefKey(String id) => 'ref:${id.toLowerCase()}';

/// Footnote key for an inline `^[note]` at [offset] of [blockId].
String homericInlineFootnoteKey(String blockId, int offset) =>
    'inline:$blockId:$offset';

/// Every footnote in [blocks] (id + text per line), numbered by where its
/// marker first appears. A definition with no reference gets no number.
Map<String, HomericFootnote> homericNumberFootnotes(
  Iterable<({String id, String text})> blocks,
) {
  final definitions = <String, String>{};
  final order = <String>[];
  final inlineText = <String, String>{};
  for (final block in blocks) {
    final scan = HomericMarkScan(block.text);
    for (final d in scan.definitions) {
      definitions.putIfAbsent(homericFootnoteRefKey(d.id), () => d.note);
    }
    // Markers in reading order across both forms.
    final markers = <(int, String)>[];
    for (final m in scan.inlineFootnotes) {
      final key = homericInlineFootnoteKey(block.id, m.start);
      inlineText[key] = m.group(1)!.trim();
      markers.add((m.start, key));
    }
    for (final m in scan.references) {
      markers.add((m.start, homericFootnoteRefKey(m.group(1)!)));
    }
    markers.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, key) in markers) {
      if (!order.contains(key)) order.add(key);
    }
  }
  return {
    for (var i = 0; i < order.length; i++)
      order[i]: HomericFootnote(
        key: order[i],
        number: i + 1,
        text: inlineText[order[i]] ?? definitions[order[i]],
      ),
  };
}

const _superscripts = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];

/// [number] in Unicode superscript digits (`12` → `¹²`), as Histos draws
/// its footnote markers.
String homericSuperscriptNumber(int number) =>
    number.toString().split('').map((d) => _superscripts[int.parse(d)]).join();

/// [body] as a reader sees it with the layer folded away: comment lines,
/// inline comments, images, footnotes and their definitions removed, annotations
/// reduced to their passage, struck text kept without its tildes.
///
/// For previews, exports and titles, where there is no caret to reveal the
/// layer.
String homericStripMarks(String body) => _stripMarks(body, blockStart: true);

/// [blockStart] says whether [body]'s first line opens a block, the only
/// place a `^^` drop cap counts; blocks are split by a blank line, so a
/// soft-wrapped line or an annotation's passage keeps its `^^` as text.
String _stripMarks(String body, {required bool blockStart}) {
  final lines = <String>[];
  var opensBlock = blockStart;
  for (final line in body.split('\n')) {
    final scan = HomericMarkScan(line);
    final atBlockStart = opensBlock;
    opensBlock = line.trim().isEmpty;
    if (scan.commentLines.isNotEmpty || scan.definitions.isNotEmpty) continue;
    // Edits as (start, end, replacement), applied back to front.
    final edits = <(int, int, String)>[
      for (final m in scan.inlineFootnotes) (m.start, m.end, ''),
      for (final m in scan.references) (m.start, m.end, ''),
      for (final m in scan.asides) (m.start, m.end, ''),
      // A passage can hold its own marks (`{{a ++b++}}`); strip those too.
      for (final m in scan.annotations)
        (
          m.start,
          m.end,
          _stripMarks(m.group(1)!, blockStart: false).trim(),
        ),
      for (final m in scan.strikes) (m.start, m.end, m.group(1)!),
      for (final m in scan.images) (m.start, m.end, ''),
      if (atBlockStart)
        for (final c in scan.dropCaps) (c.start, c.end, ''),
    ];
    // An edit inside another (a mark inside an annotation's passage) is
    // covered by the outer one, which already strips its text.
    edits.removeWhere(
      (e) => edits.any(
        (o) => !identical(o, e) && o.$1 <= e.$1 && o.$2 >= e.$2 && o != e,
      ),
    );
    edits.sort((a, b) => b.$1.compareTo(a.$1));
    if (edits.isEmpty) {
      lines.add(line);
      continue;
    }
    var out = line;
    for (final (start, end, replacement) in edits) {
      // An aside between two spaces leaves one.
      var cut = end;
      if (replacement.isEmpty &&
          start > 0 &&
          out[start - 1] == ' ' &&
          cut < out.length &&
          out[cut] == ' ') {
        cut++;
      }
      out = out.replaceRange(start, cut, replacement);
    }
    lines.add(out);
  }
  return lines.join('\n');
}

/// Every image in [body], in order: `(img src|caption)` outside code,
/// links and comment lines.
List<({String src, String? caption})> homericImages(String body) => [
      for (final m in HomericMarkScan(body).images)
        (src: m.group(1)!, caption: _caption(m.group(2))),
    ];

String? _caption(String? raw) {
  final c = raw?.trim();
  return c == null || c.isEmpty ? null : c;
}

/// Whether [src] is fetched from the web rather than the image store.
bool homericIsRemoteImageSource(String src) =>
    src.startsWith('https://') || src.startsWith('http://');
