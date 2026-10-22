import 'package:flutter/material.dart' show TextMagnifier;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  setUp(HomericSystemLoupe.resetAvailability);
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

  List<MethodCall> answerLoupe(WidgetTester tester, {required bool shown}) {
    final calls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(HomericSystemLoupe.channel,
        (call) async {
      calls.add(call);
      return call.method == 'begin' ? shown : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(
          HomericSystemLoupe.channel,
          null,
        ));
    return calls;
  }

  testWidgets('iOS asks the app for the system loupe', (tester) async {
    final calls = answerLoupe(tester, shown: true);
    final loupe = await pumpLoupe(tester, finger: const Offset(200, 310));

    expect(find.byType(HomericSystemLoupe), findsOneWidget);
    expect(find.byType(RawMagnifier), findsNothing,
        reason: 'iOS draws the loupe itself');
    expect(calls.single.method, 'begin');
    expect(calls.single.arguments, <String, Object>{
      'x': 200.0,
      'y': 310.0,
      'caret': <double>[200, 300, 2, 20],
    });

    loupe.info.value = const MagnifierInfo(
      globalGesturePosition: Offset(240, 312),
      caretRect: Rect.fromLTWH(240, 300, 2, 20),
      fieldBounds: Rect.fromLTWH(20, 280, 360, 200),
      currentLineBoundaries: Rect.fromLTWH(20, 300, 360, 20),
    );
    await tester.pump();
    expect(calls.last.method, 'move');
    expect((calls.last.arguments as Map)['x'], 240.0);

    // Far below the line, the loupe steps aside, and comes back on a new
    // session.
    loupe.info.value = const MagnifierInfo(
      globalGesturePosition: Offset(240, 400),
      caretRect: Rect.fromLTWH(240, 300, 2, 20),
      fieldBounds: Rect.fromLTWH(20, 280, 360, 200),
      currentLineBoundaries: Rect.fromLTWH(20, 300, 360, 20),
    );
    await tester.pump();
    expect(calls.last.method, 'end');
    loupe.info.value = const MagnifierInfo(
      globalGesturePosition: Offset(240, 312),
      caretRect: Rect.fromLTWH(240, 300, 2, 20),
      fieldBounds: Rect.fromLTWH(20, 280, 360, 200),
      currentLineBoundaries: Rect.fromLTWH(20, 300, 360, 20),
    );
    await tester.pump();
    expect(calls.last.method, 'begin');

    await tester.pumpWidget(const SizedBox());
    expect(calls.last.method, 'end', reason: 'the drag ended');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('an app without the system loupe gets the drawn one',
      (tester) async {
    answerLoupe(tester, shown: false);
    await pumpLoupe(tester, finger: const Offset(200, 310));
    expect(find.byType(HomericTextMagnifier), findsOneWidget);
    expect(find.byType(RawMagnifier), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the drawn loupe sits above the line', (tester) async {
    answerLoupe(tester, shown: false);
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
    answerLoupe(tester, shown: false);
    await pumpLoupe(tester, finger: const Offset(4, 310));
    final lens = find.byType(RawMagnifier);
    final rect = tester.getRect(lens);
    expect(rect.left, 10);
    expect(
      rect.center + tester.widget<RawMagnifier>(lens).focalPointOffset,
      const Offset(4, 310),
      reason: 'the shifted lens still shows the text under the finger',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a new controller drives the same loupe', (tester) async {
    answerLoupe(tester, shown: false);
    final first = await pumpLoupe(tester, finger: const Offset(200, 310));
    expect(first.controller.animationController, isNotNull);
    final info = first.info;
    final second = MagnifierController();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: Stack(children: <Widget>[
          Builder(
            builder: (_) =>
                HomericTextMagnifier(controller: second, magnifierInfo: info),
          ),
        ]),
      ),
    ));
    expect(first.controller.animationController, isNull);
    expect(second.animationController, isNotNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android keeps Flutter\'s magnifier', (tester) async {
    await pumpLoupe(tester, finger: const Offset(200, 312));
    expect(find.byType(HomericTextMagnifier), findsNothing);
    expect(find.byType(TextMagnifier), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
