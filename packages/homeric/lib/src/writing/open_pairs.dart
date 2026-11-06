/// A mark started at a bare caret: `**▍**`, the caret between the markers.
///
/// With nothing selected, a format button (or ⌘B, ⌘I, ⌘E, ⌘⇧S) writes its
/// marker twice and leaves the caret between them, so what is typed next
/// comes out styled, as it would after typing the opening marker by hand.
/// The pair is followed while the caret stays inside it:
///
/// - the same button again steps the caret out past the closing marker;
/// - a pair still empty when the caret leaves it is taken out again, so
///   no stray `****` is left in the text. When opening it was the last
///   change, the removal undoes it, leaving nothing in the history.
library;

import 'dart:async';

import '../editing/editor_controller.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';
import '../transform/builders.dart';
import '../transform/transaction.dart';

/// The marks a controller has open round its caret, innermost last.
final class HomericOpenPairs {
  HomericOpenPairs._(this._controller) {
    // Both streams close with the controller, ending the listening.
    _controller.committedChanges.listen(_mapThrough);
    _controller.selectionChanges.listen((_) => _caretMoved());
  }

  static final Expando<HomericOpenPairs> _of = Expando<HomericOpenPairs>();

  /// The open marks of [controller], following it from the first call.
  static HomericOpenPairs of(HomericEditorController controller) =>
      _of[controller] ??= HomericOpenPairs._(controller);

  /// The open marks of [controller], or null when none was ever opened.
  static HomericOpenPairs? maybeOf(HomericEditorController controller) =>
      _of[controller];

  final HomericEditorController _controller;
  final List<_OpenPair> _pairs = <_OpenPair>[];
  bool _cleanupScheduled = false;

  /// Whether [caret] sits inside a mark opened here.
  bool holds(HomericSelection? caret) =>
      caret != null && caret.isCollapsed && _pairs.any((p) => p.holds(caret));

  /// Whether [caret] sits inside an open mark of [marker].
  bool isOpen(HomericSelection? caret, String marker) =>
      caret != null &&
      caret.isCollapsed &&
      _pairs.any((p) => p.marker == marker && p.holds(caret));

  /// Whether [marker] can open at [caret]: a bare caret in a block's text,
  /// outside a composition.
  static bool canOpen(
      HomericEditorController controller, HomericSelection? caret) {
    if (caret == null || !caret.isCollapsed || controller.composing != null) {
      return false;
    }
    return controller.document.resolve(caret.head) is InlinePosition;
  }

  /// What a press of [marker] does at the bare caret: steps out of its open
  /// mark when the caret is inside one, else opens a new one. Returns
  /// whether anything changed.
  bool press(String marker) {
    final caret = _controller.selection;
    if (!canOpen(_controller, caret)) return false;
    for (final pair in _pairs.reversed) {
      if (pair.marker == marker && pair.holds(caret!)) {
        return _controller.setSelection(
          HomericSelection.collapsed(pair.close + marker.length),
        );
      }
    }
    return _open(marker, caret!);
  }

  bool _open(String marker, HomericSelection caret) {
    final document = _controller.document;
    final at = document.resolve(caret.head);
    if (at is! InlinePosition) return false;
    final Transaction tx;
    try {
      tx = Transaction(document)
        ..insertText(
            document.positionAt(at.blockIndex, at.offset), '$marker$marker');
    } on ArgumentError {
      return false;
    }
    final inner = caret.head + marker.length;
    final applied = _controller.applyPreparedCommand(HomericPreparedCommand(
      stages: <Transaction>[tx],
      selection: HomericSelection.collapsed(inner),
    ));
    if (!applied) return false;
    _pairs.add(_OpenPair(
      marker: marker,
      inner: inner,
      close: inner,
      openedAt: _controller.documentRevision,
    ));
    return true;
  }

  void _mapThrough(HomericCommittedChange change) {
    if (_pairs.isEmpty) return;
    for (final pair in _pairs) {
      // Words typed at an empty pair's caret go in, between the markers.
      pair.inner = change.mapping.map(pair.inner, assoc: -1);
      pair.close = change.mapping.map(pair.close, assoc: 1);
    }
    _pairs.removeWhere((p) => !p.standsIn(change.after));
  }

