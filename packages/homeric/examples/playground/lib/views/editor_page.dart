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
  HomericPastePolicy _pastePolicy = HomericPastePolicy.expandBlocks;
  bool _attributeStyles = false;
  double _blockGrabberWidth = kHomericBlockGrabberWidth;
  bool _markdownShortcuts = false;
  VoidCallback? _uninstallMarkdownShortcuts;
  bool _compact = false;
  final GlobalKey<HomericEditableDocumentState> _ownDocumentKey =
      GlobalKey<HomericEditableDocumentState>();

  GlobalKey<HomericEditableDocumentState> get _documentKey =>
      widget.documentKey ?? _ownDocumentKey;

  @override
  void dispose() {
    _uninstallMarkdownShortcuts?.call();
    super.dispose();
  }

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
          _HostBatchBar(
            pastePolicy: _pastePolicy,
            onPastePolicyChanged: (value) =>
                setState(() => _pastePolicy = value),
            onDemoMultiPaste: _demoMultiParagraphPaste,
            attributeStyles: _attributeStyles,
            onAttributeStylesChanged: (value) =>
                setState(() => _attributeStyles = value),
            onDemoAttributeStyles: _demoAttributeStyles,
            blockGrabberWidth: _blockGrabberWidth,
            onBlockGrabberWidthChanged: (value) =>
                setState(() => _blockGrabberWidth = value),
            markdownShortcuts: _markdownShortcuts,
            onMarkdownShortcutsChanged: _setMarkdownShortcuts,
            compact: _compact,
            onCompactChanged: (value) => setState(() {
              _compact = value;
              if (value) _blockGrabberWidth = 0;
            }),
          ),
          const Divider(height: 1),
          Expanded(
            child: _MarginDemo(
              enabled: widget.marginDemo,
              documentKey: _documentKey,
              viewModel: widget.viewModel,
              editor: _compact
                  ? HomericEditableDocument.compact(
                      key: _documentKey,
                      controller: widget.viewModel.editorController,
                      inputSession: widget.viewModel.inputSession,
                      scrollController: widget.scrollController,
                      cacheExtent: widget.cacheExtent,
                      layoutRevision: (
                        _darkText,
                        _fontSize,
                        _pastePolicy,
                        _attributeStyles,
                        _blockGrabberWidth,
                        _compact,
                      ),
                      touchSelectionConfiguration:
                          const HomericTouchSelectionConfiguration.adaptive(),
                      blockBuilder: (context, block, focusNode) => Padding(
                        padding: kHomericCompactParagraphInsets,
                        child: _BlockView(
                          key: ValueKey(block.id),
                          viewModel: widget.viewModel,
                          block: block,
                          focusNode: focusNode,
                          baseStyle: _baseStyle,
                          pastePolicy: _pastePolicy,
                          attributeStyles: _attributeStyles,
                        ),
                      ),
                    )
                  : HomericEditableDocument.builder(
                      key: _documentKey,
                      controller: widget.viewModel.editorController,
                      inputSession: widget.viewModel.inputSession,
                      scrollController: widget.scrollController,
                      padding: const EdgeInsets.all(16),
                      cacheExtent: widget.cacheExtent,
                      estimatedBlockHeight: 54,
                      blockGrabberWidth: _blockGrabberWidth,
                      layoutRevision: (
                        _darkText,
                        _fontSize,
                        _pastePolicy,
                        _attributeStyles,
                        _blockGrabberWidth,
                        _compact,
                      ),
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
                          pastePolicy: _pastePolicy,
                          attributeStyles: _attributeStyles,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _demoMultiParagraphPaste() {
    final controller = widget.viewModel.editorController;
    final document = controller.document;
    if (document.isEmpty) return;
    final first = document.blocks.first;
    final caret = document.positionAt(0, first.contentLength);
    controller.setSelection(HomericSelection.collapsed(caret));
    controller.replaceSelectionStructurally(
      'First pasted paragraph\nSecond pasted paragraph\nThird pasted paragraph',
    );
  }

  void _setMarkdownShortcuts(bool enabled) {
    _uninstallMarkdownShortcuts?.call();
    _uninstallMarkdownShortcuts = null;
    if (enabled) {
      _uninstallMarkdownShortcuts = const HomericMarkdownShortcutPolicy()
          .installOn(widget.viewModel.editorController);
      // Shortcuts write run attributes — paint them with the stock sheet.
      _attributeStyles = true;
    }
    setState(() => _markdownShortcuts = enabled);
  }

  void _demoAttributeStyles() {
    setState(() => _attributeStyles = true);
    final controller = widget.viewModel.editorController;
    final demo = Block(
      id: 'attr-demo',
      type: 'paragraph',
      runs: [
        InlineRun('Stock styles: '),
        InlineRun('bold', attributes: const <String, Object?>{'bold': true}),
        InlineRun(', '),
        InlineRun('italic',
            attributes: const <String, Object?>{'italic': true}),
        InlineRun(', and '),
        InlineRun('code', attributes: const <String, Object?>{'code': true}),
        InlineRun('.'),
      ],
    );
    final tx = Transaction(controller.document);
    tx.step(ReplaceStep(
      controller.document.size,
      controller.document.size,
      Slice(<Block>[demo]),
    ));
    controller.applyTransaction(tx);
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

/// Host-facing batch demos (paste policy and later opt-ins).
class _HostBatchBar extends StatelessWidget {
  const _HostBatchBar({
    required this.pastePolicy,
    required this.onPastePolicyChanged,
    required this.onDemoMultiPaste,
    required this.attributeStyles,
    required this.onAttributeStylesChanged,
    required this.onDemoAttributeStyles,
    required this.blockGrabberWidth,
    required this.onBlockGrabberWidthChanged,
    required this.markdownShortcuts,
    required this.onMarkdownShortcutsChanged,
    required this.compact,
    required this.onCompactChanged,
  });

  final HomericPastePolicy pastePolicy;
  final ValueChanged<HomericPastePolicy> onPastePolicyChanged;
  final VoidCallback onDemoMultiPaste;
  final bool attributeStyles;
  final ValueChanged<bool> onAttributeStylesChanged;
  final VoidCallback onDemoAttributeStyles;
  final double blockGrabberWidth;
  final ValueChanged<double> onBlockGrabberWidthChanged;
  final bool markdownShortcuts;
  final ValueChanged<bool> onMarkdownShortcutsChanged;
  final bool compact;
  final ValueChanged<bool> onCompactChanged;

  @override
  Widget build(BuildContext context) {
    final expand = pastePolicy == HomericPastePolicy.expandBlocks;
    final grabberVisible = blockGrabberWidth > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 4,
        children: [
          const Text('Host batch:'),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Expand multi-paste'),
              Switch(
                value: expand,
                onChanged: (value) => onPastePolicyChanged(
                  value
                      ? HomericPastePolicy.expandBlocks
                      : HomericPastePolicy.singleBlock,
                ),
              ),
            ],
          ),
          TextButton(
            onPressed: onDemoMultiPaste,
            child: const Text('Demo multi-paragraph paste'),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Attribute styles'),
              Switch(
                value: attributeStyles,
                onChanged: onAttributeStylesChanged,
              ),
            ],
          ),
          TextButton(
            onPressed: onDemoAttributeStyles,
            child: const Text('Demo bold/italic/code'),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(grabberVisible ? 'Grabber 44' : 'Grabber collapsed'),
              Switch(
                value: grabberVisible,
                onChanged: (value) => onBlockGrabberWidthChanged(
                  value ? kHomericBlockGrabberWidth : 0,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Markdown shortcuts'),
              Switch(
                value: markdownShortcuts,
                onChanged: onMarkdownShortcutsChanged,
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Compact preset'),
              Switch(
                value: compact,
                onChanged: onCompactChanged,
              ),
            ],
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
    required this.pastePolicy,
    required this.attributeStyles,
  });

  final DocumentViewModel viewModel;
  final Block block;
  final FocusNode focusNode;
  final TextStyle baseStyle;
  final HomericPastePolicy pastePolicy;
  final bool attributeStyles;

  static const _attributeSheet = HomericAttributeStyleSheet.standard;

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
      resolveStyle: (run) {
        final styled = _resolveRunStyle(run, baseStyle);
        return attributeStyles
            ? _attributeSheet.resolveStyle(run, base: styled)
            : styled;
      },
      deriveDecorations: attributeStyles
          ? (liveBlock) => _attributeSheet.decorationsFor(liveBlock)
          : null,
      paintLayers: layers,
      slotBuilder: (slot) => _ChipWidget(slot: slot),
      caretColor: Colors.blueAccent,
      selectionColor: const Color(0x554F64C8),
      inactiveSelectionColor: const Color(0x224F64C8),
      composingColor: const Color(0xFF7E57C2),
      spellCheckProvider: const _PlaygroundSpellCheckProvider(),
      pastePolicy: pastePolicy,
      onHostEvent: (event) => _showHostEvent(context, event, pastePolicy),
    );
  }
}

void _showHostEvent(
  BuildContext context,
  HomericHostEvent event,
  HomericPastePolicy pastePolicy,
) {
  final message = switch (event) {
    HomericPasteRejected() => pastePolicy == HomericPastePolicy.singleBlock
        ? 'Paste rejected: single-block policy (multi-paragraph paste disabled).'
        : 'Paste rejected by the editor.',
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
