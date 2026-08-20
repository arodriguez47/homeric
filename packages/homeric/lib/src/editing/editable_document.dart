/// Experimental document-owned editing coordination.
library;

import 'package:flutter/widgets.dart';

import '../input/text_input_session.dart';
import 'editor_controller.dart';

/// Coordinates one canonical controller and one platform input session.
///
/// This first-stage shell intentionally owns no scrolling or row-height policy;
/// it establishes the document-level input capability that the virtualized
/// viewport builds on.
class HomericEditableDocument extends StatefulWidget {
  const HomericEditableDocument({
    super.key,
    required this.controller,
    required this.inputSession,
    required this.child,
  });

  final HomericEditorController controller;
  final HomericTextInputSession inputSession;
  final Widget child;

  /// Returns the nearest document editing coordinator, if present.
  static HomericEditableDocumentState? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_HomericEditableDocumentScope>()
      ?.state;

  @override
  State<HomericEditableDocument> createState() =>
      HomericEditableDocumentState();
}

class HomericEditableDocumentState extends State<HomericEditableDocument> {
  bool _selectionDragActive = false;
  final Map<String, HomericTextInputCommandDelegate> _commandHosts = {};

  @override
  void initState() {
    super.initState();
    _validateSession();
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(HomericEditableDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    _validateSession();
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
    }
    if (!identical(oldWidget.inputSession, widget.inputSession)) {
      oldWidget.inputSession.resumeDeltas();
      if (_selectionDragActive) widget.inputSession.suspendDeltas();
    }
  }

  /// Suspends platform deltas while a document-global drag moves its head.
  void beginSelectionDrag() {
    if (_selectionDragActive) return;
    _selectionDragActive = true;
    widget.inputSession.suspendDeltas();
  }

  /// Retargets once to the final selection head and resumes platform input.
  bool endSelectionDrag() {
    if (!_selectionDragActive) return false;
    _selectionDragActive = false;
    final retargeted = _retargetActiveHost();
    widget.inputSession.resumeDeltas();
    return retargeted;
  }

  /// Registers the current mounted command capability for [blockId].
  void registerCommandHost(
    String blockId,
    HomericTextInputCommandDelegate delegate,
  ) {
    _commandHosts[blockId] = delegate;
  }

  /// Removes [delegate] only when it is still the current host capability.
  void unregisterCommandHost(
    String blockId,
    HomericTextInputCommandDelegate delegate,
  ) {
    if (identical(_commandHosts[blockId], delegate)) {
      _commandHosts.remove(blockId);
    }
  }

  /// Attaches platform input through the document-owned host capability.
  bool attachCommandHost(
    String blockId,
    HomericTextInputCommandDelegate delegate,
  ) {
    registerCommandHost(blockId, delegate);
    return widget.inputSession.attach(
      blockId: blockId,
      commandDelegate: delegate,
    );
  }

  void _controllerChanged() {
    if (_selectionDragActive || !widget.inputSession.isAttached) return;
    final activeBlockId = widget.controller.activeBlockId;
    if (activeBlockId == widget.inputSession.activeBlockId) return;
    if (activeBlockId == null ||
        widget.controller.document.indexOfBlockId(activeBlockId) == null) {
      widget.inputSession.blur();
      return;
    }
    _retargetActiveHost();
  }

  bool _retargetActiveHost() {
    final blockId = widget.controller.activeBlockId;
    if (blockId == null) return false;
    final delegate = _commandHosts[blockId];
    if (delegate == null) return false;
    return widget.inputSession.retarget(
      blockId: blockId,
      commandDelegate: delegate,
    );
  }

  void _validateSession() {
    if (!identical(widget.controller, widget.inputSession.controller)) {
      throw ArgumentError('inputSession must observe controller');
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    if (_selectionDragActive) widget.inputSession.resumeDeltas();
    _commandHosts.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _HomericEditableDocumentScope(
        state: this,
        child: widget.child,
      );
}

class _HomericEditableDocumentScope extends InheritedWidget {
  const _HomericEditableDocumentScope({
    required this.state,
    required super.child,
  });

  final HomericEditableDocumentState state;

  @override
  bool updateShouldNotify(_HomericEditableDocumentScope oldWidget) =>
      !identical(state, oldWidget.state);
}
