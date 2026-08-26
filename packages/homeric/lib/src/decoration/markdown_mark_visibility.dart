/// Markdown delimiter visibility: live preview (hide) vs source-visible (keep).
///
/// Hide-on-space timing stays host-owned — the host emits
/// [markdownMarkHideReplacement] decorations when a mark closes. This module
/// is the library knob for whether those hide replacements fold marks out of
/// view text while inline style decorations still paint.
library;

import 'decoration.dart';

/// Whether markdown delimiter hide replacements fold marks out of view text.
enum MarkdownMarkVisibility {
  /// Delimiter hide replacements fold marks out of view text (Typora /
  /// Obsidian live preview). Reveal-on-selection still applies. Default.
  livePreview,

  /// Delimiter hide replacements are suppressed; marks stay visible while
  /// inline style decorations still paint (iA Writer).
  sourceVisible,
}

/// Canonical [Decoration.spec] for markdown delimiter hide replacements.
///
/// A `replace` with [Decoration.replacementLength] `0` folds its range to
/// nothing; Homeric never reads [Decoration.spec] for that folding. Hosts
/// and [RevealState.forMarkdownMarkVisibility] identify markdown hides by
/// spec identity.
final class MarkdownMarkHideSpec {
  const MarkdownMarkHideSpec._();

  /// Shared spec instance for every markdown delimiter hide replacement.
  static const instance = MarkdownMarkHideSpec._();
}

/// Whether [decoration] is a zero-length markdown delimiter hide replacement.
bool isMarkdownMarkHideDecoration(Decoration decoration) =>
    decoration.kind == DecorationKind.replace &&
    decoration.replacementLength == 0 &&
    identical(decoration.spec, MarkdownMarkHideSpec.instance);

/// A zero-length replace decoration that hides a markdown delimiter span.
Decoration markdownMarkHideReplacement(
  String blockId,
  int start,
  int end,
) =>
    Decoration.replace(
      blockId,
      start,
      end,
      replacementLength: 0,
      spec: MarkdownMarkHideSpec.instance,
    );
