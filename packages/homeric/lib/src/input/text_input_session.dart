/// Experimental epoch-bound platform text input for one canonical block.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editing/editor_controller.dart';
import '../model/document.dart';
import '../model/selection.dart';

/// Connects one focused canonical block to Flutter's delta text-input model.
///
/// This surface is experimental until a real Nexus consumer validates it. The
/// platform value always contains raw block text; projected view offsets never
/// cross this boundary.
final class HomericTextInputSession {
  /// Creates a session that observes [controller].
  HomericTextInputSession({
    required this.controller,
    TextInputConfiguration configuration = const TextInputConfiguration(
      inputType: TextInputType.text,
      inputAction: TextInputAction.none,
      enableDeltaModel: true,
    ),
  }) : _configuration = configuration {
    if (!configuration.enableDeltaModel) {
      throw ArgumentError.value(
        configuration,
        'configuration',
        'must enable the delta model',
      );
    }
    controller.addListener(_controllerChanged);
  }

  /// The canonical editor state owned outside this platform adapter.
  final HomericEditorController controller;

  final TextInputConfiguration _configuration;
  TextInputConnection? _connection;
  _EpochTextInputClient? _client;
  TextEditingValue? _shadowValue;
  String? _blockId;
  int _nextEpoch = 0;
  int? _currentEpoch;
  int? _geometryGeneration;
  bool _applyingRemote = false;
  bool _disposed = false;

  /// Whether this session currently owns Flutter's active input connection.
  bool get isAttached => _connection?.attached ?? false;

  /// Stable id of the block exposed to the platform, if connected.
  String? get activeBlockId => isAttached ? _blockId : null;

  /// Captures the current adapter's epoch-bound delta callback for tests.
  ///
  /// The opaque callback proves that a superseded adapter cannot act as the
  /// current client without making the private adapter part of the API.
  @visibleForTesting
  ValueChanged<List<TextEditingDelta>>? get debugDeltaCallback {
    final client = _client;
    return client?.updateEditingValueWithDeltas;
  }

  /// Opens platform input for [blockId], or reuses its live connection.
  ///
  /// A valid canonical selection is sufficient; layout geometry may arrive
  /// later through [publishGeometry].
  bool attach({required String blockId}) {
    if (_disposed ||
        controller.activeBlockId != blockId ||
        controller.document.indexOfBlockId(blockId) == null) {
      return false;
    }
    if (isAttached && _blockId == blockId) return true;

    _close(CompositionInterruption.activeBlockSwitch);
    final value = _canonicalValue(blockId);
    if (value == null) return false;

    final epoch = ++_nextEpoch;
    final client = _EpochTextInputClient(this, epoch);
    final connection = TextInput.attach(client, _configuration);
    _currentEpoch = epoch;
    _client = client;
    _connection = connection;
    _blockId = blockId;
    _shadowValue = value;
    _geometryGeneration = null;
    connection.setEditingState(value);
    connection.show();
    return true;
  }

  /// Ends focus ownership while preserving the controller's logical selection.
  void blur() => _close(CompositionInterruption.blur);

  /// Publishes current-layout platform geometry for the connected block.
  ///
  /// [documentRevision] is an identity witness: geometry from any prior
  /// immutable [Document] is rejected. A regressing [layoutGeneration] is also
  /// rejected, allowing the host to race layout safely without pausing input.
  bool publishGeometry({
    required Document documentRevision,
    required int layoutGeneration,
    required Size editableSize,
    required Matrix4 transform,
    required Rect caretRect,
    Rect? composingRect,
  }) {
    final connection = _connection;
    if (_disposed ||
        connection == null ||
        !connection.attached ||
        !identical(documentRevision, controller.document) ||
        (_geometryGeneration != null &&
            layoutGeneration < _geometryGeneration!)) {
      return false;
    }
    _geometryGeneration = layoutGeneration;
    connection.setEditableSizeAndTransform(editableSize, transform);
    connection.setCaretRect(caretRect);
    if (composingRect != null) connection.setComposingRect(composingRect);
    return true;
  }

