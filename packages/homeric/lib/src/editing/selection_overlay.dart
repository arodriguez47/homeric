/// Internal platform touch-selection chrome shared by editable hosts.
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/widgets.dart';

/// One current canonical selection endpoint projected into Flutter geometry.
@internal
final class HomericSelectionOverlayEndpoint {
  const HomericSelectionOverlayEndpoint({
    required this.globalRect,
    required this.layerLink,
    required this.textDirection,
  });

  final Rect globalRect;
  final LayerLink layerLink;
  final TextDirection textDirection;
}

/// Owns only Flutter's transient selection chrome, never canonical state.
@internal
final class HomericSelectionOverlayCoordinator {
  final LayerLink _unlinkedStartLayerLink = LayerLink();
  final LayerLink _unlinkedEndLayerLink = LayerLink();
  final ValueNotifier<bool> _startHandleVisible = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _endHandleVisible = ValueNotifier<bool>(false);
  SelectionOverlay? _overlay;
  LayerLink? _startLayerLink;
  LayerLink? _endLayerLink;
  TextSelectionControls? _controls;
  TextMagnifierConfiguration? _magnifierConfiguration;

  bool get visible => _overlay != null;
  bool get startHandleVisible => _startHandleVisible.value;
  bool get endHandleVisible => _endHandleVisible.value;

  void sync({
    required BuildContext context,
    required Widget debugRequiredFor,
    required TextSelectionControls controls,
    required TextMagnifierConfiguration magnifierConfiguration,
    required LayerLink toolbarLayerLink,
    required bool collapsed,
    required HomericSelectionOverlayEndpoint? start,
    required HomericSelectionOverlayEndpoint? end,
    required VoidCallback onSelectionHandleTapped,
  }) {
    if ((start == null && end == null) ||
        Overlay.maybeOf(context, rootOverlay: true) == null) {
      hide();
      return;
    }
    final startLink = start?.layerLink ?? _unlinkedStartLayerLink;
    final endLink = end?.layerLink ?? _unlinkedEndLayerLink;
    final recreate = _overlay == null ||
        !identical(_startLayerLink, startLink) ||
        !identical(_endLayerLink, endLink) ||
        !identical(_controls, controls) ||
        !identical(_magnifierConfiguration, magnifierConfiguration);
    if (recreate) {
      hide();
      _startLayerLink = startLink;
      _endLayerLink = endLink;
      _controls = controls;
      _magnifierConfiguration = magnifierConfiguration;
      // The host's intent-backed context menu remains the mutation route.
      // ignore: deprecated_member_use
      _overlay = SelectionOverlay(
        context: context,
        debugRequiredFor: debugRequiredFor,
        startHandleType: _handleType(
          start: true,
          collapsed: collapsed,
          direction:
              start?.textDirection ?? end?.textDirection ?? TextDirection.ltr,
        ),
        lineHeightAtStart:
            start?.globalRect.height ?? end?.globalRect.height ?? 1,
        startHandlesVisible: _startHandleVisible,
        endHandleType: _handleType(
          start: false,
          collapsed: collapsed,
          direction:
              end?.textDirection ?? start?.textDirection ?? TextDirection.ltr,
        ),
        lineHeightAtEnd:
            end?.globalRect.height ?? start?.globalRect.height ?? 1,
        endHandlesVisible: _endHandleVisible,
        selectionEndpoints: _selectionPoints(start, end),
        selectionControls: controls,
        selectionDelegate: null,
        clipboardStatus: null,
        startHandleLayerLink: startLink,
        endHandleLayerLink: endLink,
        toolbarLayerLink: toolbarLayerLink,
        onSelectionHandleTapped: onSelectionHandleTapped,
        magnifierConfiguration: magnifierConfiguration,
      )..showHandles();
    } else {
      _overlay!
        ..startHandleType = _handleType(
          start: true,
          collapsed: collapsed,
          direction:
              start?.textDirection ?? end?.textDirection ?? TextDirection.ltr,
        )
        ..lineHeightAtStart =
            start?.globalRect.height ?? end?.globalRect.height ?? 1
        ..endHandleType = _handleType(
          start: false,
          collapsed: collapsed,
          direction:
              end?.textDirection ?? start?.textDirection ?? TextDirection.ltr,
        )
        ..lineHeightAtEnd =
            end?.globalRect.height ?? start?.globalRect.height ?? 1
        ..selectionEndpoints = _selectionPoints(start, end);
    }
    _startHandleVisible.value = start != null;
    _endHandleVisible.value = end != null && !collapsed;
  }

  void hide() {
    _overlay?.dispose();
    _overlay = null;
    _startLayerLink = null;
    _endLayerLink = null;
    _controls = null;
    _magnifierConfiguration = null;
    _startHandleVisible.value = false;
    _endHandleVisible.value = false;
  }

  void dispose() {
    hide();
    _startHandleVisible.dispose();
    _endHandleVisible.dispose();
  }

  static TextSelectionHandleType _handleType({
    required bool start,
    required bool collapsed,
    required TextDirection direction,
  }) {
    if (collapsed) return TextSelectionHandleType.collapsed;
    return switch ((start, direction)) {
      (true, TextDirection.ltr) ||
      (false, TextDirection.rtl) =>
        TextSelectionHandleType.left,
      _ => TextSelectionHandleType.right,
    };
  }

  static List<TextSelectionPoint> _selectionPoints(
    HomericSelectionOverlayEndpoint? start,
    HomericSelectionOverlayEndpoint? end,
  ) =>
      <TextSelectionPoint>[
        TextSelectionPoint(
          start?.globalRect.bottomLeft ?? Offset.zero,
          start?.textDirection ?? end?.textDirection ?? TextDirection.ltr,
        ),
        TextSelectionPoint(
          end?.globalRect.bottomRight ?? Offset.zero,
          end?.textDirection ?? start?.textDirection ?? TextDirection.ltr,
        ),
      ];
}
