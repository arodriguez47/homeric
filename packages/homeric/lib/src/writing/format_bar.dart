/// Buttons for the format bar across the top of the desktop selection menu
/// ([HomericEditableDocument.selectionFormatBarBuilder]).
///
/// Each button does what its typed marker or shortcut does, so the menu
/// teaches the syntax: its tooltip names the button, says what it does to
/// the words and shows what typing does the same. A button over words that
/// already carry its marker shows pressed and takes the marker off.
library;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../editing/context_menu.dart' show homericMenuShortcut;
import '../editing/editable_document.dart';
import '../editing/editor_controller.dart';
import '../model/selection.dart';
import 'block_indent.dart';
import 'typed_wraps.dart';
import 'wrap_shortcuts.dart';

/// The standard format bar buttons.
abstract final class HomericFormatBar {
  /// Bold, Italic, Strikethrough, Highlight, Aside and Code, then Link,
  /// Note and Footnote, for [selection] in [controller].
  ///
  /// Link and Note need [wraps] (they do what typing `[[` and `{{` over the
  /// words does, so the host's own link menu or note composer follows);
  /// Footnote needs [onFootnote]. Switch any of the rest off with its flag.
  ///
  /// With [indents], Outdent and Indent end the bar, a group of their own:
  /// they move the whole line ([HomericBlockIndent]), paragraph or list
  /// item, so they work with only a caret. [indentTypes] are the block
  /// types that indent as paragraphs.
  static List<HomericFormatAction> standard(
    HomericEditorController controller,
    HomericSelection selection, {
    HomericTypedWrapsSession? wraps,
    bool highlight = true,
    bool aside = true,
    bool code = true,
    bool link = true,
    bool note = true,
    VoidCallback? onFootnote,
    String? footnoteShortcut,
    bool indents = false,
    Set<String> indentTypes = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? indentFilter,
  }) {
    final words = !selection.isCollapsed;
    HomericFormatAction? typed(
            HomericFormatAction Function() build, String t) =>
        wraps != null && wraps.feature.pairs.containsKey(t) ? build() : null;
    return <HomericFormatAction>[
      HomericFormatBar.bold(controller, selection),
      HomericFormatBar.italic(controller, selection),
      HomericFormatBar.strikethrough(controller, selection),
      if (highlight) HomericFormatBar.highlight(controller, selection),
      if (aside) HomericFormatBar.aside(controller, selection),
      if (code) HomericFormatBar.code(controller, selection),
      ...<HomericFormatAction?>[
        if (link)
          typed(
              () => HomericFormatBar.link(controller, selection, wraps!), '['),
        if (note)
          typed(
              () => HomericFormatBar.note(controller, selection, wraps!), '{'),
      ].whereType<HomericFormatAction>(),
      if (onFootnote != null)
        HomericFormatAction(
          icon: Icons.format_list_numbered_rounded,
          label: 'Footnote',
          description: 'Adds a numbered note after the words, kept at the '
              'foot of the page.',
          syntax: 'words^[note]',
          shortcut: footnoteShortcut,
          onPressed: words ? onFootnote : null,
        ),
      if (indents) ...[
        HomericFormatBar.outdent(
          controller,
          selection,
          types: indentTypes,
          accepts: indentFilter,
        ).copyWith(startsGroup: true),
        HomericFormatBar.indent(
          controller,
          selection,
          types: indentTypes,
          accepts: indentFilter,
        ),
      ],
    ]._groupedAfter(const <String>{'Link', 'Note', 'Footnote'});
  }

  /// Tab: the line one step in, under the line above.
  static HomericFormatAction indent(
    HomericEditorController controller,
    HomericSelection selection, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) =>
      _indent(controller, selection,
          outdent: false, types: types, accepts: accepts);

  /// Shift-Tab: the line one step back toward the margin.
  static HomericFormatAction outdent(
    HomericEditorController controller,
    HomericSelection selection, {
    Set<String> types = HomericBlockIndent.defaultTypes,
    HomericIndentFilter? accepts,
  }) =>
      _indent(controller, selection,
          outdent: true, types: types, accepts: accepts);

  static HomericFormatAction _indent(
    HomericEditorController controller,
    HomericSelection selection, {
    required bool outdent,
    required Set<String> types,
    HomericIndentFilter? accepts,
  }) {
    final possible = HomericBlockIndent.canIndent(
      controller.document,
      selection,
      outdent: outdent,
      types: types,
      accepts: accepts,
    );
    return HomericFormatAction(
      icon: outdent
          ? Icons.format_indent_decrease_rounded
          : Icons.format_indent_increase_rounded,
      label: outdent ? 'Outdent' : 'Indent',
      description: outdent
          ? 'Moves the line a step back toward the margin. Backspace at '
              'the start of its words does the same.'
          : 'Moves the line a step in, under the line above; a list item '
              'nests. A space at the start of its words does the same.',
      shortcut: outdent ? '⇧Tab' : 'Tab',
      actsOnBlock: true,
      onPressed: !possible
          ? null
          : () => HomericBlockIndent.indentSelection(
                controller,
                outdent: outdent,
                types: types,
                accepts: accepts,
              ),
    );
  }

