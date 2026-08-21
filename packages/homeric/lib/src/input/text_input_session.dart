/// Experimental epoch-bound platform text input for one canonical block.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editing/editor_controller.dart';
import '../model/document.dart';
import '../model/position.dart';
import '../model/selection.dart';

/// Host-owned command boundary captured by one platform input epoch.
abstract interface class HomericTextInputCommandDelegate {
  /// Dispatches one standard Flutter editing [intent].
  Object? invoke(Intent intent);

  /// Requests the current host's editing toolbar.
  void showToolbar();

  /// Highlights the canonical block-local range targeted by iOS autocorrect.
  void showAutocorrectionPromptRect(TextRange range);

  /// Forwards one ordered platform floating-cursor callback.
  void updateFloatingCursor(RawFloatingCursorPoint point);

  /// Revokes host-owned transient input state before this epoch closes.
  void cancelTransientInput();
}

/// Requests a document-owned structural paragraph break.
final class HomericInsertParagraphBreakIntent extends Intent {
  /// Creates the structural break command.
  const HomericInsertParagraphBreakIntent();
}

/// Opaque capability for publishing platform caret and composing geometry.
///
/// A session replaces this object whenever its attached block or host command
/// capability changes. Consumers capture it with the geometry they measure;
/// stale rows can then be rejected without exposing or guessing epoch values.
final class HomericTextInputGeometryLease {
  HomericTextInputGeometryLease._();
}

