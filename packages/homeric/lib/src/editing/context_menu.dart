/// The drawn right-click menu on desktop: a bar of formatting buttons over
/// the edit items, each row with its key.
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editable_document.dart';

/// One row of the menu under the bar.
@immutable
final class HomericMenuRow {
  const HomericMenuRow({
    required this.label,
    this.shortcut,
    this.onPressed,
    this.emphasized = false,
  });

  final String label;

  /// The key beside the label (`⌘X`), already spelled for the platform.
  final String? shortcut;

  /// Null shows the row dimmed.
  final VoidCallback? onPressed;

  /// A spelling suggestion: drawn in the weight macOS gives them.
  final bool emphasized;
}

/// Spells [key] with ⌘ on macOS and Ctrl+ elsewhere (`⌘Z`, `Ctrl+Z`),
/// with Shift (`⇧⌘Z`, `Ctrl+Shift+Z`).
String homericMenuShortcut(String key, {bool shift = false}) {
  if (defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return '${shift ? '⇧' : ''}⌘$key';
  }
  return 'Ctrl+${shift ? 'Shift+' : ''}$key';
}

/// Whether the drawn menu is the desktop one: a right click's menu with the
/// format bar, rather than the touch toolbar.
bool homericUsesDesktopMenu() => switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };

const double _kButton = 30;
const double _kMenuPadding = 5;
const double _kRowHeight = 26;
const double _kMinWidth = 232;
const double _kScreenMargin = 8;

/// The desktop selection menu at [anchor] (global): [actions] across the
/// top, then [sections] of rows with a rule between each.
class HomericContextMenu extends StatelessWidget {
  const HomericContextMenu({
    super.key,
    required this.anchor,
    required this.actions,
    required this.sections,
  });

  final Offset anchor;
  final List<HomericFormatAction> actions;
  final List<List<HomericMenuRow>> sections;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.paddingOf(context);
    final palette = _MenuPalette.of(context);
    final shown = <Widget>[
      if (actions.isNotEmpty) _FormatBar(actions: actions, palette: palette),
      for (final section in sections.where((s) => s.isNotEmpty)) ...[
        _Rule(palette: palette),
        for (final row in section) HomericMenuRowButton(row: row),
      ],
    ];
    // A bar first has no rule above it; rows first neither.
    if (actions.isEmpty && shown.isNotEmpty && shown.first is _Rule) {
      shown.removeAt(0);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _kScreenMargin,
        _kScreenMargin + media.top,
        _kScreenMargin,
        _kScreenMargin + media.bottom,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor: anchor - Offset(_kScreenMargin, _kScreenMargin + media.top),
        ),
        child: Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowDown):
                DirectionalFocusIntent(TraversalDirection.down),
            SingleActivator(LogicalKeyboardKey.arrowUp):
                DirectionalFocusIntent(TraversalDirection.up),
            SingleActivator(LogicalKeyboardKey.arrowLeft):
                DirectionalFocusIntent(TraversalDirection.left),
            SingleActivator(LogicalKeyboardKey.arrowRight):
                DirectionalFocusIntent(TraversalDirection.right),
          },
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: DefaultTextStyle(
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                color: palette.ink,
                fontFamilyFallback: const <String>['.AppleSystemUIFont'],
              ),
              child: Container(
                key: const ValueKey<String>('homeric-context-menu'),
                constraints: const BoxConstraints(minWidth: _kMinWidth),
                padding: const EdgeInsets.all(_kMenuPadding),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.edge, width: 0.5),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: palette.shadow,
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                    BoxShadow(
                      color: palette.shadow.withValues(alpha: 0.5),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: IntrinsicWidth(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: shown,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The menu's colours, from the app's theme so it sits in either app.
@immutable
final class _MenuPalette {
  const _MenuPalette({
    required this.surface,
    required this.ink,
    required this.quiet,
    required this.edge,
    required this.hover,
    required this.accent,
    required this.shadow,
    required this.dark,
  });

  factory _MenuPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final ink = scheme.onSurface;
    return _MenuPalette(
      surface: dark
          ? Color.alphaBlend(
              Colors.white.withValues(alpha: 0.06), scheme.surface)
          : Color.alphaBlend(
              Colors.white.withValues(alpha: 0.7), scheme.surface),
      ink: ink,
      quiet: ink.withValues(alpha: 0.48),
      edge: ink.withValues(alpha: dark ? 0.16 : 0.12),
      hover: ink.withValues(alpha: dark ? 0.1 : 0.065),
      accent: scheme.primary,
      shadow: Colors.black.withValues(alpha: dark ? 0.45 : 0.16),
      dark: dark,
    );
  }

  final Color surface;
  final Color ink;
  final Color quiet;
  final Color edge;
  final Color hover;
  final Color accent;
  final Color shadow;
  final bool dark;
}

class _Rule extends StatelessWidget {
  const _Rule({required this.palette});

  final _MenuPalette palette;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        child: SizedBox(height: 0.5, child: ColoredBox(color: palette.edge)),
      );
}

