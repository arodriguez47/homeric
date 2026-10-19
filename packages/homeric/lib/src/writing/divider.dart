/// `---` alone on a line: a divider.
///
/// Homeric recognises the source; how a divider is stored and drawn is the
/// host's (a `---` paragraph drawn as a rule with [HomericDividerSpec], or
/// a divider block of the host's own).
library;

import 'smart_punctuation.dart';
import 'syntax_decorations.dart' show HomericDividerSpec;

/// Recognising dividers.
abstract final class HomericDivider {
  /// The source of a divider.
  static const source = '---';

  /// Whether [text], a whole block, is a divider.
  static bool isLine(String text) => text.trim() == source;

  /// Whether [text] is a line the third typed `-` turns into a divider:
  /// `---` as typed, or `—-` once smart punctuation set the first two as
  /// an em dash.
  static bool isTyped(String text) =>
      text == source || text == '${HomericSmartPunctuation.emDashCharacter}-';
}
