/// Writing features: opt-in editing behaviour a host switches on per app.
///
/// A feature is a plugin over the controller's public seams (command
/// interceptors today; decorations, slots and key bindings as features that
/// need them arrive). The core never imports this module, so an app that
/// installs nothing gets exactly the editor it had.
library;

import 'package:flutter/foundation.dart';

import '../editing/editable_document.dart';
import '../editing/editor_controller.dart';

/// One writing feature, installed on a controller.
abstract base class HomericWritingFeature {
  /// Const constructor so features can be configured as const values.
  const HomericWritingFeature();

  /// Stable name, unique within a [HomericWritingKit] (`smartPunctuation`).
  String get id;

  /// Starts the feature on [controller]; returns the callback that stops it.
  VoidCallback installOn(HomericEditorController controller);

  /// Shortcuts the feature adds to the document, passed to
  /// `HomericEditableDocument(commandBindings:)` through
  /// [HomericWritingKit.commandBindings]. Most features add none.
  List<HomericDocumentCommandBinding> get commandBindings =>
      const <HomericDocumentCommandBinding>[];
}

/// A [VoidCallback] that does nothing, for features with nothing to stop.
void homericWritingNoop() {}
