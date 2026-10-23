/// The iOS 17+ text loupe, which Flutter's [CupertinoTextMagnifier] predates.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart' show TextMagnifier;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Homeric's adaptive magnifier: the system loupe on iOS, Flutter's default
/// elsewhere. Touch selection uses it on iOS only; Android keeps
/// [TextMagnifier.adaptiveMagnifierConfiguration], which also keeps the
/// handles out of the lens there.
const TextMagnifierConfiguration homericAdaptiveMagnifierConfiguration =
    TextMagnifierConfiguration(magnifierBuilder: _adaptiveMagnifierBuilder);

Widget? _adaptiveMagnifierBuilder(
  BuildContext context,
  MagnifierController controller,
  ValueNotifier<MagnifierInfo> magnifierInfo,
) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return HomericSystemLoupe(
      controller: controller,
      magnifierInfo: magnifierInfo,
    );
  }
  return TextMagnifier.adaptiveMagnifierConfiguration.magnifierBuilder(
    context,
    controller,
    magnifierInfo,
  );
}

/// The loupe iOS itself draws (Liquid Glass on iOS 26), asked for over the
/// `homeric/loupe` channel, which magnifies whatever Flutter drew under the
/// finger. An app that doesn't answer the channel gets [HomericTextMagnifier]
/// instead.
///
/// The channel takes `begin` and `move` with the finger (`x`, `y`) and the
/// caret (`caret`: left, top, width, height), all in logical pixels of the
/// Flutter view, and `end`. `begin` answers whether a loupe is showing.
class HomericSystemLoupe extends StatefulWidget {
  /// Creates the loupe for one drag.
  const HomericSystemLoupe({
    super.key,
    required this.controller,
    required this.magnifierInfo,
  });

  /// Shows and hides the loupe.
  final MagnifierController controller;

  /// The caret and finger the loupe follows.
  final ValueNotifier<MagnifierInfo> magnifierInfo;

  /// The channel the app's iOS side answers.
  static const MethodChannel channel = MethodChannel('homeric/loupe');

  /// Whether the app answered `begin`; unknown until the first drag.
  static bool? _available;

  /// Forgets whether the app answered, for tests.
  @visibleForTesting
  static void resetAvailability() => _available = null;

  @override
  State<HomericSystemLoupe> createState() => _HomericSystemLoupeState();
}

class _HomericSystemLoupeState extends State<HomericSystemLoupe> {
  bool _drawn = HomericSystemLoupe._available == false;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    if (_drawn) return;
    widget.magnifierInfo.addListener(_follow);
    _follow();
  }

  @override
  void didUpdateWidget(HomericSystemLoupe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_drawn && oldWidget.magnifierInfo != widget.magnifierInfo) {
      oldWidget.magnifierInfo.removeListener(_follow);
      widget.magnifierInfo.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.magnifierInfo.removeListener(_follow);
    _end();
    super.dispose();
  }

  void _follow() {
    final info = widget.magnifierInfo.value;
    final finger = info.globalGesturePosition;
    final caret = info.caretRect;
    // Like the drawn loupe, step aside when the finger drags far below the
    // line.
    if (caret.center.dy - finger.dy <
        -HomericTextMagnifier._hideBelowThreshold) {
      _end();
      return;
    }
    final args = <String, Object>{
      'x': finger.dx,
      'y': finger.dy,
      'caret': <double>[caret.left, caret.top, caret.width, caret.height],
    };
    if (_active) {
      HomericSystemLoupe.channel.invokeMethod<void>('move', args);
      return;
    }
    _active = true;
    HomericSystemLoupe.channel.invokeMethod<bool>('begin', args).then(
      (shown) {
        HomericSystemLoupe._available = shown ?? false;
        if (shown != true) _drawInstead();
      },
      onError: (Object _) {
        HomericSystemLoupe._available = false;
        _drawInstead();
      },
    );
  }

  void _end() {
    if (!_active) return;
    _active = false;
    HomericSystemLoupe.channel.invokeMethod<void>('end').catchError((_) {});
  }

  void _drawInstead() {
    widget.magnifierInfo.removeListener(_follow);
    _active = false;
    if (mounted) setState(() => _drawn = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_drawn) return const SizedBox.shrink();
    return HomericTextMagnifier(
      controller: widget.controller,
      magnifierInfo: widget.magnifierInfo,
    );
  }
}

/// The loupe iOS 17 and later show while a caret or handle is dragged: a
/// wide pill well above the finger, text a quarter larger, a soft shadow and
/// a hairline edge instead of a tinted border.
///
/// Placement follows [CupertinoTextMagnifier]: the lens tracks the finger
/// horizontally, stays on the current line, and hides when the finger drags
/// far below it.
class HomericTextMagnifier extends StatefulWidget {
  /// Creates the loupe for one drag.
  const HomericTextMagnifier({
    super.key,
    required this.controller,
    required this.magnifierInfo,
  });

