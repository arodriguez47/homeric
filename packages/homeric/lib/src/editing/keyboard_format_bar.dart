/// The format bar over the touch keyboard: the focused editor's format
/// buttons in a row pinned above the keys, as an iOS input accessory sits,
/// with a key at the end that puts the keyboard away.
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../model/position.dart';
import '../model/selection.dart';
import 'editable_document.dart';
import 'editor_controller.dart';

/// Whether [HomericKeyboardFormatBar] shows on this platform when nothing
/// says otherwise: the phones and tablets, whose keyboards have no ⌘B.
bool homericUsesKeyboardFormatBar() => switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.android => true,
      _ => false,
    };

/// Shows the focused editor's format bar above the touch keyboard.
///
/// Wrap the app once, above its Navigator (`MaterialApp.builder`). While a
/// paragraph of a [HomericEditableDocument] holds the focus and the keyboard
/// is up, the document's [HomericEditableDocument.selectionFormatBarBuilder]
/// buttons sit in a row on top of the keys. The row counts as part of the
/// keyboard: [child] sees it in `MediaQuery.viewInsets`, so pages make room
/// for it as they do for the keys.
///
/// With only a caret, the buttons act on the word around it and leave the
/// caret where it was, inside the new marks; in a space they are disabled.
class HomericKeyboardFormatBar extends StatefulWidget {
  const HomericKeyboardFormatBar({
    super.key,
    required this.child,
    this.enabled,
  });

  final Widget child;

  /// Whether the bar may show at all; null shows it on iOS and Android
  /// ([homericUsesKeyboardFormatBar]).
  final bool? enabled;

  /// The row's height, which [child] sees added to the keyboard's.
  static const double height = 44;

  @override
  State<HomericKeyboardFormatBar> createState() =>
      _HomericKeyboardFormatBarState();
}

class _HomericKeyboardFormatBarState extends State<HomericKeyboardFormatBar> {
  HomericEditableDocumentState? _document;
  HomericEditorController? _controller;