/// Connects one focused canonical block to Flutter's delta text-input model.
///
/// This surface is experimental until a real Nexus consumer validates it. The
/// platform value always contains raw block text; projected view offsets never
/// cross this boundary.
final class HomericTextInputSession extends ChangeNotifier {
  /// Creates a session that observes [controller].
  HomericTextInputSession({
    required this.controller,
    TextInputConfiguration configuration = const TextInputConfiguration(
      inputType: TextInputType.text,
      inputAction: TextInputAction.newline,
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
  HomericTextInputGeometryLease? _geometryLease;
  Object? _geometryOwner;
  HomericTextInputCommandDelegate? _commandDelegate;
  bool _applyingRemote = false;
  bool _deltasSuspended = false;
  bool _disposed = false;
  String? _suppressedSelector;
  Timer? _suppressedSelectorTimer;

  /// Whether this session currently owns Flutter's active input connection.
  bool get isAttached => _connection?.attached ?? false;

  /// Stable id of the block exposed to the platform, if connected.
  String? get activeBlockId => isAttached ? _blockId : null;

  /// Returns the current geometry capability only to its exact attached host.
  HomericTextInputGeometryLease? geometryLeaseFor({
    required String blockId,
    required Object owner,
  }) =>
      isAttached && _blockId == blockId && identical(_geometryOwner, owner)
          ? _geometryLease
          : null;

  /// Captures the current adapter's epoch-bound delta callback for tests.
  ///
  /// The opaque callback proves that a superseded adapter cannot act as the
  /// current client without making the private adapter part of the API.
  @visibleForTesting
  ValueChanged<List<TextEditingDelta>>? get debugDeltaCallback {
    final client = _client;
    return client?.debugDeltaCallback;
  }

  /// Captures the current adapter's epoch-bound selector callback for tests.
  @visibleForTesting
  ValueChanged<String>? get debugSelectorCallback => _client?.performSelector;

  /// Captures the current adapter's epoch-bound toolbar callback for tests.
  @visibleForTesting
  VoidCallback? get debugToolbarCallback => _client?.showToolbar;

  /// Captures the current adapter's epoch-bound floating-cursor callback.
  @visibleForTesting
  ValueChanged<RawFloatingCursorPoint>? get debugFloatingCursorCallback =>
      _client?.updateFloatingCursor;

  /// Captures the current adapter's epoch-bound autocorrection callback.
  @visibleForTesting
  void Function(int start, int end)? get debugAutocorrectionPromptCallback =>
      _client?.showAutocorrectionPromptRect;

  /// Opens platform input for [blockId], or reuses its live connection.
  ///
  /// A valid canonical selection is sufficient; layout geometry may arrive
  /// later through [publishGeometry]. [geometryOwner] may identify a host that
  /// does not install a [commandDelegate]; without either owner, geometry
  /// publication stays disabled rather than accepting an ambiguous callback.
  bool attach({
    required String blockId,
    HomericTextInputCommandDelegate? commandDelegate,
    Object? geometryOwner,
  }) {
    final resolvedGeometryOwner = geometryOwner ?? commandDelegate;
    if (_disposed ||
        controller.isReadOnly ||
        controller.activeBlockId != blockId ||
        controller.document.indexOfBlockId(blockId) == null) {
      return false;
    }
    if (isAttached &&
        _blockId == blockId &&
        identical(_commandDelegate, commandDelegate) &&
        identical(_geometryOwner, resolvedGeometryOwner)) {
      return true;
    }

    _close(CompositionInterruption.activeBlockSwitch, notify: false);
    final value = _canonicalValue(blockId);
    if (value == null) return false;

    final epoch = ++_nextEpoch;
    final client = _EpochTextInputClient(this, epoch);
    final connection = TextInput.attach(client, _configuration);
    _currentEpoch = epoch;
    _client = client;
    _connection = connection;
    _blockId = blockId;
    _commandDelegate = commandDelegate;
    _geometryOwner = resolvedGeometryOwner;
    _shadowValue = value;
    _geometryGeneration = null;
    _geometryLease = resolvedGeometryOwner == null
        ? null
        : HomericTextInputGeometryLease._();
    connection.setEditingState(value);
    connection.show();
    notifyListeners();
    return true;
  }

  /// Temporarily ignores platform deltas while a document gesture moves the
  /// logical head across blocks.
  void suspendDeltas() {
    if (_disposed) return;
    _deltasSuspended = true;
  }

  /// Resumes platform delta acceptance after the document host retargets.
  void resumeDeltas() {
    if (_disposed) return;
    _deltasSuspended = false;
  }

  /// Retargets the live platform capability without closing its connection.
  ///
  /// The platform receives a fresh block-local canonical value while the
  /// connection/client epoch remains intact. Host command callbacks are
  /// replaced atomically with [commandDelegate].
  bool retarget({
    required String blockId,
    HomericTextInputCommandDelegate? commandDelegate,
    Object? geometryOwner,
  }) {
    final resolvedGeometryOwner = geometryOwner ?? commandDelegate;
    if (_disposed ||
        controller.isReadOnly ||
        controller.activeBlockId != blockId) {
      return false;
    }
    if (!isAttached) {
      return attach(
        blockId: blockId,
        commandDelegate: commandDelegate,
        geometryOwner: geometryOwner,
      );
    }
    final value = _canonicalValue(blockId);
    if (value == null) return false;
    final blockChanged = _blockId != blockId;
    final hostChanged = !identical(_commandDelegate, commandDelegate) ||
        !identical(_geometryOwner, resolvedGeometryOwner);
    _blockId = blockId;
    _commandDelegate = commandDelegate;
    _geometryOwner = resolvedGeometryOwner;
    _shadowValue = value;
    _geometryGeneration = null;
    if (blockChanged || hostChanged) {
      _geometryLease = resolvedGeometryOwner == null
          ? null
          : HomericTextInputGeometryLease._();
    }
    _connection!.setEditingState(value);
    // Reassert the platform first responder as well as the canonical value.
    // AppKit may release it while a selector-triggered structural edit moves
    // the active row even though Flutter retains the same FocusNode.
    _connection!.show();
    if (blockChanged || hostChanged) notifyListeners();
    return true;
  }

  /// Ends focus ownership while preserving the controller's logical selection.
  void blur() => _close(CompositionInterruption.blur);

  /// Publishes current-layout platform geometry for the connected block.
  ///
  /// [lease] is the opaque attachment witness captured with the geometry. A
  /// recycled row or replaced same-block host therefore cannot position the
  /// current platform caret or IME candidate window.
  ///
  /// [documentRevision] is an identity witness: geometry from any prior
  /// immutable [Document] is rejected. A regressing [layoutGeneration] is also
  /// rejected, allowing the host to race layout safely without pausing input.
  bool publishGeometry({
    required HomericTextInputGeometryLease lease,
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
        !identical(_geometryLease, lease) ||
        controller.activeBlockId != _blockId ||
        controller.isReadOnly ||
        !identical(documentRevision, controller.document) ||
        (_geometryGeneration != null &&
            layoutGeneration < _geometryGeneration!)) {
      return false;
    }
    _geometryGeneration = layoutGeneration;
    connection.setEditableSizeAndTransform(editableSize, transform);
    connection.setCaretRect(caretRect);
    connection.setComposingRect(composingRect ?? Rect.zero);
    return true;
  }

  void _controllerChanged() {
    if (_disposed || _applyingRemote || _deltasSuspended || !isAttached) {
      return;
    }
    if (controller.isReadOnly) {
      _close(CompositionInterruption.platformClose);
      return;
    }
    if (controller.activeBlockId != _blockId) {
      final epoch = _currentEpoch;
      scheduleMicrotask(() {
        if (!_disposed &&
            epoch == _currentEpoch &&
            isAttached &&
            controller.activeBlockId != _blockId) {
          _close(CompositionInterruption.activeBlockSwitch);
        }
      });
      return;
    }
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
      if (controller.activeBlockId != blockId) return null;
      final resolvedHead = controller.document.resolve(selection.head);
      if (resolvedHead is! InlinePosition || resolvedHead.block.id != blockId) {
        return null;
      }
      anchor = resolvedHead.offset;
      head = resolvedHead.offset;
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
    if (_deltasSuspended) return;
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
    if (_selectionSpansBlocks(blockId)) {
      _applyDocumentSelectionDelta(
        initial: initial,
        shadow: shadow,
      );
      return;
    }
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

  bool _selectionSpansBlocks(String blockId) {
    final selection = controller.selection;
    if (selection == null) return false;
    try {
      controller.blockOffsetForGlobalPosition(blockId, selection.anchor);
      controller.blockOffsetForGlobalPosition(blockId, selection.head);
      return false;
    } on ArgumentError {
      return controller.activeBlockId == blockId;
    }
  }

  void _applyDocumentSelectionDelta({
    required TextEditingValue initial,
    required TextEditingValue shadow,
  }) {
    final edit = _singleEdit(initial.text, shadow.text);
    final insertionOffset = initial.selection.extentOffset;
    if (edit == null ||
        edit.start != insertionOffset ||
        edit.end != insertionOffset ||
        shadow.selection.baseOffset < insertionOffset ||
        shadow.selection.extentOffset < insertionOffset ||
        (shadow.composing.isValid &&
            (shadow.composing.start < insertionOffset ||
                shadow.composing.end < insertionOffset))) {
      _syncCanonical(force: true);
      return;
    }
    final localSelection = BlockTextSelection(
      anchor: shadow.selection.baseOffset - insertionOffset,
      head: shadow.selection.extentOffset - insertionOffset,
      affinity: shadow.selection.affinity == TextAffinity.upstream
          ? HomericCaretAffinity.upstream
          : HomericCaretAffinity.downstream,
    );
    final localComposing =
        shadow.composing.isValid && !shadow.composing.isCollapsed
            ? BlockTextRange(
                shadow.composing.start - insertionOffset,
                shadow.composing.end - insertionOffset,
              )
            : null;
    _applyingRemote = true;
    late final bool changed;
    try {
      changed = controller.applyDocumentSelectionTextInput(
        text: edit.text,
        selection: localSelection,
        composing: localComposing,
      );
    } finally {
      _applyingRemote = false;
    }
    final survivorId = controller.activeBlockId;
    if (!changed || survivorId == null) {
      _syncCanonical(force: true);
      return;
    }
    final canonical = _canonicalValue(survivorId);
    if (canonical == null) {
      _close(CompositionInterruption.activeBlockSwitch);
      return;
    }
    if (_blockId == survivorId &&
        _sameCanonicalValue(_shadowValue, canonical)) {
      return;
    }
    final blockChanged = _blockId != survivorId;
    _blockId = survivorId;
    if (blockChanged) {
      _commandDelegate = null;
      _geometryOwner = null;
      _geometryLease = null;
    }
    _shadowValue = canonical;
    _geometryGeneration = null;
    _connection?.setEditingState(canonical);
    if (blockChanged) notifyListeners();
  }

  void _legacyUpdate(int epoch, TextEditingValue value) {
    _resyncIfCurrent(epoch);
  }

  void _performAction(int epoch, TextInputAction action) {
    if (epoch != _currentEpoch || _disposed) return;
    if (action == TextInputAction.newline &&
        controller.composing == null &&
        _commandDelegate?.invoke(
              const HomericInsertParagraphBreakIntent(),
            ) ==
            true) {
      _syncCanonical(force: true);
      return;
    }
    _syncCanonical(force: true);
  }

  /// Suppresses the one AppKit selector that may follow a handled shortcut.
  void suppressNextSelector(String selectorName) {
    if (_disposed) return;
    _suppressedSelector = selectorName;
    _suppressedSelectorTimer?.cancel();
    _suppressedSelectorTimer = Timer(const Duration(milliseconds: 100), () {
      _suppressedSelector = null;
      _suppressedSelectorTimer = null;
    });
  }

  bool _consumeSuppressedSelector(String selectorName) {
    final suppressed = _suppressedSelector;
    if (suppressed != selectorName) return false;
    _suppressedSelector = null;
    _suppressedSelectorTimer?.cancel();
    _suppressedSelectorTimer = null;
    return true;
  }

  void _resyncIfCurrent(int epoch) {
    if (epoch != _currentEpoch || _disposed) return;
    _syncCanonical(force: true);
  }

  void _platformClosed(int epoch) {
    if (_disposed || epoch != _currentEpoch) return;
    _commandDelegate?.cancelTransientInput();
    _invalidateEpoch();
    _connection?.connectionClosedReceived();
    _connection = null;
    _client = null;
    _blockId = null;
    _shadowValue = null;
    _geometryGeneration = null;
    _geometryLease = null;
    _geometryOwner = null;
    _commandDelegate = null;
    controller.interruptComposition(CompositionInterruption.platformClose);
    notifyListeners();
  }

  void _close(
    CompositionInterruption interruption, {
    bool notify = true,
  }) {
    final connection = _connection;
    final hadAttachment =
        _currentEpoch != null || _blockId != null || connection != null;
    _commandDelegate?.cancelTransientInput();
    _invalidateEpoch();
    _connection = null;
    _client = null;
    _blockId = null;
    _shadowValue = null;
    _geometryGeneration = null;
    _geometryLease = null;
    _geometryOwner = null;
    _commandDelegate = null;
    _deltasSuspended = false;
    _suppressedSelector = null;
    _suppressedSelectorTimer?.cancel();
    _suppressedSelectorTimer = null;
    controller.interruptComposition(interruption);
    connection?.close();
    if (notify && hadAttachment) notifyListeners();
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
    if (start > 0 &&
        start < before.length &&
        _isHighSurrogate(before.codeUnitAt(start - 1)) &&
        _isLowSurrogate(before.codeUnitAt(start))) {
      start--;
    }
    var beforeEnd = before.length;
    var afterEnd = after.length;
    while (beforeEnd > start &&
        afterEnd > start &&
        before.codeUnitAt(beforeEnd - 1) == after.codeUnitAt(afterEnd - 1)) {
      beforeEnd--;
      afterEnd--;
    }
    if (beforeEnd > start &&
        beforeEnd < before.length &&
        afterEnd < after.length &&
        _isHighSurrogate(before.codeUnitAt(beforeEnd - 1)) &&
        _isLowSurrogate(before.codeUnitAt(beforeEnd))) {
      beforeEnd++;
      afterEnd++;
    }
    return CanonicalTextEdit(
        start, beforeEnd, after.substring(start, afterEnd));
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  /// Invalidates and closes the live connection exactly once.
  @override
  void dispose() {
    if (_disposed) return;
    controller.removeListener(_controllerChanged);
    _suppressedSelectorTimer?.cancel();
    _close(CompositionInterruption.disposal, notify: false);
    _disposed = true;
    super.dispose();
  }
}

final class _EpochTextInputClient with DeltaTextInputClient {
  _EpochTextInputClient(this.session, this.epoch);

  final HomericTextInputSession session;
  final int epoch;

  /// Stable test capability whose identity changes only with the client epoch.
  late final ValueChanged<List<TextEditingDelta>> debugDeltaCallback =
      updateEditingValueWithDeltas;

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
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    if (epoch != session._currentEpoch || session._disposed) return;
    session._commandDelegate?.updateFloatingCursor(point);
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    final value = session._shadowValue;
    if (epoch != session._currentEpoch ||
        session._disposed ||
        value == null ||
        start < 0 ||
        end <= start ||
        end > value.text.length) {
      return;
    }
    session._commandDelegate?.showAutocorrectionPromptRect(
      TextRange(start: start, end: end),
    );
  }

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
  void showToolbar() {
    if (epoch != session._currentEpoch || session._disposed) return;
    session._commandDelegate?.showToolbar();
  }

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void performSelector(String selectorName) {
    if (epoch != session._currentEpoch || session._disposed) return;
    if (session._consumeSuppressedSelector(selectorName)) return;
    final intent = intentForMacOSSelector(selectorName);
    if (intent != null) session._commandDelegate?.invoke(intent);
  }
}
