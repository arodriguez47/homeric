/// Small, hand-built demo content (R8: "small/medium only, no
/// virtualization"). A single short [Document] with a few blocks stands in
/// for the plan's "2-3 small fixture documents" — one coherent document
/// covering the decoration shapes the playground exercises (bold + hidden
/// annotation markers, a heading, and a plain paragraph for split/join/move
/// demos) is simpler to drive from one [DocumentViewModel] than juggling
/// several independent documents, and every scenario the plan calls out is
/// still reachable.
library;

import 'package:homeric/homeric.dart';

import 'decoration_spec.dart';

/// The playground's starting document.
Document buildFixtureDocument() {
  return Document([
    Block(id: 'heading', type: 'heading', runs: [
      InlineRun('Homeric Playgrond'),
    ]),
    Block(id: 'intro', type: 'paragraph', runs: [
      InlineRun('This paragraph has **bold** text and a %%hidden%% '
          'annotation. Tap to place the caret, then drive edits from the '
          'panel on the right.'),
    ]),
    Block(id: 'notes', type: 'paragraph', runs: [
      InlineRun('A short second paragraph for split, join, and move demos.'),
    ]),
  ]);
}

/// A deterministic long-form mobile fixture for touch and recycle testing.
///
/// It retains the debug panel's stable base IDs, then adds wrapping, Unicode,
/// an empty paragraph, and enough rows to force the real lazy viewport to
/// recycle children during device testing.
Document buildTouchFixtureDocument() {
  final base = buildFixtureDocument();
  return Document(<Block>[
    ...base.blocks,
    Block(
      id: 'touch-unicode',
      type: 'paragraph',
      runs: <InlineRun>[
        InlineRun(
          'Touch geometry: English مرحبا שלום 👨‍👩‍👧‍👦 e\u0301 [touch] '
          'wraps across several visual lines without splitting a grapheme.',
        ),
      ],
    ),
    Block(
      id: 'touch-empty',
      type: 'paragraph',
      runs: <InlineRun>[InlineRun('')],
    ),
    for (var index = 0; index < 48; index++)
      Block(
        id: 'touch-row-$index',
        type: 'paragraph',
        runs: <InlineRun>[
          InlineRun(
            'Recycled row ${index + 1}: drag a handle beyond the viewport '
            'edge to exercise bounded autoscroll and stable block identity.',
          ),
        ],
      ),
  ]);
}

/// The decorations backing [buildFixtureDocument]'s baked-in bold/italic
/// styling (the hide-delimiter, wash, underline, and chip decorations are
/// all added live from the decoration panel instead — see
/// `views/decoration_panel.dart`).
DecorationSet buildFixtureDecorations(Document document) {
  final decorations = <Decoration>[];
  final intro = document.blockById('intro');
  if (intro != null) {
    final text = intro.text;
    void styleBetween(String needle, PlaygroundDecorationKind kind) {
      final start = text.indexOf(needle);
      if (start == -1) return;
      decorations.add(Decoration.inline(
        intro.id,
        start,
        start + needle.length,
        spec: PlaygroundSpec(kind),
      ));
    }

    styleBetween('bold', PlaygroundDecorationKind.bold);
    styleBetween('hidden', PlaygroundDecorationKind.italic);
  }
  return DecorationSet.of(decorations);
}

/// Projection fixture paired with [buildTouchFixtureDocument].
///
/// The intro's markers provide folded caret edges, while `[touch]` becomes a
/// widget slot so the same mobile trace covers both projection mechanisms.
DecorationSet buildTouchFixtureDecorations(Document document) {
  final decorations = <Decoration>[
    ...buildFixtureDecorations(document).forBlock('intro'),
  ];
  final intro = document.blockById('intro');
  if (intro != null) decorations.addAll(markerDecorationsFor(intro));
  final unicode = document.blockById('touch-unicode');
  if (unicode != null) {
    final start = unicode.text.indexOf('[touch]');
    if (start >= 0) {
      decorations.add(Decoration.replace(
        unicode.id,
        start,
        start + '[touch]'.length,
        replacementLength: 1,
        spec: const PlaygroundSpec(
          PlaygroundDecorationKind.chip,
          label: 'touch slot',
        ),
      ));
    }
  }
  return DecorationSet.of(decorations);
}
