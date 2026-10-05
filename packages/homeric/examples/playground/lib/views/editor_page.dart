/// The editor page: one [HomericEditableDocument] over the current document,
/// with per-build style resolution from a small in-page theme. Every paragraph
/// remains an editing entry point backed by the same controller and
/// epoch-bound input session.
///
/// This is the "view" side of the flutter-architecture MVVM split: no
/// business logic lives here — every widget either reads
/// [DocumentViewModel] state or calls one of its command methods. Mapping
/// [PlaygroundSpec] kinds to concrete [TextStyle]/[PaintLayer] values is
/// presentation, not business logic, so it stays here rather than leaking
/// Flutter/`dart:ui` types into the view-model.
library;

import 'package:flutter/material.dart' hide Decoration;
import 'package:flutter/services.dart' show SuggestionSpan, TextRange;
import 'package:homeric/homeric.dart';
import 'package:homeric/margin.dart';

import '../decoration_spec.dart';
import '../view_models/document_view_model.dart';

/// Renders [viewModel]'s document as a scrolling list of blocks.
class EditorPage extends StatefulWidget {
  /// Creates the editor page over [viewModel].
  const EditorPage({
    super.key,
    required this.viewModel,
    this.cacheExtent = 250,
    this.scrollController,
    this.documentKey,
    this.marginDemo = false,
  });

  /// The document view-model this page renders and edits.
  final DocumentViewModel viewModel;

  /// Logical pixels retained before and after the visible list extent.
  ///
  /// Explicitly pinned so benchmark runs do not inherit a framework-default
  /// change silently.
  final double cacheExtent;

  /// Optional controller used by deterministic benchmark traces.
  final ScrollController? scrollController;

  /// Optional key for benchmark harnesses that must read document state
  /// without walking the reorderable sliver with a test [Finder].
  final GlobalKey<HomericEditableDocumentState>? documentKey;

  /// Whether wide layouts show the margin-notes demo beside the editor.
  final bool marginDemo;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  bool _darkText = false;
  double _fontSize = 18;
  final GlobalKey<HomericEditableDocumentState> _ownDocumentKey =
      GlobalKey<HomericEditableDocumentState>();

  GlobalKey<HomericEditableDocumentState> get _documentKey =>
      widget.documentKey ?? _ownDocumentKey;

