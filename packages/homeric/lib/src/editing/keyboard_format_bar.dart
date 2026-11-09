/// The format bar over the touch keyboard: the focused editor's format
/// buttons in a row pinned above the keys, as an iOS input accessory sits,
/// with a key at the end that puts the keyboard away.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

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

  /// Whether a phone's bar shows the text styles in place of its main row.
  bool _stylesOpen = false;

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
    _listenTo(document?.widget.controller);
    if (!identical(document, _document)) {
      _document = document;
      _stylesOpen = false;
      _changed();
    }
  }

  /// Follows [controller]'s selection, the focused document's current one:
  /// a host may hand the same document a new controller.
  void _listenTo(HomericEditorController? controller) {
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_changed);
    controller?.addListener(_changed);
    _controller = controller;
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
    // Each time the bar comes back it starts on its main row.
    if (!shown) _stylesOpen = false;
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
            child: _KeyboardBar(
              actions: actions,
              controller: _controller!,
              stylesOpen: _stylesOpen,
              onStylesOpen: (open) => setState(() => _stylesOpen = open),
            ),
          ),
      ],
    );
  }

  /// The document's buttons for its selection, or for the word at its
  /// caret, each first selecting what it acts on.
  List<HomericFormatAction> _actions() {
    final document = _document;
    if (document != null && document.mounted) {
      _listenTo(document.widget.controller);
    }
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
    var word = selection.isCollapsed ? _wordAt(controller, selection) : null;
    // What each button does at the bare caret: a line's button (an indent,
    // a comment) acts on the line whatever word the caret is in, and inside
    // a mark a button started at the caret every button acts at the caret,
    // so the same one again steps out.
    final atCaret = word == null ? null : _caretActions(builder, controller);
    if (atCaret != null && atCaret.any((a) => a.actsAtCaret)) word = null;
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
    final lineActions = <String, HomericFormatAction>{
      if (word != null)
        for (final action in atCaret!)
          if (action.actsOnBlock) action.label: action,
    };
    return <HomericFormatAction>[
      for (final built in builder(target, blockId, blockSelection))
        if (lineActions[built.label] ?? built case final action)
          if (action.onPressed case final onPressed?)
            action.copyWith(
              onPressed: () => _press(
                controller,
                selection,
                action.actsOnBlock ? null : word,
                onPressed,
              ),
            )
          else
            action,
    ];
  }

  static List<HomericFormatAction>? _caretActions(
    HomericSelectionFormatBarBuilder builder,
    HomericEditorController controller,
  ) {
    final caret = controller.selection;
    if (caret == null) return null;
    final at = controller.document.resolve(caret.head);
    if (at is! InlinePosition) return null;
    return builder(caret, at.block.id, BlockTextSelection.collapsed(at.offset));
  }

  void _press(
    HomericEditorController controller,
    HomericSelection selection,
    HomericSelection? word,
    VoidCallback onPressed,
  ) {
    if (controller.selection != selection) return;
    // A drawn selection menu left open would take its focus scope back
    // from whatever the button opens (a note's field). UIKit closes its
    // own menu on the tap.
    ContextMenuController.removeAny();
    if (word == null) {
      onPressed();
      return;
    }
    // Mid-composition the selection can't move; the word isn't the
    // button's to change yet.
    if (!controller.setSelection(word) && controller.selection != word) return;
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

/// The row itself. On a phone: Undo and Redo, the Aa key that opens the
/// text styles, the buttons that attach something to the words, the line's
/// buttons, then the key that puts the keyboard away. With [stylesOpen] the
/// row shows the text styles instead, with a key back. On a wider screen
/// everything sits in one row after Undo and Redo.
class _KeyboardBar extends StatefulWidget {
  const _KeyboardBar({
    required this.actions,
    required this.controller,
    required this.stylesOpen,
    required this.onStylesOpen,
  });

  final List<HomericFormatAction> actions;
  final HomericEditorController controller;
  final bool stylesOpen;
  final ValueChanged<bool> onStylesOpen;

  /// Narrower than this, the text styles wait behind the Aa key.
  static const double compactWidth = 600;

  static const double _hideKey = 48;
  static const double _minButton = 36;
  static const double _maxButton = 48;
  static const double _rule = 8.5;

  /// The styles that share one box at the front of the styles row.
  static const Set<String> _boxed = <String>{
    'Bold',
    'Italic',
    'Strikethrough',
  };

  @override
  State<_KeyboardBar> createState() => _KeyboardBarState();
}

class _KeyboardBarState extends State<_KeyboardBar> {
  final GlobalKey _stack = GlobalKey();

  /// The name of the key a finger rests on, and its centre across the bar.
  ({String text, double x})? _tip;

  void _hold(String? text, BuildContext? key) {
    if (text == null || key == null) {
      if (_tip != null) setState(() => _tip = null);
      return;
    }
    final keyBox = key.findRenderObject();
    final rowBox = _stack.currentContext?.findRenderObject();
    if (keyBox is! RenderBox || rowBox is! RenderBox) return;
    final centre = rowBox.globalToLocal(
      keyBox.localToGlobal(keyBox.size.center(Offset.zero)),
    );
    HapticFeedback.selectionClick();
    setState(() => _tip = (text: text, x: centre.dx));
  }

  @override
  Widget build(BuildContext context) {
    final palette = _BarPalette.of(context);
    final sides = MediaQuery.paddingOf(context);
    final tip = _tip;
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
          final width = constraints.maxWidth;
          final compact = width < _KeyboardBar.compactWidth;
          return Stack(
            key: _stack,
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned.fill(
                child: compact
                    ? (widget.stylesOpen && widget.actions.any((a) => a.isStyle)
                        ? _stylesRow(palette, width)
                        : _mainRow(palette, width))
                    : _wideRow(palette, width),
              ),
              if (tip != null)
                Positioned(
                  left: tip.x.clamp(64.0, math.max(64.0, width - 64)),
                  bottom: HomericKeyboardFormatBar.height + 6,
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, 0),
                    child: _Tip(text: tip.text, palette: palette),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  /// Undo, Redo, Aa, the words' other buttons, the line's buttons.
  Widget _mainRow(_BarPalette palette, double width) {
    final styles = [
      for (final a in widget.actions)
        if (a.isStyle) a
    ];
    final words = [
      for (final a in widget.actions)
        if (!a.isStyle && !a.actsOnBlock) a
    ];
    final lines = [
      for (final a in widget.actions)
        if (!a.isStyle && a.actsOnBlock) a
    ];
    final groups = <List<Widget Function(double)>>[
      _history(palette),
      if (styles.isNotEmpty)
        <Widget Function(double)>[
          (w) => _StylesKey(
                width: w,
                palette: palette,
                marked: styles.any((a) => a.isActive),
                onPressed: () => widget.onStylesOpen(true),
                onHold: _hold,
              ),
        ],
      if (words.isNotEmpty)
        [for (final a in words) (w) => _button(a, w, palette)],
      if (lines.isNotEmpty)
        [for (final a in lines) (w) => _button(a, w, palette)],
    ];
    return _row(palette, width, groups);
  }

  /// Back, the boxed Bold, Italic and Strikethrough, the other styles.
  Widget _stylesRow(_BarPalette palette, double width) {
    final styles = [
      for (final a in widget.actions)
        if (a.isStyle) a
    ];
    final boxed = [
      for (final a in styles)
        if (_KeyboardBar._boxed.contains(a.label)) a
    ];
    final rest = [
      for (final a in styles)
        if (!_KeyboardBar._boxed.contains(a.label)) a
    ];
    // Back needs less room than a style: it sits before the box, which
    // its outline already sets apart, with no rule between.
    final back = _BarKey(
      key: const ValueKey<String>('homeric-keyboard-styles-back'),
      width: 32,
      label: 'Back',
      tip: 'Back',
      palette: palette,
      onPressed: () => widget.onStylesOpen(false),
      onHold: _hold,
      child: Icon(
        Icons.chevron_left_rounded,
        size: 22,
        color: palette.ink,
      ),
    );
    final groups = <List<Widget Function(double)>>[];
    if (boxed.length > 1) {
      groups.add([
        (w) => _StyleBox(
              palette: palette,
              children: [
                for (final a in boxed)
                  _button(a, math.min(w, 40), palette, square: true),
              ],
            ),
      ]);
    } else {
      groups.add([for (final a in boxed) (w) => _button(a, w, palette)]);
    }
    var current = <Widget Function(double)>[];
    for (final a in rest) {
      if (a.startsGroup && current.isNotEmpty) {
        groups.add(current);
        current = <Widget Function(double)>[];
      }
      current.add((w) => _button(a, w, palette));
    }
    if (current.isNotEmpty) groups.add(current);
    // The box counts as its keys when the widths are shared out.
    return _row(
      palette,
      width,
      groups,
      extraKeys: boxed.length > 1 ? boxed.length - 1 : 0,
      lead: back,
      leadWidth: 32 + 4,
      // Eight styles share a phone's width: a little under the main row's
      // keys, still a full bar tall.
      minButton: 32,
    );
  }

  /// Undo, Redo, then every button in one row, the words' scrolling and
  /// the line's kept in sight beside the hide key, for a tablet's width.
  Widget _wideRow(_BarPalette palette, double width) {
    final words = [
      for (final a in widget.actions)
        if (!a.actsOnBlock || a.isStyle) a
    ];
    final lines = [
      for (final a in widget.actions)
        if (a.actsOnBlock && !a.isStyle) a
    ];
    final room = width -
        _KeyboardBar._hideKey -
        8 -
        2 * _KeyboardBar._minButton -
        (lines.isEmpty ? 0 : lines.length * _KeyboardBar._minButton + 0.5);
    final rules = words.skip(1).where((a) => a.startsGroup).length + 1;
    final each = words.isEmpty
        ? _KeyboardBar._minButton
        : ((room - rules * 9) / words.length)
            .clamp(_KeyboardBar._minButton, _KeyboardBar._maxButton)
            .toDouble();
    final buttons = <Widget>[
      for (final make in _history(palette)) make(_KeyboardBar._minButton),
      _ruleLine(palette),
    ];
    for (var index = 0; index < words.length; index++) {
      final action = words[index];
      if (index > 0 && action.startsGroup) buttons.add(_ruleLine(palette));
      buttons.add(_button(action, each, palette));
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
        if (lines.isNotEmpty) ...[
          SizedBox(
            width: 0.5,
            height: 20,
            child: ColoredBox(color: palette.edge),
          ),
          for (final action in lines)
            _button(action, _KeyboardBar._minButton, palette),
        ],
        _hideKey(palette),
      ],
    );
  }

  /// [groups] of keys with a rule between groups, sharing out the width
  /// left of the hide key; [extraKeys] counts keys a single builder draws
  /// more than one of. Too many keys for the width scroll, as a last resort.
  Widget _row(
    _BarPalette palette,
    double width,
    List<List<Widget Function(double)>> groups, {
    int extraKeys = 0,
    Widget? lead,
    double leadWidth = 0,
    double minButton = _KeyboardBar._minButton,
  }) {
    final shown = [
      for (final g in groups)
        if (g.isNotEmpty) g
    ];
    final keys = shown.fold<int>(0, (n, g) => n + g.length) + extraKeys;
    final room = width -
        _KeyboardBar._hideKey -
        4 -
        leadWidth -
        (shown.length - 1) * _KeyboardBar._rule;
    final each = keys == 0
        ? minButton
        : (room / keys).clamp(minButton, _KeyboardBar._maxButton).toDouble();
    final children = <Widget>[if (lead != null) lead];
    for (var i = 0; i < shown.length; i++) {
      if (i > 0) children.add(_ruleLine(palette));
      for (final make in shown[i]) {
        children.add(make(each));
      }
    }
    return Row(
      children: <Widget>[
        const SizedBox(width: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: children),
          ),
        ),
        _hideKey(palette),
      ],
    );
  }

  List<Widget Function(double)> _history(_BarPalette palette) {
    final controller = widget.controller;
    final writable = !controller.isReadOnly;
    return <Widget Function(double)>[
      (w) => _historyKey(
            palette,
            w,
            'Undo',
            Icons.undo_rounded,
            writable && controller.canUndo ? controller.undo : null,
          ),
      (w) => _historyKey(
            palette,
            w,
            'Redo',
            Icons.redo_rounded,
            writable && controller.canRedo ? controller.redo : null,
          ),
    ];
  }

  Widget _historyKey(
    _BarPalette palette,
    double width,
    String label,
    IconData icon,
    bool Function()? run,
  ) =>
      _BarKey(
        key: ValueKey<String>('homeric-keyboard-${label.toLowerCase()}'),
        width: width,
        label: label,
        tip: label,
        palette: palette,
        onHold: _hold,
        onPressed: run == null
            ? null
            : () {
                ContextMenuController.removeAny();
                run();
              },
        child: Icon(
          icon,
          size: 21,
          color: run == null ? palette.ink.withValues(alpha: 0.3) : palette.ink,
        ),
      );

  Widget _button(
    HomericFormatAction action,
    double width,
    _BarPalette palette, {
    bool square = false,
  }) =>
      _BarButton(
        action: action,
        width: width,
        palette: palette,
        square: square,
        onHold: _hold,
      );

  Widget _ruleLine(_BarPalette palette) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          width: 0.5,
          height: 20,
          child: ColoredBox(color: palette.edge),
        ),
      );

  Widget _hideKey(_BarPalette palette) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 0.5,
            height: HomericKeyboardFormatBar.height,
            child: ColoredBox(color: palette.edge),
          ),
          _BarKey(
            key: const ValueKey<String>('homeric-keyboard-hide'),
            width: _KeyboardBar._hideKey - 0.5,
            label: 'Hide keyboard',
            tip: 'Hide keyboard',
            palette: palette,
            onHold: _hold,
            onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: Icon(
              Icons.keyboard_hide_outlined,
              size: 21,
              color: palette.ink,
            ),
          ),
        ],
      );
}