  void _caretMoved() {
    if (_pairs.isEmpty || _cleanupScheduled) return;
    final caret = _controller.selection;
    if (caret != null && _pairs.every((p) => p.holds(caret))) return;
    // A change can't be made while the controller publishes one.
    _cleanupScheduled = true;
    scheduleMicrotask(_closeLeftPairs);
  }

  void _closeLeftPairs() {
    _cleanupScheduled = false;
    final caret = _controller.selection;
    final left = <_OpenPair>[
      for (final pair in _pairs)
        if (caret == null || !pair.holds(caret)) pair,
    ];
    if (left.isEmpty) return;
    _pairs.removeWhere(left.contains);
    // Empty: nothing between the markers, or only another empty pair
    // opened inside (`**==▍==**`). Innermost first.
    final standing = [
      for (final pair in left)
        if (pair.standsIn(_controller.document)) pair,
    ]..sort((a, b) => (a.close - a.inner).compareTo(b.close - b.inner));
    final empty = <_OpenPair>[];
    for (final pair in standing) {
      if (pair.inner == pair.close ||
          empty.any((q) =>
              q.inner - q.marker.length == pair.inner &&
              q.close + q.marker.length == pair.close)) {
        empty.add(pair);
      }
    }
    if (empty.isEmpty || _controller.isReadOnly) return;
    // Only the pair just opened, left untouched: undoing its opening takes
    // it out without a step to undo, and the caret goes where it was put.
    if (empty.length == 1 &&
        empty.single.openedAt == _controller.documentRevision &&
        caret != null) {
      final pair = empty.single;
      final width = 2 * pair.marker.length;
      final start = pair.inner - pair.marker.length;
      // A place inside the markers taken out lands where they stood.
      HomericSelection back(int p) => HomericSelection.collapsed(
            p <= start
                ? p
                : p >= start + width
                    ? p - width
                    : start,
          );
      final target = caret.isCollapsed
          ? back(caret.head)
          : HomericSelection(
              anchor: back(caret.anchor).head,
              head: back(caret.head).head,
              affinity: caret.affinity,
            );
      if (_controller.undo()) {
        _controller.setSelection(target);
        return;
      }
    }
    _removeMarkers(empty, caret);
  }

  void _removeMarkers(List<_OpenPair> empty, HomericSelection? caret) {
    final document = _controller.document;
    try {
      final tx = Transaction(document);
      // Empty pairs opened one inside another (`***▍***`) are one run of
      // markers: merge the spans, then delete furthest first, so the
      // offsets still to come stay where they were.
      final spans = <(int, int)>[
        for (final pair in empty)
          (pair.inner - pair.marker.length, pair.close + pair.marker.length),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      final merged = <(int, int)>[];
      for (final span in spans) {
        if (merged.isNotEmpty && span.$1 <= merged.last.$2) {
          final last = merged.removeLast();
          merged.add((last.$1, span.$2 > last.$2 ? span.$2 : last.$2));
        } else {
          merged.add(span);
        }
      }
      for (final (from, to) in merged.reversed) {
        tx.deleteRange(from, to);
      }
      _controller.applyPreparedCommand(HomericPreparedCommand(
        stages: <Transaction>[tx],
        selection: caret?.map(tx.mapping),
      ));
    } on ArgumentError {
      // The text moved on under the pair; leave it be.
    }
  }
}

final class _OpenPair {
  _OpenPair({
    required this.marker,
    required this.inner,
    required this.close,
    required this.openedAt,
  });

  final String marker;

  /// Global position just after the opening marker.
  int inner;

  /// Global position of the closing marker.
  int close;

  /// The controller's document revision right after opening: any later
  /// change to the document, text or not, moves it on.
  final int openedAt;

  bool holds(HomericSelection caret) =>
      caret.isCollapsed && caret.head >= inner && caret.head <= close;

  /// Whether both markers still stand around the words in one block.
  bool standsIn(Document document) {
    if (close < inner) return false;
    final from = document.resolve(inner);
    final to = document.resolve(close);
    if (from is! InlinePosition ||
        to is! InlinePosition ||
        from.blockIndex != to.blockIndex) {
      return false;
    }
    final text = from.block.text;
    final length = marker.length;
    if (from.offset < length || to.offset + length > text.length) {
      return false;
    }
    return text.substring(from.offset - length, from.offset) == marker &&
        text.substring(to.offset, to.offset + length) == marker;
  }
}
