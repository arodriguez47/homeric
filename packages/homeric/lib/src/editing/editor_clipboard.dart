/// Epoch-safe clipboard operations for one canonical editor block.
library;

import 'package:flutter/services.dart';

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

/// A paste was rejected because this phase only accepts one paragraph.
final class HomericPasteRejected extends HomericHostEvent {
  const HomericPasteRejected();
}

/// Coordinates stale-safe clipboard work for one mounted editor host.
///
/// Every operation captures the controller state and a monotonically newer
/// request generation. Async completions fail closed when the host, block,
/// selection, composition, revision, or request generation has changed.
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
    controller.replaceSelection('');
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
    if (text.contains('\n') || text.contains('\r')) {
      onEvent?.call(const HomericPasteRejected());
      return;
    }
    controller.replaceSelection(text);
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
    late final BlockTextSelection local;
    try {
      local = BlockTextSelection(
        anchor: controller.blockOffsetForGlobalPosition(
          blockId,
          selection.anchor,
        ),
        head: controller.blockOffsetForGlobalPosition(blockId, selection.head),
        affinity: selection.affinity,
      );
    } on ArgumentError {
      return null;
    }
    if (requireExpandedSelection && local.isCollapsed) return null;
    return _ClipboardWitness(
      ++_generation,
      controller.stateRevision,
      local,
    );
  }

  String _visibleSelection(_ClipboardWitness witness) {
    final block = controller.document.blockById(blockId);
    if (block == null) return '';
    final source = ParagraphSource<Object?>.build(
      block: block,
      decorations: controller.decorations.forBlock(blockId),
      resolveStyle: (_) => null,
    );
    final start = source.viewMap.docToView(witness.selection.start, assoc: 1);
    final end = source.viewMap.docToView(witness.selection.end, assoc: -1);
    return start < end ? source.viewText.substring(start, end) : '';
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
  final BlockTextSelection selection;
}