/// The Aa key: opens the row of text styles; a dot says the words already
/// carry one.
class _StylesKey extends StatelessWidget {
  const _StylesKey({
    required this.width,
    required this.palette,
    required this.marked,
    required this.onPressed,
    required this.onHold,
  });

  final double width;
  final _BarPalette palette;
  final bool marked;
  final VoidCallback onPressed;
  final _HoldCallback onHold;

  @override
  Widget build(BuildContext context) => _BarKey(
        key: const ValueKey<String>('homeric-keyboard-styles'),
        width: width,
        label: 'Text styles',
        tip: 'Text styles',
        palette: palette,
        onPressed: onPressed,
        onHold: onHold,
        child: SizedBox(
          width: 34,
          height: 32,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              CustomPaint(
                size: const Size(19, 14),
                painter: _AaPainter(palette.ink),
              ),
              if (marked)
                Positioned(
                  key: const ValueKey<String>('homeric-keyboard-styles-dot'),
                  top: 5,
                  right: 4,
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: palette.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

/// "Aa", drawn, so it needs no font: a capital A and a small a, in the
/// strokes of the icons beside it.
class _AaPainter extends CustomPainter {
  _AaPainter(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 22 × 16 grid, scaled to [size].
    canvas.scale(size.width / 22, size.height / 16);
    final pen = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final capital = Path()
      ..moveTo(1, 15)
      ..lineTo(6.5, 1)
      ..lineTo(12, 15)
      ..moveTo(3.3, 9.6)
      ..lineTo(9.7, 9.6);
    final small = Path()
      ..addOval(Rect.fromCircle(center: const Offset(17, 11.3), radius: 3.6))
      ..moveTo(20.6, 7.4)
      ..lineTo(20.6, 15);
    canvas
      ..drawPath(capital, pen)
      ..drawPath(small, pen);
  }

  @override
  bool shouldRepaint(_AaPainter old) => old.ink != ink;
}

/// Bold, Italic and Strikethrough in one outlined box.
class _StyleBox extends StatelessWidget {
  const _StyleBox({required this.palette, required this.children});

  final _BarPalette palette;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        key: const ValueKey<String>('homeric-keyboard-style-box'),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              right: 0,
              top: 5,
              bottom: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: palette.edge),
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
            Row(mainAxisSize: MainAxisSize.min, children: children),
          ],
        ),
      );
}