  bool get _enabled => widget.enabled ?? homericUsesKeyboardFormatBar();

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    _focusChanged();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    _controller?.removeListener(_changed);
    super.dispose();
  }

  void _focusChanged() {
    final document = HomericEditableDocument.ofPrimaryFocus();
    final controller = document?.widget.controller;
    if (!identical(controller, _controller)) {
      _controller?.removeListener(_changed);
      controller?.addListener(_changed);
      _controller = controller;
    }
    if (!identical(document, _document)) {
      _document = document;
      _changed();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final actions =
        _enabled && keyboard > 0 ? _actions() : const <HomericFormatAction>[];
    final shown = actions.isNotEmpty;
    return Stack(
      alignment: Alignment.topLeft,
      fit: StackFit.passthrough,
      children: <Widget>[
        MediaQuery(
          data: shown
              ? media.copyWith(
                  viewInsets: media.viewInsets.copyWith(
                    bottom: keyboard + HomericKeyboardFormatBar.height,
                  ),
                )
              : media,
          child: widget.child,
        ),
        if (shown)
          Positioned(
            left: 0,
            right: 0,
            bottom: keyboard,
            child: _KeyboardBar(actions: actions),
          ),
      ],
    );
  }

  /// The document's buttons for its selection, or for the word at its
  /// caret, each first selecting what it acts on.
  List<HomericFormatAction> _actions() {
    final document = _document;
    final controller = _controller;
    if (document == null ||
        controller == null ||
        !document.mounted ||
        controller.isReadOnly ||
        !document.hasEditingFocus) {
      return const <HomericFormatAction>[];
    }
    final builder = document.selectionFormatBarBuilder;
    final selection = controller.selection;
    if (builder == null || selection == null) {
      return const <HomericFormatAction>[];
    }
    final word = selection.isCollapsed ? _wordAt(controller, selection) : null;
    final target = word ?? selection;
    final head = controller.document.resolve(target.head);
    if (head is! InlinePosition) return const <HomericFormatAction>[];
    final blockId = head.block.id;
    final BlockTextSelection blockSelection;
    if (word != null || selection.isCollapsed) {
      final anchor = controller.document.resolve(target.anchor);
      if (anchor is! InlinePosition) return const <HomericFormatAction>[];
      blockSelection =
          BlockTextSelection(anchor: anchor.offset, head: head.offset);
    } else {
      final fragment = document.selectionFragmentForBlock(blockId);
      if (fragment == null) return const <HomericFormatAction>[];
      blockSelection = fragment;
    }
    return <HomericFormatAction>[
      for (final action in builder(target, blockId, blockSelection))
        if (action.onPressed case final onPressed?)
          action.copyWith(
            onPressed: () => _press(controller, selection, word, onPressed),
          )
        else
          action,
    ];
  }

  void _press(
    HomericEditorController controller,
    HomericSelection selection,
    HomericSelection? word,
    VoidCallback onPressed,
  ) {
    if (controller.selection != selection) return;
    if (word == null) {
      onPressed();
      return;
    }
    controller.setSelection(word);
    onPressed();
    // Marks put round the word leave the word selected, and the next key
    // would replace it: back to the caret, at the same place in the word.
    // A button that went on to something else (a link menu, a note) has
    // moved the selection or the focus, and keeps it.
    final after = controller.selection;
    final wordLength = word.end - word.start;
    if (after != null &&
        !after.isCollapsed &&
        after.end - after.start == wordLength &&
        _document?.hasEditingFocus == true) {
      final into = (selection.head - word.start).clamp(0, wordLength);
      controller.setSelection(HomericSelection.collapsed(after.start + into));
    }
  }

  /// The word around a caret, as the selection a button acts on; null in a
  /// space or between marks.
  static HomericSelection? _wordAt(
    HomericEditorController controller,
    HomericSelection caret,
  ) {
    final position = controller.document.resolve(caret.head);
    if (position is! InlinePosition) return null;
    final text = position.block.text;
    var start = position.offset.clamp(0, text.length);
    var end = start;
    while (start > 0 && _isWordUnit(text.codeUnitAt(start - 1))) {
      start--;
    }
    while (end < text.length && _isWordUnit(text.codeUnitAt(end))) {
      end++;
    }
    // Apostrophes join a word's letters; they don't start or end one.
    while (start < end && _isApostrophe(text.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _isApostrophe(text.codeUnitAt(end - 1))) {
      end--;
    }
    if (start == end) return null;
    final base = caret.head - position.offset;
    return HomericSelection(anchor: base + start, head: base + end);
  }

  static final RegExp _letter = RegExp(r'[\p{L}\p{M}\p{N}]', unicode: true);

  static bool _isApostrophe(int unit) => unit == 0x27 || unit == 0x2019;

  static bool _isWordUnit(int unit) =>
      _isApostrophe(unit) ||
      // Either half of a surrogate pair: letters beyond the basic plane.
      (unit >= 0xD800 && unit <= 0xDFFF) ||
      _letter.hasMatch(String.fromCharCode(unit));
}

/// The row itself: the buttons, then the key that puts the keyboard away.
class _KeyboardBar extends StatelessWidget {
  const _KeyboardBar({required this.actions});

  final List<HomericFormatAction> actions;

  static const double _hideKey = 48;
  static const double _minButton = 36;
  static const double _maxButton = 48;

  @override
  Widget build(BuildContext context) {
    final palette = _BarPalette.of(context);
    final sides = MediaQuery.paddingOf(context);
    return TextFieldTapRegion(
      child: Container(
        key: const ValueKey<String>('homeric-keyboard-format-bar'),
        height: HomericKeyboardFormatBar.height,
        padding: EdgeInsets.only(left: sides.left, right: sides.right),
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border(top: BorderSide(color: palette.edge, width: 0.5)),
        ),
        child: LayoutBuilder(builder: (context, constraints) {
          final room = constraints.maxWidth - _hideKey - 8;
          final rules = actions.skip(1).where((a) => a.startsGroup).length;
          final width = ((room - rules * 9) / actions.length)
              .clamp(_minButton, _maxButton);
          final buttons = <Widget>[];
          for (var index = 0; index < actions.length; index++) {
            final action = actions[index];
            if (index > 0 && action.startsGroup) {
              buttons.add(Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: 0.5,
                  height: 20,
                  child: ColoredBox(color: palette.edge),
                ),
              ));
            }
            buttons.add(_BarButton(
              action: action,
              width: width.toDouble(),
              palette: palette,
            ));
          }
          return Row(
            children: <Widget>[
              const SizedBox(width: 4),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: buttons),
                ),
              ),
              SizedBox(
                width: 0.5,
                height: HomericKeyboardFormatBar.height,
                child: ColoredBox(color: palette.edge),
              ),
              _BarKey(
                key: const ValueKey<String>('homeric-keyboard-hide'),
                width: _hideKey - 0.5,
                label: 'Hide keyboard',
                palette: palette,
                onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: Icon(
                  Icons.keyboard_hide_outlined,
                  size: 21,
                  color: palette.ink,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.action,
    required this.width,
    required this.palette,
  });

  final HomericFormatAction action;
  final double width;
  final _BarPalette palette;

  @override
  Widget build(BuildContext context) {
    final enabled = action.onPressed != null;
    final active = action.isActive && enabled;
    return _BarKey(
      key: ValueKey<String>('homeric-keyboard-format-${action.label}'),
      width: width,
      label: action.isActive
          ? 'Remove ${action.label.toLowerCase()}'
          : action.label,
      selected: action.isActive,
      palette: palette,
      onPressed: action.onPressed,
      child: Container(
        width: 34,
        height: 32,
        decoration: BoxDecoration(
          color: active
              ? palette.accent.withValues(alpha: 0.14)
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          action.icon,
          size: 19,
          color: !enabled
              ? palette.ink.withValues(alpha: 0.3)
              : active
                  ? palette.accent
                  : palette.ink,
        ),
      ),
    );
  }
}

/// A press target on the bar that never takes the focus, so the keyboard
/// stays up; it shades while a finger is on it.
class _BarKey extends StatefulWidget {
  const _BarKey({
    super.key,
    required this.width,
    required this.label,
    required this.palette,
    required this.onPressed,
    required this.child,
    this.selected,
  });

  final double width;
  final String label;
  final _BarPalette palette;
  final VoidCallback? onPressed;
  final Widget child;
  final bool? selected;

  @override
  State<_BarKey> createState() => _BarKeyState();
}

class _BarKeyState extends State<_BarKey> {
  bool _down = false;

  void _setDown(bool value) {
    if (_down != value) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      // The detector's own tap is excluded with the icon below, so the
      // node itself is what VoiceOver and TalkBack activate.
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setDown(true) : null,
        onTapCancel: () => _setDown(false),
        onTapUp: (_) => _setDown(false),
        onTap: widget.onPressed,
        child: SizedBox(
          width: widget.width,
          height: HomericKeyboardFormatBar.height,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _down ? widget.palette.pressed : const Color(0x00000000),
                borderRadius: BorderRadius.circular(8),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar's colours, from the app's theme: a shade off the page, its
/// icons at half ink like the apps' other toolbars.
@immutable
final class _BarPalette {
  const _BarPalette({
    required this.surface,
    required this.ink,
    required this.edge,
    required this.pressed,
    required this.accent,
  });

  factory _BarPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final onSurface = scheme.onSurface;
    return _BarPalette(
      surface: dark
          ? Color.alphaBlend(
              Colors.white.withValues(alpha: 0.07), scheme.surface)
          : Color.alphaBlend(
              Colors.black.withValues(alpha: 0.035), scheme.surface),
      ink: onSurface.withValues(alpha: 0.5),
      edge: onSurface.withValues(alpha: dark ? 0.16 : 0.12),
      pressed: onSurface.withValues(alpha: dark ? 0.12 : 0.08),
      accent: scheme.primary,
    );
  }

  final Color surface;
  final Color ink;
  final Color edge;
  final Color pressed;
  final Color accent;
}
