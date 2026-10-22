/// The iOS 17+ text loupe, which Flutter's [CupertinoTextMagnifier] predates.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart' show TextMagnifier;
import 'package:flutter/widgets.dart';

/// Homeric's adaptive magnifier: the modern loupe on iOS, Flutter's default
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
    return HomericTextMagnifier(
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