  void _controllerChanged() {
    if (_disposed || _applyingRemote || !isAttached) return;
    _syncCanonical(force: false);
  }

  TextEditingValue? _canonicalValue(String blockId) {
    final index = controller.document.indexOfBlockId(blockId);
    final selection = controller.selection;
    if (index == null || selection == null) return null;
    int anchor;
    int head;
    try {
      anchor = controller.blockOffsetForGlobalPosition(
        blockId,
        selection.anchor,
      );
      head = controller.blockOffsetForGlobalPosition(blockId, selection.head);
    } on ArgumentError {
      return null;
    }
    final composing = controller.composing;
    var composingRange = TextRange.empty;
    if (composing != null) {
      try {
        composingRange = TextRange(
          start: controller.blockOffsetForGlobalPosition(
            blockId,
            composing.start,
          ),
          end: controller.blockOffsetForGlobalPosition(
            blockId,
            composing.end,
          ),
        );
      } on ArgumentError {
        return null;
      }
    }
    return TextEditingValue(
      text: controller.document.blocks[index].text,
      selection: TextSelection(
        baseOffset: anchor,
        extentOffset: head,
        affinity: selection.affinity == HomericCaretAffinity.upstream
            ? TextAffinity.upstream
            : TextAffinity.downstream,
        // Anchor and head already preserve direction. Flutter's independent
        // flag describes how the platform formed the selection, which the
        // canonical model intentionally does not own.
        isDirectional: false,
      ),
      composing: composingRange,
    );
  }

  void _syncCanonical({required bool force}) {
    final connection = _connection;
    final blockId = _blockId;
    if (connection == null || !connection.attached || blockId == null) return;
    final canonical = _canonicalValue(blockId);
    if (canonical == null) {
      _close(CompositionInterruption.activeBlockSwitch);
      return;
    }
    if (force || !_sameCanonicalValue(canonical, _shadowValue)) {
      _shadowValue = canonical;
      connection.setEditingState(canonical);
    }
  }

  void _updateWithDeltas(int epoch, List<TextEditingDelta> deltas) {
    if (_disposed || epoch != _currentEpoch || !isAttached) {
      _syncCanonical(force: true);
      return;
    }
    final initial = _shadowValue;
    final blockId = _blockId;
    if (initial == null || blockId == null) return;

    var shadow = initial;
    final edits = <CanonicalTextEdit>[];
    try {
      for (final delta in deltas) {
        if (delta.oldText != shadow.text) {
          _syncCanonical(force: true);
          return;
        }
        final next = delta.apply(shadow);
        if (!_validValue(next) || _containsNewline(next.text)) {
          _syncCanonical(force: true);
          return;
        }
        final edit = _singleEdit(shadow.text, next.text);
        if (edit != null) edits.add(edit);
        shadow = next;
      }
    } on AssertionError {
      _syncCanonical(force: true);
      return;
    } on ArgumentError {
      _syncCanonical(force: true);
      return;
    }

    if (!_validValue(shadow) || _containsNewline(shadow.text)) {
      _syncCanonical(force: true);
      return;
    }
    final composing = shadow.composing.isValid && !shadow.composing.isCollapsed
        ? BlockTextRange(shadow.composing.start, shadow.composing.end)
        : null;
    _applyingRemote = true;
    try {
      controller.applyBlockEditBatch(
        blockId: blockId,
        edits: edits,
        selection: BlockTextSelection(
          anchor: shadow.selection.baseOffset,
          head: shadow.selection.extentOffset,
          affinity: shadow.selection.affinity == TextAffinity.upstream
              ? HomericCaretAffinity.upstream
              : HomericCaretAffinity.downstream,
        ),
        composing: composing,
      );
    } finally {
      _applyingRemote = false;
    }

    final canonical = _canonicalValue(blockId);
    if (_sameCanonicalValue(canonical, shadow)) {
      _shadowValue = shadow;
      return;
    }
    _syncCanonical(force: true);
  }

