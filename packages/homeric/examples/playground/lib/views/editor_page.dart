/// The editor page: a `ListView` of [HomericParagraph] views over the
/// current document (R8), with per-build style resolution from a small
/// in-page theme (R7 — no special plumbing, just calling [resolveStyle]
/// with the current theme each build) and a tap-to-place caret display
/// driven by [ParagraphGeometry] (U4).
///
/// This is the "view" side of the flutter-architecture MVVM split: no
/// business logic lives here — every widget either reads
/// [DocumentViewModel] state or calls one of its command methods. Mapping
/// [PlaygroundSpec] kinds to concrete [TextStyle]/[PaintLayer] values is
/// presentation, not business logic, so it stays here rather than leaking
/// Flutter/`dart:ui` types into the view-model.
library;

import 'package:flutter/material.dart' hide Decoration;
import 'package:homeric/homeric.dart';

import '../decoration_spec.dart';
import '../view_models/document_view_model.dart';

/// The key the caret's exact-geometry indicator carries — read by
/// `test/document_view_model_test.dart` to cross-check
/// [ParagraphGeometry.caretRect] end to end against what tapping actually
/// produces on screen.
const Key caretIndicatorKey = ValueKey('caret-indicator');

/// Renders [viewModel]'s document as a scrolling list of blocks.
class EditorPage extends StatefulWidget {
  /// Creates the editor page over [viewModel].
  const EditorPage({super.key, required this.viewModel});

  /// The document view-model this page renders and edits.
  final DocumentViewModel viewModel;

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
                  padding: const EdgeInsets.all(16),
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

/// One block's paragraph, with tap-to-place caret and per-block decoration
/// derivation.
class _BlockView extends StatefulWidget {
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
  State<_BlockView> createState() => _BlockViewState();
}

class _BlockViewState extends State<_BlockView> {
  // Delivered by onGeometryChanged after every layout — which is why this
  // widget needs no GlobalKey. The callback arrives before anything can
  // ask for geometry, and again whenever geometry changes, so a held
  // reference is always one a fresh ParagraphGeometry can be built from.
  RenderHomericParagraph? _paragraph;

  @override
  Widget build(BuildContext context) {
    final decorations = widget.viewModel.decorations.forBlock(widget.block.id);
    final reveal = widget.viewModel.revealStateForBlock(widget.block.id);
    final source = ParagraphSource.build(
      block: widget.block,
      decorations: decorations,
      reveal: reveal,
      resolveStyle: (run) => _resolveRunStyle(run, widget.baseStyle),
    );
    final layers = _paintLayersForBlock(decorations);
    final localCaret = _caretLocalOffset();
    final paragraph = _paragraph;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _handleTap,
      child: Stack(
        children: [
          HomericParagraph(
            source: source,
            baseStyle: widget.baseStyle,
            paintLayers: layers,
            slotBuilder: (slot) => _ChipWidget(slot: slot),
            onGeometryChanged: _handleGeometryChanged,
          ),
          if (localCaret != null && paragraph != null)
            ..._buildCaretOverlay(
                paragraph: paragraph, localOffset: localCaret),
        ],
      ),
    );
  }

  /// Re-places the caret overlay whenever the paragraph relayouts — a
  /// window resize, a base-style change, an edit. The first call is what
  /// mounts the overlay at all: on the first build there is no geometry to
  /// position against yet.
  void _handleGeometryChanged(RenderHomericParagraph paragraph, int _) {
    if (!mounted) {
      return;
    }
    setState(() => _paragraph = paragraph);
  }

  int? _caretLocalOffset() {
    final caret = widget.viewModel.caret;
    if (caret == null) return null;
    final resolved = widget.viewModel.document.resolve(caret);
    if (resolved is! InlinePosition || resolved.block.id != widget.block.id) {
      return null;
    }
    return resolved.offset;
  }

  void _handleTap(TapUpDetails details) {
    final renderObject = _paragraph;
    if (renderObject == null) return;
    final local = renderObject.globalToLocal(details.globalPosition);
    final docOffset =
        ParagraphGeometry(renderObject).positionForPoint(local).value;
    final document = widget.viewModel.document;
    final index = document.indexOfBlockId(widget.block.id);
    if (index == null) return;
    widget.viewModel.placeCaretAt(document.positionAt(index, docOffset.value));
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

/// Computes the caret's local rect via [ParagraphGeometry] against
/// [paragraph] and returns the [Positioned] overlays for it: an
/// exact-geometry probe (tagged [caretIndicatorKey], zero-width, matched
/// bit-for-bit by the widget test) plus a 2px visual stroke for the
/// running app.
///
/// [paragraph] comes from [HomericParagraph.onGeometryChanged], so it is
/// laid out and current by construction — no `debugNeedsLayout` guard, and
/// no argument about frame ordering. The [ParagraphGeometry] is built
/// fresh here rather than held: that is the supported pattern, and the
/// reason the callback hands back the render object.
List<Widget> _buildCaretOverlay({
  required RenderHomericParagraph paragraph,
  required int localOffset,
}) {
  final Rect rect;
  try {
    rect = ParagraphGeometry(paragraph).caretRect(DocOffset(localOffset)).value;
  } on DocOffsetOutOfRangeError {
    // A caret offset past the end of this block — a different failure
    // from stale geometry, and still possible.
    return const <Widget>[];
  }
  return <Widget>[
    Positioned.fromRect(
      rect: rect,
      child: const IgnorePointer(
        child: ColoredBox(key: caretIndicatorKey, color: Colors.transparent),
      ),
    ),
    Positioned(
      left: rect.left - 1,
      top: rect.top,
      width: 2,
      height: rect.height == 0 ? 16 : rect.height,
      child: const IgnorePointer(child: ColoredBox(color: Colors.blueAccent)),
    ),
  ];
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
