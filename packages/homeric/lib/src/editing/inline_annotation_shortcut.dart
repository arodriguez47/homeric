/// Opt-in `{{text}}` typing shortcut that asks the host to annotate a range.
///
/// Typing the closing `}}` of `{{some words}}` removes both brace pairs,
/// keeps `some words` in place, and reports that range to [onAnnotate].
/// `{{some words|a note}}` also takes `|a note` out of the text and hands it
/// over as [HomericInlineAnnotationRequest.note], so the writer can say what
/// the note is without leaving the line. What
/// an annotation *is* (a margin note, a comment, a popover) stays the host's
/// decision, per the no-presentation-in-the-core rule: Homeric only spots the
/// gesture and hands over the anchored range.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../model/position.dart';
import 'editor_controller.dart';

/// The range a writer marked with `{{…}}`, after the braces were removed.
@immutable
final class HomericInlineAnnotationRequest {
  /// Creates a request for `[start, end)` in block [blockId].
  const HomericInlineAnnotationRequest({
    required this.blockId,
    required this.start,
    required this.end,
    required this.text,
    this.note,
  });

  /// Stable ID of the block holding the range.
  final String blockId;

  /// Block-local start of the marked text.
  final int start;

  /// Block-local exclusive end of the marked text.
  final int end;

  /// The marked text itself.
  final String text;

  /// What was typed after `|`, trimmed; null when there was no `|` or
  /// nothing but spaces after it.
  final String? note;

  @override
  bool operator ==(Object other) =>
      other is HomericInlineAnnotationRequest &&
      other.blockId == blockId &&
      other.start == start &&
      other.end == end &&
      other.text == text &&
      other.note == note;

  @override
  int get hashCode => Object.hash(blockId, start, end, text, note);

  @override
  String toString() => 'HomericInlineAnnotationRequest($blockId, '
      '$start..$end, "$text"${note == null ? '' : ', note: "$note"'})';
}

/// Turns typed `{{text}}` into an annotation request.
///
/// Default is **off**: a host registers [interceptor] (or calls [installOn])
/// to enable it. [onAnnotate] runs after the frame that lays out the edited
/// paragraph, so geometry for the range is current when the host anchors its
/// composer there. The edit is one undo step: undo restores the braces.
final class HomericInlineAnnotationShortcut {
  /// Creates the shortcut.
  const HomericInlineAnnotationShortcut({required this.onAnnotate});

  /// Receives each marked range once its braces are gone.
  final ValueChanged<HomericInlineAnnotationRequest> onAnnotate;

  /// Command interceptor that recognizes the closing brace on
  /// [HomericCommandKind.preInsert].
  HomericCommandInterceptor get interceptor => _intercept;

  /// Registers [interceptor] on [controller]; returns the unregister callback.
  VoidCallback installOn(HomericEditorController controller) =>
      controller.addCommandInterceptor(interceptor);

  /// Text between the braces: one line, no nested braces, not just spaces,
  /// then an optional `|note`. The marked words stop at the first `|`.
  static final RegExp _closing = RegExp(
    r'\{\{([^{}|\n]*[^{}|\s][^{}|\n]*)(?:\|([^{}\n]*))?\}$',
  );

  HomericCommandInterception _intercept(HomericEditorCommand command) {
    if (command.kind != HomericCommandKind.preInsert || command.text != '}') {
      return HomericCommandInterception.ignored;
    }
    final selection = command.selection;
    final blockId = command.blockId;
    if (selection == null || !selection.isCollapsed || blockId == null) {
      return HomericCommandInterception.ignored;
    }
    final controller = command.controller;
    final resolved = controller.document.resolve(selection.head);
    if (resolved is! InlinePosition || resolved.block.id != blockId) {
      return HomericCommandInterception.ignored;
    }
    final offset = resolved.offset;
    final before = resolved.block.text.substring(0, offset);
    final match = _closing.firstMatch(before);
    if (match == null) return HomericCommandInterception.ignored;

    final open = match.start;
    final inner = match.group(1)!;
    final note = match.group(2)?.trim();
    final innerEnd = open + 2 + inner.length;
    final applied = controller.applyBlockEditBatch(
      blockId: blockId,
      edits: <CanonicalTextEdit>[
        // `|note` and the first closing brace, already typed; the second
        // never lands.
        CanonicalTextEdit(innerEnd, offset, ''),
        CanonicalTextEdit(open, open + 2, ''),
      ],
      selection: BlockTextSelection.collapsed(open + inner.length),
    );
    if (!applied) return HomericCommandInterception.ignored;

    final request = HomericInlineAnnotationRequest(
      blockId: blockId,
      start: open,
      end: open + inner.length,
      text: inner,
      note: note == null || note.isEmpty ? null : note,
    );
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => onAnnotate(request))
      ..ensureVisualUpdate();
    return HomericCommandInterception.handled;
  }
}
