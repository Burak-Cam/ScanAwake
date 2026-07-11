import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:no_snooze/widgets/brand.dart';

// BRAND-IN-APP: pins the self-fitting behavior of the ScanAwake wordmark.
// The lockup must (1) scale itself down when the layout gives it less width
// than its natural size (narrow screens), (2) ignore the system text scale —
// it is a brand lockup, not accessibility text — and (3) never scale UP on
// wide layouts (natural size is the ceiling).
void main() {
  Finder wordmarkRichText() => find.descendant(
        of: find.byType(ScanAwakeWordmark),
        matching: find.byType(RichText),
      );

  group('ScanAwakeWordmark self-fitting', () {
    testWidgets('fits a narrow constraint under 2.0 system text scale',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 120,
                  child: ScanAwakeWordmark(fontSize: 20),
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);

      // The widget itself must respect the 120px constraint.
      expect(
        tester.getSize(find.byType(ScanAwakeWordmark)).width,
        lessThanOrEqualTo(120),
      );

      // The text must not paint past its own render box: the natural
      // (intrinsic) single-line width may not exceed the laid-out width.
      // (A visible-overflow paragraph keeps its box at the constraint while
      // drawing beyond it, so the size check alone cannot catch that.)
      final RenderParagraph paragraph =
          tester.renderObject<RenderParagraph>(wordmarkRichText());
      expect(
        paragraph.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(paragraph.size.width + 0.01),
      );
    });

    testWidgets('renders SCAN + AWAKE spans as a single SCANAWAKE rich text',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: ScanAwakeWordmark())),
        ),
      );

      expect(find.text('SCANAWAKE', findRichText: true), findsOneWidget);
    });

    testWidgets('never scales up on a wide unconstrained layout',
        (tester) async {
      const double fontSize = 20;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: ScanAwakeWordmark(fontSize: fontSize)),
          ),
        ),
      );

      // Scale-down only: on a wide layout the wordmark stays at its natural
      // text size instead of growing to fill the available space.
      final Size size = tester.getSize(find.byType(ScanAwakeWordmark));
      expect(size.height, lessThanOrEqualTo(fontSize * 1.6));
    });
  });
}
