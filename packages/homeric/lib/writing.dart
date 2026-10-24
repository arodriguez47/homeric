/// Optional writing features for Homeric editors.
///
/// Editing behaviour a host switches on per app, built only on the public
/// seams of `package:homeric/homeric.dart`. The core library does not
/// export these types and no core module imports them.
///
/// - Typing rules, installed on a controller by a [HomericWritingKit]:
///   [HomericSmartPunctuation], [HomericWrapShortcuts] (⌘B ⌘I ⌘E ⌘⇧S),
///   [HomericFootnotePunctuation], keyboard-only list nesting
///   [HomericListNesting] and the soft word cap [HomericBrevity].
/// - Typed syntax, folded away in live preview by [HomericSyntax]:
///   markdown, `[[links]]` ([HomericWikiLinks], [HomericLinkQuery]),
///   `#tags` ([HomericTags]), to-dos ([HomericChecklists]), `---`
///   dividers ([HomericDivider]), and the writing layer of asides,
///   comments, annotations, footnotes, strikes, drop caps and images
///   ([HomericMarkScan]).
/// - Presentation: [HomericTypography], [HomericListGlyphs], hanging list
///   lines ([HomericListHang], [HomericListLine]),
///   [HomericWritingWidth] and focus dimming ([HomericFocusDimController]).
library;

export 'src/writing/brevity.dart';
export 'src/writing/checklists.dart';
export 'src/writing/divider.dart';
export 'src/writing/focus_dim.dart';
export 'src/writing/footnote_punctuation.dart';
export 'src/writing/inline_annotation_shortcut.dart';
export 'src/writing/list_glyphs.dart';
export 'src/writing/list_hang.dart';
export 'src/writing/list_nesting.dart';
export 'src/writing/marker_stroke.dart';
export 'src/writing/note_marks.dart';
export 'src/writing/quote_continuation.dart';
export 'src/writing/sentences.dart';
export 'src/writing/smart_punctuation.dart';
export 'src/writing/syntax_decorations.dart';
export 'src/writing/tags.dart';
export 'src/writing/typography.dart';
export 'src/writing/wiki_links.dart';
export 'src/writing/wrap_shortcuts.dart';
export 'src/writing/writing_feature.dart';
export 'src/writing/writing_kit.dart';
export 'src/writing/writing_width.dart';