/// A key's name over the bar while a finger rests on it.
class _Tip extends StatelessWidget {
  const _Tip({required this.text, required this.palette});

  final String text;
  final _BarPalette palette;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          key: const ValueKey<String>('homeric-keyboard-tip'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: palette.tip,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            maxLines: 1,
            // The app's own face, as its other small text.
            style: (Theme.of(context).textTheme.bodySmall ?? const TextStyle())
                .copyWith(color: palette.onTip, fontSize: 13, height: 1.2),
          ),
        ),
      );
}

typedef _HoldCallback = void Function(String? text, BuildContext? key);

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.action,
    required this.width,
    required this.palette,
    required this.onHold,
    this.square = false,
  });

  final HomericFormatAction action;
  final double width;
  final _BarPalette palette;
  final _HoldCallback onHold;

  /// Whether it sits in the style box, whose outline already frames it.
  final bool square;

  @override
  Widget build(BuildContext context) {
    final enabled = action.onPressed != null;
    final active = action.isActive && enabled;
    final syntax = action.syntax;
    return _BarKey(
      key: ValueKey<String>('homeric-keyboard-format-${action.label}'),
      width: width,
      label: action.isActive
          ? 'Remove ${action.label.toLowerCase()}'
          : action.label,
      tip: syntax == null ? action.label : '${action.label} · $syntax',
      selected: action.isActive,
      palette: palette,
      onPressed: action.onPressed,
      onHold: onHold,
      child: Container(
        width: square ? width - 4 : 34,
        height: square ? 28 : 32,
        decoration: BoxDecoration(
          color: active
              ? palette.accent.withValues(alpha: 0.14)
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(square ? 6 : 8),
        ),
        child: IconTheme.merge(
          data: IconThemeData(
            size: 19,
            color: !enabled
                ? palette.ink.withValues(alpha: 0.3)
                : active
                    ? palette.accent
                    : palette.ink,
          ),
          child: action.glyph ?? Icon(action.icon),
        ),
      ),
    );
  }
}

