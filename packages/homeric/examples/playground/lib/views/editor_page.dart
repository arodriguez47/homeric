/// The editor page: a `ListView` of [HomericEditableParagraph] views over the
/// current document (R8), with per-build style resolution from a small
/// in-page theme (R7 — no special plumbing, just calling [resolveStyle]
/// with the current theme each build). Every paragraph is an editing entry
/// point backed by the same controller and epoch-bound input session.
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

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  bool _darkText = false;
  double _fontSize = 18;

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
            child: ListenableBuilder(
              listenable: widget.viewModel,
              builder: (context, _) {
                final document = widget.viewModel.document;
                return ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.all(16),
                  // Flutter 3.24 minimum uses cacheExtent; the replacement
                  // name exists only on newer SDKs.
                  // ignore: deprecated_member_use
                  cacheExtent: widget.cacheExtent,
                  itemCount: document.blockCount,
                  itemBuilder: (context, index) {
                    final block = document.blocks[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _BlockView(
                        key: ValueKey(block.id),
                        viewModel: widget.viewModel,
                        block: block,
                        baseStyle: _baseStyle,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
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
    required this.baseStyle,
  });

  final DocumentViewModel viewModel;
  final Block block;
  final TextStyle baseStyle;

  @override
  Widget build(BuildContext context) {
    final decorations = viewModel.decorations.forBlock(block.id);
    final layers = _paintLayersForBlock(decorations);
    return HomericEditableParagraph(
      controller: viewModel.editorController,
      inputSession: viewModel.inputSession,
      blockId: block.id,
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