  void _legacyUpdate(int epoch, TextEditingValue value) {
    _resyncIfCurrent(epoch);
  }

  void _performAction(int epoch, TextInputAction action) {
    _resyncIfCurrent(epoch);
  }

  void _resyncIfCurrent(int epoch) {
    if (epoch != _currentEpoch || _disposed) return;
    _syncCanonical(force: true);
  }

  void _platformClosed(int epoch) {
    if (_disposed || epoch != _currentEpoch) return;
    _invalidateEpoch();
    _connection?.connectionClosedReceived();
    _connection = null;
    _client = null;
    _blockId = null;
    _shadowValue = null;
    _geometryGeneration = null;
    controller.interruptComposition(CompositionInterruption.platformClose);
  }

  void _close(CompositionInterruption interruption) {
    final connection = _connection;
    _invalidateEpoch();
    _connection = null;
    _client = null;
    _blockId = null;
    _shadowValue = null;
    _geometryGeneration = null;
    controller.interruptComposition(interruption);
    connection?.close();
  }

  void _invalidateEpoch() {
    _currentEpoch = null;
  }

  static bool _containsNewline(String text) =>
      text.contains('\n') || text.contains('\r');

  static bool _sameCanonicalValue(
    TextEditingValue? left,
    TextEditingValue? right,
  ) =>
      left != null &&
      right != null &&
      left.text == right.text &&
      left.selection.baseOffset == right.selection.baseOffset &&
      left.selection.extentOffset == right.selection.extentOffset &&
      left.selection.affinity == right.selection.affinity &&
      left.composing == right.composing;

  static bool _validValue(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || selection.end > value.text.length) {
      return false;
    }
    final composing = value.composing;
    return !composing.isValid || composing.end <= value.text.length;
  }

  static CanonicalTextEdit? _singleEdit(String before, String after) {
    if (before == after) return null;
    var start = 0;
    final shortest =
        before.length < after.length ? before.length : after.length;
    while (start < shortest &&
        before.codeUnitAt(start) == after.codeUnitAt(start)) {
      start++;
    }
    var beforeEnd = before.length;
    var afterEnd = after.length;
    while (beforeEnd > start &&
        afterEnd > start &&
        before.codeUnitAt(beforeEnd - 1) == after.codeUnitAt(afterEnd - 1)) {
      beforeEnd--;
      afterEnd--;
    }
    return CanonicalTextEdit(
        start, beforeEnd, after.substring(start, afterEnd));
  }

  /// Invalidates and closes the live connection exactly once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_controllerChanged);
    _close(CompositionInterruption.disposal);
  }
}

final class _EpochTextInputClient with DeltaTextInputClient {
  const _EpochTextInputClient(this.session, this.epoch);

  final HomericTextInputSession session;
  final int epoch;

  @override
  TextEditingValue? get currentTextEditingValue =>
      epoch == session._currentEpoch ? session._shadowValue : null;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) =>
      session._updateWithDeltas(epoch, textEditingDeltas);

  @override
  void updateEditingValue(TextEditingValue value) =>
      session._legacyUpdate(epoch, value);

  @override
  void performAction(TextInputAction action) =>
      session._performAction(epoch, action);

  @override
  void connectionClosed() => session._platformClosed(epoch);

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  // Flutter added this optional hook after Homeric's 3.24 minimum.
  // ignore: annotate_overrides
  bool onFocusReceived() => false;

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void showToolbar() {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void performSelector(String selectorName) {
    if (epoch != session._currentEpoch || session._disposed) return;
    final intent = intentForMacOSSelector(selectorName);
    final context = primaryFocus?.context;
    if (intent != null && context != null) Actions.maybeInvoke(context, intent);
  }
}
