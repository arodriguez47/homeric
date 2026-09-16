/// Inline markdown image slot: paint the picture from a URL in the source.
///
/// Given [HomericMarkdownImageSpec] from leave-mode decorations, this widget
/// loads [HomericMarkdownImageSpec.url] with [Image.network]. Homeric does not
/// invent upload, drop, paste, or file storage — the URL must already be in
/// the markdown (`![alt](url)`).
library;

import 'package:flutter/widgets.dart';

import 'markdown_inline.dart';

/// Paints a markdown image from [spec.url] inside a paragraph widget slot.
final class HomericMarkdownImageSlot extends StatelessWidget {
  /// Creates a slot child that paints [spec]'s URL as a picture.
  const HomericMarkdownImageSlot({
    super.key,
    required this.spec,
    this.width = 48,
    this.height = 48,
    this.fit = BoxFit.cover,
  });

  /// Tokenized image payload (url + alt from markdown).
  final HomericMarkdownImageSpec spec;

  /// Slot width passed to [Image.network].
  final double width;

  /// Slot height passed to [Image.network].
  final double height;

  /// How the picture fits the slot.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      spec.url,
      width: width,
      height: height,
      fit: fit,
      semanticLabel: spec.alt.isEmpty ? null : spec.alt,
      errorBuilder: (context, error, stackTrace) => SizedBox(
        width: width,
        height: height,
      ),
    );
  }
}
