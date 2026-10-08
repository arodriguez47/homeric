/// Host-facing content size measurement for embedded editor cards.
library;

import 'package:flutter/painting.dart';

import '../model/document.dart';
import 'editor_controller.dart';

/// Measured content extent for a document at a given max width.
final class HomericContentExtent {
  /// Creates an extent of [size] laid out under [maxWidth].
  const HomericContentExtent({
    required this.size,
    required this.maxWidth,
  });

  /// The measured width/height (width ≤ [maxWidth]).
  final Size size;

  /// The width constraint used for the measurement.
  final double maxWidth;

  @override
  String toString() => 'HomericContentExtent($size at maxWidth=$maxWidth)';
}

/// Measures [document] as wrapped plain text under [maxWidth].
///
/// This is a layout-free estimate for embedded card sizing: each block is
/// shaped with [style] via [TextPainter], and [paragraphSpacing] is added
/// between blocks. It does not include grabber chrome, document padding, or
/// decoration-driven view-text substitutions — hosts that need post-layout
/// geometry should read [HomericEditableDocumentState] after mount.
HomericContentExtent measureDocumentContent(
  Document document, {
  required double maxWidth,
  TextStyle style = const TextStyle(fontSize: 16, height: 1.5),
  double paragraphSpacing = 12,
}) {
  assert(maxWidth >= 0);
  assert(paragraphSpacing >= 0);
  if (document.isEmpty) {
    return HomericContentExtent(size: Size.zero, maxWidth: maxWidth);
  }
  var height = 0.0;
  var width = 0.0;
  for (var i = 0; i < document.blockCount; i++) {
    final block = document.blocks[i];
    final painter = TextPainter(
      text: TextSpan(text: block.text.isEmpty ? ' ' : block.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    width = width < painter.width ? painter.width : width;
    height += painter.height;
    if (i + 1 < document.blockCount) height += paragraphSpacing;
    painter.dispose();
  }
  return HomericContentExtent(
    size: Size(width.clamp(0, maxWidth), height),
    maxWidth: maxWidth,
  );
}

/// Controller convenience for [measureDocumentContent].
extension HomericEditorContentMeasure on HomericEditorController {
  /// Measures the current document for an embedded card of [maxWidth].
  HomericContentExtent measureContent({
    required double maxWidth,
    TextStyle style = const TextStyle(fontSize: 16, height: 1.5),
    double paragraphSpacing = 12,
  }) =>
      measureDocumentContent(
        document,
        maxWidth: maxWidth,
        style: style,
        paragraphSpacing: paragraphSpacing,
      );
}