/// A press target on the bar that never takes the focus, so the keyboard
/// stays up; it shades while a finger is on it, and held, it names itself
/// over the bar.
class _BarKey extends StatefulWidget {
  const _BarKey({
    super.key,
    required this.width,
    required this.label,
    required this.palette,
    required this.onPressed,
    required this.child,
    this.tip,
    this.onHold,
    this.selected,
  });

  final double width;
  final String label;
  final _BarPalette palette;
  final VoidCallback? onPressed;
  final Widget child;
  final String? tip;
  final _HoldCallback? onHold;
  final bool? selected;

  @override
  State<_BarKey> createState() => _BarKeyState();
}

class _BarKeyState extends State<_BarKey> {
  bool _down = false;

  void _setDown(bool value) {
    if (_down != value) setState(() => _down = value);
  }

  void _release() {
    _setDown(false);
    widget.onHold?.call(null, null);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final tip = widget.tip;
    final hold = widget.onHold;
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
        // Held, the key names itself and does nothing on release.
        onLongPressStart: tip == null || hold == null
            ? null
            : (_) {
                _setDown(false);
                hold(tip, context);
              },
        onLongPressEnd: tip == null || hold == null ? null : (_) => _release(),
        onLongPressCancel:
            tip == null || hold == null ? null : () => _release(),
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
    required this.tip,
    required this.onTip,
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
      tip: dark ? const Color(0xFFECE7E1) : const Color(0xFF2B2623),
      onTip: dark ? const Color(0xFF1E1B19) : const Color(0xFFF8F4EF),
    );
  }

  final Color surface;
  final Color ink;
  final Color edge;
  final Color pressed;
  final Color accent;
  final Color tip;
  final Color onTip;
}
