import 'package:flutter/material.dart' show TextMagnifier;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  Future<({MagnifierController controller, ValueNotifier<MagnifierInfo> info})>
      pumpLoupe(WidgetTester tester, {required Offset finger}) async {
    final controller = MagnifierController();
    final info = ValueNotifier<MagnifierInfo>(MagnifierInfo(
      globalGesturePosition: finger,
      caretRect: const Rect.fromLTWH(200, 300, 2, 20),
      fieldBounds: const Rect.fromLTWH(20, 280, 360, 200),
      currentLineBoundaries: const Rect.fromLTWH(20, 300, 360, 20),
    ));
    addTearDown(info.dispose);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: Stack(children: <Widget>[
          Builder(
            builder: (context) =>
                homericAdaptiveMagnifierConfiguration.magnifierBuilder(
                  context,
                  controller,
                  info,
                ) ??
                const SizedBox(),
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    return (controller: controller, info: info);
  }

  testWidgets('iOS gets the modern loupe above the line', (tester) async {
    await pumpLoupe(tester, finger: const Offset(200, 310));

    expect(find.byType(HomericTextMagnifier), findsOneWidget);
    final lens = find.byType(RawMagnifier);
    final rect = tester.getRect(lens);
    expect(rect.size, HomericTextMagnifier.size);
    expect(rect.center.dx, 200, reason: 'the lens follows the finger');
    expect(
      rect.bottom,
      310 - HomericTextMagnifier.gapAboveLine,
      reason: 'the lens sits a fixed gap above the line center',
    );
    final raw = tester.widget<RawMagnifier>(lens);
    expect(raw.magnificationScale, HomericTextMagnifier.magnificationScale);
    expect(raw.decoration.shape, isA<StadiumBorder>());
    expect(
      rect.center + raw.focalPointOffset,
      const Offset(200, 310),
      reason: 'the lens magnifies the line under the caret',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the loupe keeps clear of the screen edge', (tester) async {
    await pumpLoupe(tester, finger: const Offset(4, 312));
    final rect = tester.getRect(find.byType(RawMagnifier));
    expect(rect.left, 10);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android keeps Flutter\'s magnifier', (tester) async {
    await pumpLoupe(tester, finger: const Offset(200, 312));
    expect(find.byType(HomericTextMagnifier), findsNothing);
    expect(find.byType(TextMagnifier), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
