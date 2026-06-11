import 'package:flutter/widgets.dart';
import 'package:homeric/src/core/edit_context.dart';
import 'package:homeric/src/default_editor/super_editor.dart';
import 'package:homeric/src/infrastructure/attribution_layout_bounds.dart';
import 'package:homeric/src/infrastructure/content_layers.dart';

/// A [SuperEditorLayerBuilder] that makes [AttributionBounds] usable by a `SuperEditor`.
///
/// See [AttributionBounds] for the real implementation.
class AttributedTextBoundsOverlay implements SuperEditorLayerBuilder {
  const AttributedTextBoundsOverlay({
    required this.selector,
    required this.builder,
  });

  final AttributionBoundsSelector selector;
  final AttributionBoundsBuilder builder;

  @override
  ContentLayerStatefulWidget build(BuildContext context, SuperEditorContext editContext) {
    return AttributionBounds(
      document: editContext.document,
      layout: editContext.documentLayout,
      selector: selector,
      builder: builder,
    );
  }
}