  TextStyle get _baseStyle => TextStyle(
        fontSize: _fontSize,
        height: 1.5,
        color: _darkText ? Colors.white : const Color(0xFF1B1B1B),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _darkText ? const Color(0xFF121212) : Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ThemeBar(
            darkText: _darkText,
            fontSize: _fontSize,
            onToggleDark: () => setState(() => _darkText = !_darkText),
            onFontSizeChanged: (value) => setState(() => _fontSize = value),
          ),
          const Divider(height: 1),
          Expanded(
            child: _MarginDemo(
              enabled: widget.marginDemo,
              documentKey: _documentKey,
              viewModel: widget.viewModel,
              editor: HomericEditableDocument.builder(
                key: _documentKey,
                controller: widget.viewModel.editorController,
                inputSession: widget.viewModel.inputSession,
                scrollController: widget.scrollController,
                padding: const EdgeInsets.all(16),
                cacheExtent: widget.cacheExtent,
                estimatedBlockHeight: 54,
                layoutRevision: (_darkText, _fontSize),
                touchSelectionConfiguration:
                    const HomericTouchSelectionConfiguration.adaptive(),
                blockBuilder: (context, block, focusNode) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _BlockView(
                    key: ValueKey(block.id),
                    viewModel: widget.viewModel,
                    block: block,
                    focusNode: focusNode,
                    baseStyle: _baseStyle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Margin-notes demo: a [HomericMarginLayer] beside the editor with sparse,
/// colliding and crowded notes, one note per annotation underline from the
/// decoration panel, expansion on tap, and a composer for the current
/// selection. Notes live only in this widget; it is a consumer of
/// `package:homeric/margin.dart`, not part of the editor.
class _MarginDemo extends StatefulWidget {
  const _MarginDemo({
    required this.enabled,
    required this.documentKey,
    required this.viewModel,
    required this.editor,
  });

  final bool enabled;
  final GlobalKey<HomericEditableDocumentState> documentKey;
  final DocumentViewModel viewModel;
  final Widget editor;

  @override
  State<_MarginDemo> createState() => _MarginDemoState();
}

class _MarginDemoState extends State<_MarginDemo> {
  static const double _gap = 24;
  static const double _noteWidth = 220;
  static const Color _ink = Color(0xFF2F5D9E);

  final List<({String id, String blockId, BlockTextRange range, String text})>
      _notes = [
    // Sparse: one note on the heading's misspelling.
    (
      id: 'typo',
      blockId: 'heading',
      range: const BlockTextRange(8, 17),
      text: 'Spelled this way on purpose: the spell-check demo needs it.',
    ),
    // Colliding: two notes on the first line of one paragraph.
    (
      id: 'bold',
      blockId: 'intro',
      range: const BlockTextRange(19, 27),
      text: 'Markdown markers fold away when delimiters are hidden.',
    ),
    (
      id: 'hidden',
      blockId: 'intro',
      range: const BlockTextRange(39, 49),
      text: 'A second voice, shifted below the first with a connector.',
    ),
    // Crowded: three long notes on a one-line paragraph turn compact.
    for (var index = 0; index < 3; index++)
      (
        id: 'crowd-$index',
        blockId: 'notes',
        range: BlockTextRange(index * 8, index * 8 + 5),
        text: 'Crowded note ${index + 1}. Several notes beside one short '
            'paragraph cannot all fit in full, so the paragraph shows '
            'one-line previews. Tap a preview to read it in full over its '
            'neighbours; Escape or a tap elsewhere closes it again.',
      ),
  ];

  String? _expanded;
  HomericMarginComposer? _composer;
  final TextEditingController _draft = TextEditingController();
  int _created = 0;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_changed);
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_changed);
    _draft.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  HomericMarginNote _note(
      String id, String blockId, BlockTextRange range, String text,
      {bool indicator = false}) {
    const style = TextStyle(
      fontSize: 14,
      height: 1.4,
      fontStyle: FontStyle.italic,
      color: _ink,
    );
    return HomericMarginNote(
      id: id,
      blockId: blockId,
      range: range,
      semanticsLabel: 'Margin note: $text',
      paintSourceIndicator: indicator,
      fullBuilder: (context) => Text(text, style: style),
      compactBuilder: (context) => Text(
        text,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  List<HomericMarginNote> get _allNotes => [
        for (final note in _notes)
          _note(note.id, note.blockId, note.range, note.text,
              indicator:
                  note.id.startsWith('typo') || note.id.startsWith('created')),
        // One note per annotation underline added in the decoration panel;
        // the underline is already the in-document mark.
        for (final decoration in widget.viewModel.decorations.decorations)
          if (decoration.spec
              case PlaygroundSpec(kind: PlaygroundDecorationKind.annotation))
            _note(
              'underline-${decoration.blockId}-${decoration.start}',
              decoration.blockId,
              BlockTextRange(decoration.start, decoration.end),
              'Annotation underline ${decoration.start}–${decoration.end}.',
            ),
      ];

  /// A compact preview expands to its full text; activating it again closes
  /// it. A full note is already readable in place (a host with editable
  /// notes would open it for editing here), so it only closes an open one.
  void _activate(String id, MarginNoteForm form) => setState(() {
        _expanded =
            form == MarginNoteForm.compact && _expanded != id ? id : null;
      });

  void _dismiss() => setState(() {
        _expanded = null;
        _composer = null;
      });

  void _compose() {
    final selection = widget.viewModel.editorController.selection;
    final document = widget.viewModel.editorController.document;
    var blockId = 'intro';
    var range = const BlockTextRange(0, 4);
    if (selection != null) {
      final start = document.resolve(selection.anchor < selection.head
          ? selection.anchor
          : selection.head);
      final end = document.resolve(selection.anchor < selection.head
          ? selection.head
          : selection.anchor);
      if (start is InlinePosition &&
          end is InlinePosition &&
          start.block.id == end.block.id &&
          start.offset < end.offset) {
        blockId = start.block.id;
        range = BlockTextRange(start.offset, end.offset);
      }
    }
    _draft.clear();
    setState(() {
      _expanded = null;
      _composer = HomericMarginComposer(
        blockId: blockId,
        range: range,
        semanticsLabel: 'New margin note',
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _draft,
              autofocus: true,
              maxLines: null,
              style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Write a note…',
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _save(blockId, range),
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      );
    });
  }

  void _save(String blockId, BlockTextRange range) {
    final text = _draft.text.trim();
    setState(() {
      if (text.isNotEmpty) {
        _notes.add((
          id: 'created-${_created++}',
          blockId: blockId,
          range: range,
          text: text,
        ));
      }
      _composer = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.editor;
    return LayoutBuilder(builder: (context, constraints) {
      final editorWidth = constraints.maxWidth - _gap - _noteWidth - 16;
      if (editorWidth < 320) return widget.editor;
      final lineHeight = MediaQuery.textScalerOf(context).scale(14) * 1.4;
      return Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: editorWidth,
            child: widget.editor,
          ),
          // Later child: notes follow block links, which must paint first.
          Positioned.fill(
            child: HomericMarginLayer(
              documentKey: widget.documentKey,
              notes: _allNotes,
              // The editor's 16 px padding ends its text column early.
              marginLeft: editorWidth - 16 + _gap,
              noteWidth: _noteWidth,
              lineHeight: lineHeight,
              expandedNoteId: _expanded,
              composer: _composer,
              onNoteActivated: _activate,
              onDismissed: _dismiss,
              expandedDecoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [
                  BoxShadow(color: Color(0x33000000), blurRadius: 8),
                ],
              ),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: FilledButton.tonal(
              onPressed: _compose,
              child: const Text('Annotate selection'),
            ),
          ),
        ],
      );
    });
  }
}

class _ThemeBar extends StatelessWidget {
  const _ThemeBar({
    required this.darkText,
    required this.fontSize,
    required this.onToggleDark,
    required this.onFontSizeChanged,
  });

  final bool darkText;
  final double fontSize;
  final VoidCallback onToggleDark;
  final ValueChanged<double> onFontSizeChanged;

  @override
  Widget build(BuildContext context) {
    // Proves R7: toggling these changes every visible block's text style
    // on the very next build with no decoration/document plumbing at all
    // — resolveStyle in _BlockView just reads the current baseStyle.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          const Text('Theme (R7 proof):'),
          Switch(value: darkText, onChanged: (_) => onToggleDark()),
          const SizedBox(width: 12),
          const Text('Size'),
          Expanded(
            child: Slider(
              min: 12,
              max: 28,
              value: fontSize,
              onChanged: onFontSizeChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// One block's public editable host with per-block paint derivation.
class _BlockView extends StatelessWidget {
  const _BlockView({
    super.key,
    required this.viewModel,
    required this.block,
    required this.focusNode,
    required this.baseStyle,
  });

  final DocumentViewModel viewModel;
  final Block block;
  final FocusNode focusNode;
  final TextStyle baseStyle;

  @override
  Widget build(BuildContext context) {
    final decorations = viewModel.decorations.forBlock(block.id);
    final layers = _paintLayersForBlock(decorations);
    return HomericEditableParagraph(
      controller: viewModel.editorController,
      inputSession: viewModel.inputSession,
      blockId: block.id,
      focusNode: focusNode,
      baseStyle: baseStyle,
      resolveStyle: (run) => _resolveRunStyle(run, baseStyle),
      paintLayers: layers,
      slotBuilder: (slot) => _ChipWidget(slot: slot),
      caretColor: Colors.blueAccent,
      selectionColor: const Color(0x554F64C8),
      inactiveSelectionColor: const Color(0x224F64C8),
      composingColor: const Color(0xFF7E57C2),
      spellCheckProvider: const _PlaygroundSpellCheckProvider(),
      onHostEvent: (event) => _showHostEvent(context, event),
    );
  }
}

void _showHostEvent(BuildContext context, HomericHostEvent event) {
  final message = switch (event) {
    HomericPasteRejected() => 'Paste supports one paragraph at a time.',
    HomericClipboardFailure(operation: final operation) =>
      '${switch (operation) {
        HomericClipboardOperation.copy => 'Copy',
        HomericClipboardOperation.cut => 'Cut',
        HomericClipboardOperation.paste => 'Paste',
      }} failed.',
  };
  ScaffoldMessenger.of(context)
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

final class _PlaygroundSpellCheckProvider implements HomericSpellCheckProvider {
  const _PlaygroundSpellCheckProvider();

  @override
  Future<List<SuggestionSpan>> check(HomericSpellCheckRequest request) async {
    const misspelling = 'Playgrond';
    final start = request.text.indexOf(misspelling);
    if (start < 0) return const [];
    return [
      SuggestionSpan(
        TextRange(start: start, end: start + misspelling.length),
        const ['Playground'],
      ),
    ];
  }
}

/// Maps [PlaygroundSpec] kinds carried by [run]'s active decorations onto
/// a concrete [TextStyle] — the R7 per-build style resolver.
TextStyle _resolveRunStyle(RunStyleContext run, TextStyle base) {
  var style = base;
  for (final decoration in run.decorations) {
    final spec = decoration.spec;
    if (spec is! PlaygroundSpec) continue;
    switch (spec.kind) {
      case PlaygroundDecorationKind.bold:
        style = style.copyWith(fontWeight: FontWeight.bold);
      case PlaygroundDecorationKind.italic:
        style = style.copyWith(fontStyle: FontStyle.italic);
      case PlaygroundDecorationKind.mentionWash:
      case PlaygroundDecorationKind.annotation:
      case PlaygroundDecorationKind.hideMarker:
      case PlaygroundDecorationKind.chip:
        break;
    }
  }
  return style;
}

/// Builds the U5 paint layers for [decorations]: mention washes as
/// underlays, annotation underlines as overlays.
List<PaintLayer> _paintLayersForBlock(List<Decoration> decorations) {
  final layers = <PaintLayer>[];
  for (final decoration in decorations) {
    final spec = decoration.spec;
    if (spec is! PlaygroundSpec) continue;
    switch (spec.kind) {
      case PlaygroundDecorationKind.mentionWash:
        layers.add(PaintLayer(
          range:
              DocRange(DocOffset(decoration.start), DocOffset(decoration.end)),
          band: PaintBand.underlay,
          painter: solidWashPainter,
          spec: const SolidWashSpec(Color(0x552196F3)),
        ));
      case PlaygroundDecorationKind.annotation:
        layers.add(PaintLayer(
          range:
              DocRange(DocOffset(decoration.start), DocOffset(decoration.end)),
          band: PaintBand.overlay,
          painter: underlinePainter,
          spec: const UnderlineSpec(Color(0xFF8E24AA)),
        ));
      case PlaygroundDecorationKind.bold:
      case PlaygroundDecorationKind.italic:
      case PlaygroundDecorationKind.hideMarker:
      case PlaygroundDecorationKind.chip:
        break;
    }
  }
  return layers;
}

/// The widget rendered for a widget-chip decoration's placeholder slot.
class _ChipWidget extends StatelessWidget {
  const _ChipWidget({required this.slot});

  final SlotSegment<TextStyle> slot;

  @override
  Widget build(BuildContext context) {
    final spec = slot.decoration.spec;
    final label = spec is PlaygroundSpec ? (spec.label ?? '?') : '?';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade100,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 11, color: Colors.deepPurple)),
    );
  }
}
