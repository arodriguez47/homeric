/// ⌘B, ⌘I, ⌘E and ⌘⇧S wrap the selection in markdown markers.
///
/// The markers are written into the text (`**bold**`, `*italic*`,
/// `` `code` ``, `~~struck~~`), so a host that shows markdown as live
/// preview gets the styling from its own syntax, and the source stays
/// plain text. Pressing the shortcut again on a selection that is already
/// wrapped in exactly that marker takes the marker off.
library;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart' show SingleActivator, VoidCallback;

import '../editing/editable_document.dart';
import '../editing/editor_controller.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';
import 'writing_feature.dart';

/// One wrap shortcut: the key, with ⌘ (and Ctrl on other platforms), and
/// the marker it writes.
final class HomericWrap {
  /// Creates a wrap on [key] with [marker].
  const HomericWrap(this.key, this.marker, {this.shift = false});

  /// The letter pressed with ⌘ or Ctrl.
  final LogicalKeyboardKey key;

  /// Whether Shift is held too.
  final bool shift;

  /// The marker written on both sides of the selection.
  final String marker;
}

/// The wrap shortcuts as a [HomericWritingFeature].
///
/// Each shortcut is bound twice, with ⌘ and with Ctrl, so it works the same
/// on macOS and elsewhere. It acts on a selection inside one block; a
/// collapsed caret or a selection across blocks is left to the host.
final class HomericWrapShortcuts extends HomericWritingFeature {
  /// Creates the feature with [wraps].
  const HomericWrapShortcuts({this.wraps = standardWraps});

  /// ⌘B bold, ⌘I italic, ⌘E code, ⌘⇧S strikethrough.
  static const List<HomericWrap> standardWraps = <HomericWrap>[
    HomericWrap(LogicalKeyboardKey.keyB, '**'),
    HomericWrap(LogicalKeyboardKey.keyI, '*'),
    HomericWrap(LogicalKeyboardKey.keyE, '`'),
    HomericWrap(LogicalKeyboardKey.keyS, '~~', shift: true),
  ];

  /// The shortcuts bound, in order.
  final List<HomericWrap> wraps;

  @override
  String get id => 'wrapShortcuts';

  @override
  VoidCallback installOn(HomericEditorController controller) =>
      homericWritingNoop;

  @override
  List<HomericDocumentCommandBinding> get commandBindings =>
      <HomericDocumentCommandBinding>[
        for (final wrap in wraps)
          for (final control in const <bool>[false, true])
            HomericDocumentCommandBinding(
              shortcut: SingleActivator(
                wrap.key,
                meta: !control,
                control: control,
                shift: wrap.shift,
              ),
              onInvoke: (context) => wrapResult(context, wrap.marker),
            ),
      ];

  /// The binding result for wrapping [context]'s selection in [marker].
  static HomericDocumentCommandResult wrapResult(
    HomericDocumentCommandContext context,
    String marker,
  ) {
    if (!context.isCurrent || context.composing != null) {
      return HomericDocumentCommandResult.ignored;
    }
    try {
      final prepared = prepareWrap(
        context.document,
        context.selection,
        marker,
        blockId: context.blockId,
      );
      return prepared == null
          ? HomericDocumentCommandResult.ignored
          : HomericDocumentCommandResult.prepared(prepared);
    } on ArgumentError catch (error) {
      return HomericDocumentCommandResult.rejected(
        error,
        announcement: 'This selection cannot be formatted here.',
      );
    } on StepFailedError catch (error) {
      return HomericDocumentCommandResult.rejected(
        error,
        announcement: 'This selection cannot be formatted here.',
      );
    }
  }

  /// The command that wraps [selection] of [document] in [marker], or takes
  /// [marker] off when the selection is already wrapped in exactly it; null
  /// when the selection is collapsed or spans blocks (or is not in
  /// [blockId], when given).
  static HomericPreparedCommand? prepareWrap(
    Document document,
    HomericSelection? selection,
    String marker, {
    String? blockId,
  }) {
    if (selection == null || selection.isCollapsed || marker.isEmpty) {
      return null;
    }
    final anchor = document.resolve(selection.anchor);
    final head = document.resolve(selection.head);
    if (anchor is! InlinePosition ||
        head is! InlinePosition ||
        anchor.blockIndex != head.blockIndex ||
        (blockId != null && anchor.block.id != blockId)) {
      return null;
    }
    final index = anchor.blockIndex;
    final text = anchor.block.text;
    final start = anchor.offset < head.offset ? anchor.offset : head.offset;
    final end = anchor.offset > head.offset ? anchor.offset : head.offset;
    final forward = head.offset >= anchor.offset;
    final transaction = Transaction(document);
    final int newStart;
    final int newEnd;
    if (_wrappedIn(text, start, end, marker)) {
      transaction
        ..deleteRange(
          document.positionAt(index, end),
          document.positionAt(index, end + marker.length),
        )
        ..deleteRange(
          document.positionAt(index, start - marker.length),
          document.positionAt(index, start),
        );
      newStart = start - marker.length;
      newEnd = end - marker.length;
    } else {
      transaction
        ..insertText(document.positionAt(index, end), marker)
        ..insertText(document.positionAt(index, start), marker);
      newStart = start + marker.length;
      newEnd = end + marker.length;
    }
    final after = transaction.doc;
    final from = after.positionAt(index, forward ? newStart : newEnd);
    final to = after.positionAt(index, forward ? newEnd : newStart);
    return HomericPreparedCommand(
      stages: <Transaction>[transaction],
      selection: HomericSelection(
        anchor: from,
        head: to,
        affinity: selection.affinity,
      ),
    );
  }

  /// Whether `[start, end)` of [text] sits between two [marker]s that are
  /// not part of a longer run of the same character (`**` around a ⌘I
  /// selection is bold, not italic).
  static bool _wrappedIn(String text, int start, int end, String marker) {
    final before = start - marker.length;
    final after = end + marker.length;
    if (before < 0 || after > text.length) return false;
    if (text.substring(before, start) != marker ||
        text.substring(end, after) != marker) {
      return false;
    }
    final unit = marker[marker.length - 1];
    if (marker.split('').every((c) => c == unit)) {
      if (before > 0 && text[before - 1] == unit) return false;
      if (after < text.length && text[after] == unit) return false;
      if (start < end && (text[start] == unit || text[end - 1] == unit)) {
        return false;
      }
    }
    return true;
  }
}
