/// Epoch-safe clipboard operations for one canonical editor document.
library;

import 'package:flutter/services.dart';

import '../model/position.dart';
import '../model/selection.dart';
import '../render/paragraph_source.dart';
import 'editor_controller.dart';

/// Plain-text clipboard boundary used by the editable host.
abstract interface class HomericClipboardAdapter {
  /// Reads plain text, or `null` when the clipboard has no text payload.
  Future<String?> readText();

  /// Writes one plain-text payload.
  Future<void> writeText(String text);
}

/// Clipboard adapter backed by Flutter's system clipboard.
final class SystemHomericClipboard implements HomericClipboardAdapter {
  const SystemHomericClipboard();

  @override
  Future<String?> readText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

/// Operation that produced a clipboard host event.
enum HomericClipboardOperation { copy, cut, paste }

/// Presentation-agnostic feedback emitted by an editable host.
sealed class HomericHostEvent {
  const HomericHostEvent();
}

/// A clipboard adapter call failed while its host was still current.
final class HomericClipboardFailure extends HomericHostEvent {
  const HomericClipboardFailure(this.operation, this.error);

  final HomericClipboardOperation operation;
  final Object error;
}

/// A paste was rejected by the host's structural editing policy.
final class HomericPasteRejected extends HomericHostEvent {
  const HomericPasteRejected();
}

/// Coordinates stale-safe clipboard work for one mounted editor host.
///
/// Every operation captures the controller state and a monotonically newer
/// request generation. Async completions fail closed when the host, block,
/// selection, composition, revision, or request generation has changed. Text
/// projection spans the canonical selection without laying out off-screen
/// paragraphs; hidden replacement decorations remain absent from the payload.
final class HomericEditorClipboard {
  HomericEditorClipboard({
    required this.controller,
    required this.blockId,
    required this.adapter,
    required this.isHostCurrent,
    this.onEvent,
  });

  final HomericEditorController controller;
  final String blockId;
  final HomericClipboardAdapter adapter;
  final bool Function() isHostCurrent;
  final void Function(HomericHostEvent event)? onEvent;

  int _generation = 0;
  bool _disposed = false;

  Future<void> copy() async {
    final witness = _capture(requireExpandedSelection: true);
    if (witness == null) return;
    final text = _visibleSelection(witness);
    try {
      await adapter.writeText(text);
    } on Object catch (error) {
      _emitFailureIfCurrent(witness, HomericClipboardOperation.copy, error);
    }
  }

  Future<void> cut() async {
    final witness = _capture(requireExpandedSelection: true);
    if (witness == null) return;
    final text = _visibleSelection(witness);
    try {
      await adapter.writeText(text);
    } on Object catch (error) {
      _emitFailureIfCurrent(witness, HomericClipboardOperation.cut, error);
      return;
    }
    if (!_isCurrent(witness)) return;
    controller.replaceSelectionStructurally('');
  }

  Future<void> paste() async {
    final witness = _capture(requireExpandedSelection: false);
    if (witness == null) return;
    late final String? text;
    try {
      text = await adapter.readText();
    } on Object catch (error) {
      _emitFailureIfCurrent(witness, HomericClipboardOperation.paste, error);
      return;
    }
    if (!_isCurrent(witness) || text == null || text.isEmpty) return;
    if (!controller.replaceSelectionStructurally(text) && _isCurrent(witness)) {
      onEvent?.call(const HomericPasteRejected());
    }
  }

  _ClipboardWitness? _capture({required bool requireExpandedSelection}) {
    final selection = controller.selection;
    if (_disposed ||
        !isHostCurrent() ||
        controller.activeBlockId != blockId ||
        controller.composing != null ||
        selection == null) {
      return null;
    }
    if (requireExpandedSelection && selection.isCollapsed) return null;
    return _ClipboardWitness(
      ++_generation,
      controller.stateRevision,
      selection,
    );
  }

  String _visibleSelection(_ClipboardWitness witness) {
    final document = controller.document;
    final start = document.resolve(witness.selection.start);
    final end = document.resolve(witness.selection.end);
    if (start is! InlinePosition || end is! InlinePosition) return '';
    final slices = <String>[];
    for (var index = start.blockIndex; index <= end.blockIndex; index++) {
      final block = document.blocks[index];
      final source = ParagraphSource<Object?>.build(
        block: block,
        decorations: controller.decorations.forBlock(block.id),
        resolveStyle: (_) => null,
      );
      final localStart = index == start.blockIndex ? start.offset : 0;
      final localEnd =
          index == end.blockIndex ? end.offset : block.contentLength;
      final viewStart = source.viewMap.docToView(localStart, assoc: 1);
      final viewEnd = source.viewMap.docToView(localEnd, assoc: -1);
      slices.add(viewStart < viewEnd
          ? source.viewText.substring(viewStart, viewEnd)
          : '');
    }
    return slices.join('\n');
  }

  bool _isCurrent(_ClipboardWitness witness) {
    return !_disposed &&
        witness.generation == _generation &&
        isHostCurrent() &&
        controller.stateRevision == witness.stateRevision;
  }

  void _emitFailureIfCurrent(
    _ClipboardWitness witness,
    HomericClipboardOperation operation,
    Object error,
  ) {
    if (_isCurrent(witness)) {
      onEvent?.call(HomericClipboardFailure(operation, error));
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
  }
}

final class _ClipboardWitness {
  const _ClipboardWitness(
    this.generation,
    this.stateRevision,
    this.selection,
  );

  final int generation;
  final int stateRevision;
  final HomericSelection selection;
}