  /// ⌘B: `**words**`.
  static HomericFormatAction bold(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '**',
        icon: Icons.format_bold_rounded,
        label: 'Bold',
        description: 'Gives the words weight, for what must not be missed.',
        shortcut: homericMenuShortcut('B'),
      );

  /// ⌘I: `*words*`.
  static HomericFormatAction italic(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '*',
        icon: Icons.format_italic_rounded,
        label: 'Italic',
        description: 'Leans the words, for stress or a title.',
        shortcut: homericMenuShortcut('I'),
      );

  /// ⇧⌘S: `~~words~~`.
  static HomericFormatAction strikethrough(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '~~',
        icon: Icons.format_strikethrough_rounded,
        label: 'Strikethrough',
        description: 'Crosses the words out and keeps them readable.',
        shortcut: homericMenuShortcut('S', shift: true),
      );

  /// `==words==`.
  static HomericFormatAction highlight(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '==',
        icon: Icons.border_color_outlined,
        label: 'Highlight',
        description: 'Marks the words as a pen would, to find them again.',
      );

  /// `++words++`.
  static HomericFormatAction aside(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '++',
        icon: Icons.short_text_rounded,
        label: 'Aside',
        description: 'Quiets the words into a second voice, said under '
            'your breath.',
      );

  /// ⌘E: `` `words` ``.
  static HomericFormatAction code(
    HomericEditorController controller,
    HomericSelection selection,
  ) =>
      wrap(
        controller,
        selection,
        marker: '`',
        icon: Icons.code_rounded,
        label: 'Code',
        description: 'Sets the words in monospace, exactly as typed.',
        shortcut: homericMenuShortcut('E'),
      );

  /// `[[`, keeping the words as the link's text.
  static HomericFormatAction link(
    HomericEditorController controller,
    HomericSelection selection,
    HomericTypedWrapsSession wraps,
  ) =>
      typedWrap(
        controller,
        selection,
        wraps,
        typed: '[',
        icon: Icons.link_rounded,
        label: 'Link',
        description: 'Links the words to another note; they stay as the '
            "link's text.",
        syntax: '[[note|words]]',
      );

  /// `{{`, a note about the words.
  static HomericFormatAction note(
    HomericEditorController controller,
    HomericSelection selection,
    HomericTypedWrapsSession wraps,
  ) =>
      typedWrap(
        controller,
        selection,
        wraps,
        typed: '{',
        icon: Icons.sticky_note_2_outlined,
        label: 'Note',
        description: 'Pins a note to the words, shown beside them in the '
            'margin.',
        syntax: '{{words|note}}',
      );

  /// A button wrapping the selection in [marker], as
  /// [HomericWrapShortcuts.prepareWrap] does; pressed when it already is.
  static HomericFormatAction wrap(
    HomericEditorController controller,
    HomericSelection selection, {
    required String marker,
    required IconData icon,
    required String label,
    String? description,
    String? syntax,
    String? shortcut,
    bool startsGroup = false,
  }) {
    final command = HomericWrapShortcuts.prepareWrap(
      controller.document,
      selection,
      marker,
    );
    return HomericFormatAction(
      icon: icon,
      label: label,
      description: description,
      syntax: syntax ?? '${marker}words${marker.split('').reversed.join()}',
      shortcut: shortcut,
      startsGroup: startsGroup,
      isActive: HomericWrapShortcuts.isWrapped(
        controller.document,
        selection,
        marker,
      ),
      onPressed: command == null
          ? null
          : () {
              final fresh = HomericWrapShortcuts.prepareWrap(
                controller.document,
                controller.selection ?? selection,
                marker,
              );
              if (fresh != null) controller.applyPreparedCommand(fresh);
            },
    );
  }

  /// A button doing what typing [typed] over the words does
  /// ([HomericTypedWrapsSession.prepareMenuWrap]); pressed when the words
  /// already carry the whole pair.
  static HomericFormatAction typedWrap(
    HomericEditorController controller,
    HomericSelection selection,
    HomericTypedWrapsSession wraps, {
    required String typed,
    required IconData icon,
    required String label,
    String? description,
    String? syntax,
    String? shortcut,
    bool startsGroup = false,
  }) {
    final possible = wraps.canMenuWrap(selection, typed);
    return HomericFormatAction(
      icon: icon,
      label: label,
      description: description,
      syntax: syntax,
      shortcut: shortcut,
      startsGroup: startsGroup,
      isActive: wraps.isWrapped(selection, typed),
      onPressed: !possible
          ? null
          : () {
              final command = wraps.prepareMenuWrap(
                controller.selection ?? selection,
                typed,
              );
              if (command != null) controller.applyPreparedCommand(command);
            },
    );
  }
}

extension on List<HomericFormatAction> {
  /// The same buttons, a rule before the first of [labels].
  List<HomericFormatAction> _groupedAfter(Set<String> labels) {
    var marked = false;
    return <HomericFormatAction>[
      for (final action in this)
        if (!marked && labels.contains(action.label) && (marked = true))
          action.copyWith(startsGroup: true)
        else
          action,
    ];
  }
}