  /// Shows and hides the loupe.
  final MagnifierController controller;

  /// The caret and finger the loupe follows.
  final ValueNotifier<MagnifierInfo> magnifierInfo;

  /// Lens size, measured from the system loupe on iOS 26.
  static const Size size = Size(104, 74);

  /// Gap between the line's center and the lens's bottom edge.
  static const double gapAboveLine = 30;

  /// How much larger text reads inside the lens.
  static const double magnificationScale = 1.25;

  static const double _dragResistance = 10;
  static const double _hideBelowThreshold = 48;
  static const double _horizontalScreenEdgePadding = 10;
  static const Duration _inOutDuration = Duration(milliseconds: 150);
  static const Duration _dragDuration = Duration(milliseconds: 45);

  @override
  State<HomericTextMagnifier> createState() => _HomericTextMagnifierState();
}

class _HomericTextMagnifierState extends State<HomericTextMagnifier>
    with SingleTickerProviderStateMixin {
  Offset _position = Offset.zero;
  double _focalAdjustment = 0;
  double _focalShift = 0;
  late final AnimationController _inOut = AnimationController(
    vsync: this,
    duration: HomericTextMagnifier._inOutDuration,
  )..addListener(() => setState(() {}));
  late final CurvedAnimation _inOutCurve = CurvedAnimation(
    parent: _inOut,
    curve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.animationController = _inOut;
    widget.magnifierInfo.addListener(_follow);
  }

  @override
  void didUpdateWidget(HomericTextMagnifier oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.animationController = null;
      widget.controller.animationController = _inOut;
    }
    if (oldWidget.magnifierInfo != widget.magnifierInfo) {
      oldWidget.magnifierInfo.removeListener(_follow);
      widget.magnifierInfo.addListener(_follow);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void dispose() {
    widget.controller.animationController = null;
    widget.magnifierInfo.removeListener(_follow);
    _inOutCurve.dispose();
    _inOut.dispose();
    super.dispose();
  }

  void _follow() {
    final info = widget.magnifierInfo.value;
    final lineCenter = info.caretRect.center.dy;
    final finger = info.globalGesturePosition;
    if (lineCenter - finger.dy < -HomericTextMagnifier._hideBelowThreshold) {
      if (widget.controller.shown) {
        widget.controller.hide(removeFromOverlay: false);
      }
      return;
    }
    if (!widget.controller.shown) _inOut.forward();

    // Stay on the line, with some give when the finger drags below it.
    final lensLine = math.max(
      lineCenter,
      lineCenter -
          (lineCenter - finger.dy) / HomericTextMagnifier._dragResistance,
    );
    const size = HomericTextMagnifier.size;
    final raw = Offset(
      finger.dx - size.width / 2,
      lensLine - HomericTextMagnifier.gapAboveLine - size.height,
    );
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    const padding = HomericTextMagnifier._horizontalScreenEdgePadding;
    final position = MagnifierController.shiftWithinBounds(
      bounds: Rect.fromLTRB(
        screen.left + padding,
        // iOS lets the lens leave the top of the screen rather than move it.
        screen.top - size.height - HomericTextMagnifier.gapAboveLine,
        screen.right - padding,
        screen.bottom + size.height + HomericTextMagnifier.gapAboveLine,
      ),
      rect: raw & size,
    ).topLeft;
    setState(() {
      _position = position;
      _focalAdjustment = lineCenter - lensLine;
      // Kept off the screen edge, the lens still shows what is under the
      // finger.
      _focalShift = finger.dx - (position.dx + size.width / 2);
    });
  }

  @override
  Widget build(BuildContext context) {
    const size = HomericTextMagnifier.size;
    final t = _inOutCurve.value;
    // The lens grows up out of the line as it appears.
    final rise =
        (1 - t) * (size.height / 2 + HomericTextMagnifier.gapAboveLine);
    return AnimatedPositioned(
      duration: HomericTextMagnifier._dragDuration,
      curve: Curves.easeOut,
      left: _position.dx,
      top: _position.dy,
      child: Transform.translate(
        offset: Offset(0, rise),
        child: RawMagnifier(
          size: size,
          magnificationScale: HomericTextMagnifier.magnificationScale,
          // The shadow paints over the lens; the clip keeps it outside.
          clipBehavior: Clip.hardEdge,
          focalPointOffset: Offset(
            _focalShift,
            size.height / 2 +
                HomericTextMagnifier.gapAboveLine -
                rise +
                _focalAdjustment,
          ),
          decoration: MagnifierDecoration(
            opacity: t,
            shape: const StadiumBorder(
              side: BorderSide(color: Color(0x14000000), width: 0.5),
            ),
            shadows: const <BoxShadow>[
              BoxShadow(
                color: Color(0x1F000000),
                blurRadius: 24,
                offset: Offset(0, 6),
              ),
              BoxShadow(
                color: Color(0x0F000000),
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