/// A hover- and focus-aware press target, shaded the way the menu shades.
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.onPressed,
    required this.palette,
    required this.builder,
    this.semanticsLabel,
    this.selected,
  });

  final VoidCallback? onPressed;
  final _MenuPalette palette;
  final Widget Function(BuildContext context, bool lit) builder;
  final String? semanticsLabel;
  final bool? selected;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final lit = enabled && (_hovered || _focused);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.semanticsLabel,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor:
            enabled ? SystemMouseCursors.basic : SystemMouseCursors.basic,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: widget.builder(context, lit),
        ),
      ),
    );
  }
}

/// One row of [HomericContextMenu], pressable by pointer or keyboard.
class HomericMenuRowButton extends StatelessWidget {
  const HomericMenuRowButton({super.key, required this.row});

  final HomericMenuRow row;

  /// What pressing the row runs; null when it is dimmed.
  VoidCallback? get onPressed => row.onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = row.onPressed != null;
    final palette = _MenuPalette.of(context);
    return _Pressable(
      onPressed: row.onPressed,
      palette: palette,
      semanticsLabel: row.label,
      builder: (context, lit) => AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: _kRowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: lit ? palette.hover : const Color(0x00000000),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                row.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: enabled ? palette.ink : palette.quiet,
                  fontWeight:
                      row.emphasized ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (row.shortcut != null) ...[
              const SizedBox(width: 24),
              Text(
                row.shortcut!,
                style: TextStyle(
                  color: palette.quiet,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FormatBar extends StatelessWidget {
  const _FormatBar({required this.actions, required this.palette});

  final List<HomericFormatAction> actions;
  final _MenuPalette palette;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var index = 0; index < actions.length; index++) {
      final action = actions[index];
      if (index > 0 && action.startsGroup) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SizedBox(
            width: 0.5,
            height: 18,
            child: ColoredBox(color: palette.edge),
          ),
        ));
      }
      children.add(_FormatButton(action: action, palette: palette));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        key: const ValueKey<String>('homeric-format-bar'),
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: children,
      ),
    );
  }
}

class _FormatButton extends StatelessWidget {
  const _FormatButton({required this.action, required this.palette});

  final HomericFormatAction action;
  final _MenuPalette palette;

  @override
  Widget build(BuildContext context) {
    final enabled = action.onPressed != null;
    final active = action.isActive && enabled;
    return Tooltip(
      key: ValueKey<String>('homeric-format-${action.label}'),
      richMessage: WidgetSpan(child: _FormatTip(action: action)),
      waitDuration: const Duration(milliseconds: 350),
      showDuration: const Duration(milliseconds: 100),
      exitDuration: const Duration(milliseconds: 60),
      preferBelow: false,
      verticalOffset: _kButton / 2 + 6,
      padding: const EdgeInsets.fromLTRB(11, 8, 11, 9),
      decoration: BoxDecoration(
        color: palette.dark ? const Color(0xFFF2EFEA) : const Color(0xFF2A2624),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      excludeFromSemantics: true,
      child: _Pressable(
        onPressed: action.onPressed,
        palette: palette,
        semanticsLabel: action.label,
        selected: action.isActive,
        builder: (context, lit) => AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: _kButton,
          height: _kButton,
          decoration: BoxDecoration(
            color: active
                ? palette.accent.withValues(alpha: lit ? 0.2 : 0.13)
                : lit
                    ? palette.hover
                    : const Color(0x00000000),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(
            action.icon,
            size: 18,
            color: !enabled
                ? palette.quiet.withValues(alpha: 0.3)
                : active
                    ? palette.accent
                    : palette.ink.withValues(alpha: lit ? 0.9 : 0.68),
          ),
        ),
      ),
    );
  }
}

/// A button's tooltip: its name and key, what it does, and what typing
/// does the same.
class _FormatTip extends StatelessWidget {
  const _FormatTip({required this.action});

  final HomericFormatAction action;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xFF1F1B19) : const Color(0xFFF7F3EE);
    final quiet = ink.withValues(alpha: 0.66);
    final description = action.description;
    final syntax = action.syntax;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 236),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                action.isActive
                    ? 'Remove ${action.label.toLowerCase()}'
                    : action.label,
                style: TextStyle(
                  color: ink,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (action.shortcut != null) ...[
                const SizedBox(width: 8),
                Text(
                  action.shortcut!,
                  style: TextStyle(color: quiet, fontSize: 12),
                ),
              ],
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 3),
            Text(
              description,
              style: TextStyle(color: quiet, fontSize: 12, height: 1.3),
            ),
          ],
          if (syntax != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: ink.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                syntax,
                style: TextStyle(
                  color: ink.withValues(alpha: 0.85),
                  fontSize: 11.5,
                  fontFamily: 'Menlo',
                  fontFamilyFallback: const <String>[
                    'SF Mono',
                    'Consolas',
                    'monospace',
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
