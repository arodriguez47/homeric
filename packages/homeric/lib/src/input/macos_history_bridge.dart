/// Publishes Homeric undo/redo availability to a macOS Edit-menu host.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../editing/editor_controller.dart';
import 'text_input_session.dart';

/// Well-known channel name for macOS Edit-menu undo/redo routing.
const String kHomericMacOSHistoryChannel = 'homeric/macos_history';

/// Mirrors [HomericEditorController] history enablement into a macOS host and
/// accepts Edit-menu undo/redo invocations.
///
/// The host AppDelegate (or equivalent) owns `validateMenuItem` / `undo:` /
/// `redo:` and talks to this bridge over [kHomericMacOSHistoryChannel]. Dart
/// publishes `{canUndo, canRedo}`; native calls `undo` / `redo`, which route
/// through the live [HomericTextInputSession] command delegate so superseded
/// hosts stay inert.
final class HomericMacOSHistoryBridge {
  /// Creates a bridge over [controller] and its shared [session].
  HomericMacOSHistoryBridge({
    required this.controller,
    required this.session,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(kHomericMacOSHistoryChannel);

  /// Canonical editor history owner.
  final HomericEditorController controller;

  /// Epoch-bound platform command boundary used for menu invocations.
  final HomericTextInputSession session;

  final MethodChannel _channel;
  bool _attached = false;
  bool _lastCanUndo = false;
  bool _lastCanRedo = false;

  /// Whether [attach] is currently active.
  bool get isAttached => _attached;

  /// Last undo enablement published to the host.
  @visibleForTesting
  bool get debugPublishedCanUndo => _lastCanUndo;

  /// Last redo enablement published to the host.
  @visibleForTesting
  bool get debugPublishedCanRedo => _lastCanRedo;

  /// Starts publishing history state and handling host undo/redo calls.
  void attach() {
    if (_attached) return;
    _attached = true;
    controller.addListener(_onControllerChanged);
    _channel.setMethodCallHandler(_onMethodCall);
    _publishState(force: true);
  }

  /// Stops publishing and clears the host method handler.
  void detach() {
    if (!_attached) return;
    _attached = false;
    controller.removeListener(_onControllerChanged);
    _channel.setMethodCallHandler(null);
    _lastCanUndo = false;
    _lastCanRedo = false;
    unawaited(
      _channel.invokeMethod<void>('setUndoState', <String, bool>{
        'canUndo': false,
        'canRedo': false,
      }).catchError((Object _) {}),
    );
  }

  void _onControllerChanged() => _publishState();

  void _publishState({bool force = false}) {
    if (!_attached) return;
    final canUndo = !controller.isReadOnly && controller.canUndo;
    final canRedo = !controller.isReadOnly && controller.canRedo;
    if (!force && canUndo == _lastCanUndo && canRedo == _lastCanRedo) {
      return;
    }
    _lastCanUndo = canUndo;
    _lastCanRedo = canRedo;
    unawaited(
      _channel.invokeMethod<void>('setUndoState', <String, bool>{
        'canUndo': canUndo,
        'canRedo': canRedo,
      }).catchError((Object _) {}),
    );
  }

  Future<Object?> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'undo':
        return session.invokeCommand(
          const UndoTextIntent(SelectionChangedCause.toolbar),
        );
      case 'redo':
        return session.invokeCommand(
          const RedoTextIntent(SelectionChangedCause.toolbar),
        );
      default:
        throw MissingPluginException(
          'No Homeric macOS history handler for ${call.method}',
        );
    }
  }
}
