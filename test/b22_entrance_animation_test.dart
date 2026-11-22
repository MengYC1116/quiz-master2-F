// 二十二批 D-247：入场上移淡入（EntranceFadeSlide）单测。
// 只用合成字符串/纯 widget，不用题目数据。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/widgets/entrance_animation.dart';

void main() {
  Widget wrap(Widget child, {bool disableAnimations = false}) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: child,
      ),
    );
  }

  double opacityOf(WidgetTester tester) {
    final found = find.byType(Opacity);
    expect(found, findsOneWidget);
    return tester.widget<Opacity>(found).opacity;
  }

  testWidgets('默认：首帧近乎透明、跑完后完全不透明且无位移', (tester) async {
    await tester.pumpWidget(
      wrap(
        const EntranceFadeSlide(child: Text('入场内容')),
      ),
    );
    expect(find.text('入场内容'), findsOneWidget);
    expect(opacityOf(tester), closeTo(0.01, 0.001));
    await tester.pumpAndSettle();
    expect(opacityOf(tester), closeTo(1.0, 0.001));
    final transform = tester.widget<Transform>(find.byType(Transform).first);
    expect((transform.transform).getTranslation().y, closeTo(0.0, 0.001));
  });

  testWidgets('delay：等待期内不动，过了 delay 才开始淡入', (tester) async {
    await tester.pumpWidget(
      wrap(
        const EntranceFadeSlide(
          delay: Duration(milliseconds: 200),
          child: Text('错开的行'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacityOf(tester), closeTo(0.01, 0.001));
    // 注意：fake async 下定时器在“跨过它”的那次 pump 里不触发，
    // 要再 pump 一次才 forward、再 pump 一次 ticker 才推进
    //（实测：100→350→空 pump→100 后透明度约 0.57）。
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacityOf(tester), greaterThan(0.01));
    await tester.pumpAndSettle();
    expect(opacityOf(tester), closeTo(1.0, 0.001));
  });

  testWidgets('disableAnimations：直接出内容，不包 Opacity 层', (tester) async {
    await tester.pumpWidget(
      wrap(
        const EntranceFadeSlide(child: Text('减弱动效')),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    expect(find.text('减弱动效'), findsOneWidget);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('首帧仍可点按（淡入起点 0.01 而非 0）', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      wrap(
        EntranceFadeSlide(
          child: TextButton(
            onPressed: () => tapped++,
            child: const Text('点我'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('点我'));
    expect(tapped, 1);
  });
}
