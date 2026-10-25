import 'package:calabash_maturity_detection/utils/app_theme.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/widgets/information_button.dart';
import 'package:calabash_maturity_detection/widgets/information_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

const _title = 'Model confidence score';
const _message =
    'A score describes how strongly the model favors a predicted class.';
const _tooltip = 'Explain model confidence';

Future<void> _show(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double textScale = 1,
  bool compact = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final theme = AppTheme.build();
  await tester.pumpWidget(
    MaterialApp(
      theme: compact
          ? theme.copyWith(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

TextStyle _effectiveStyle(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  return DefaultTextStyle.of(tester.element(finder)).style.merge(text.style);
}

Finder _dialogSurface() => find
    .descendant(
      of: find.byType(InformationDialog),
      matching: find.byType(Material),
    )
    .first;

void main() {
  test('app theme provides consistent typography and keeps splash sizes', () {
    final text = AppTheme.build().textTheme;
    expect(text.titleLarge?.fontSize, 20);
    expect(text.titleLarge?.fontWeight, FontWeight.w600);
    expect(text.bodyLarge?.fontSize, 16);
    expect(text.bodyLarge?.fontWeight, FontWeight.w400);
    expect(text.labelLarge?.fontSize, 15);
    expect(text.labelLarge?.fontWeight, FontWeight.w500);
    expect(text.bodyLarge?.fontFamily, contains('NunitoSans'));
    expect(text.titleLarge?.fontFamily, text.bodyLarge?.fontFamily);
    // The approved splash derives these three sizes from the shared theme.
    expect(text.headlineMedium?.fontSize, 32);
    expect(text.titleSmall?.fontSize, 14);
    expect(text.bodySmall?.fontSize, 12);
  });

  testWidgets(
    'information icon keeps a labeled 48dp target in compact themes',
    (tester) async {
      var presses = 0;
      await _show(
        tester,
        InformationIconButton(tooltip: _tooltip, onPressed: () => presses++),
        compact: true,
      );
      final button = find.byType(InformationIconButton);
      final rect = tester.getRect(button);
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
      final icon = tester.widget<Icon>(find.byIcon(Icons.info_outline_rounded));
      expect(icon.size, 22);
      final semantics = tester
          .getSemantics(find.byTooltip(_tooltip))
          .getSemanticsData();
      expect(semantics.tooltip, _tooltip);
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(semantics.hasAction(SemanticsAction.tap), isTrue);
      // A nominal 48dp wrapper must also respond outside the visual icon.
      await tester.tapAt(rect.topLeft + const Offset(3, 3));
      await tester.pump();
      expect(presses, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('information button opens and closes the shared dialog', (
    tester,
  ) async {
    await _show(
      tester,
      const InformationButton(
        title: _title,
        message: _message,
        tooltip: _tooltip,
      ),
    );
    await tester.tap(find.byTooltip(_tooltip));
    await tester.pumpAndSettle();
    expect(find.byType(InformationDialog), findsOneWidget);
    expect(find.text(_title), findsOneWidget);
    expect(find.text(_message), findsOneWidget);
    expect(find.text('Close').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(InformationDialog), findsNothing);
    expect(find.byTooltip(_tooltip).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled information button cannot open a dialog', (
    tester,
  ) async {
    await _show(
      tester,
      const InformationButton(
        title: _title,
        message: _message,
        tooltip: _tooltip,
        enabled: false,
      ),
    );
    final semantics = tester
        .getSemantics(find.byTooltip(_tooltip))
        .getSemanticsData();
    expect(semantics.hasAction(SemanticsAction.tap), isFalse);
    await tester.tap(find.byTooltip(_tooltip));
    await tester.pumpAndSettle();
    expect(find.byType(InformationDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short dialog uses content height and the shared presentation', (
    tester,
  ) async {
    const viewport = Size(1000, 800);
    await _show(
      tester,
      const InformationButton(
        title: _title,
        message: _message,
        tooltip: _tooltip,
      ),
      size: viewport,
    );
    await tester.tap(find.byTooltip(_tooltip));
    await tester.pumpAndSettle();
    final rect = tester.getRect(_dialogSurface());
    expect(rect.width, lessThanOrEqualTo(520));
    expect(rect.height, lessThan(viewport.height * .6));
    expect(rect.center.dx, closeTo(viewport.width / 2, 1));
    expect(rect.center.dy, closeTo(viewport.height / 2, 1));
    final material = tester.widget<Material>(_dialogSurface());
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(22));
    final title = _effectiveStyle(tester, find.text(_title));
    final body = _effectiveStyle(tester, find.text(_message));
    final close = _effectiveStyle(tester, find.text('Close'));
    expect(title.fontSize, 20);
    expect(title.fontWeight, FontWeight.w600);
    expect(body.fontSize, 16);
    expect(body.fontWeight, FontWeight.w400);
    expect(close.fontSize, 15);
    expect(close.fontWeight, FontWeight.w500);
    expect(close.color, AppConstants.primaryGreen);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long dialog scrolls on a small screen at 2x text', (
    tester,
  ) async {
    final message = List.generate(
      18,
      (index) =>
          'Paragraph ${index + 1}: Review the visible fruit and the prediction '
          'carefully. Lighting, image quality, and fruit visibility can affect '
          'the displayed result.',
    ).join('\n\n');
    await _show(
      tester,
      InformationButton(
        title: 'Understanding prediction information',
        message: message,
        tooltip: _tooltip,
      ),
      size: const Size(320, 568),
      textScale: 2,
    );
    await tester.tap(find.byTooltip(_tooltip));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: find.byType(InformationDialog),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(position.extentAfter, 0);
    expect(find.text('Close').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(InformationDialog), findsNothing);
  });

  testWidgets('information label stays aligned and wraps at 2x text', (
    tester,
  ) async {
    const label = '100% Model confidence score';
    await _show(
      tester,
      const SizedBox(
        width: 220,
        child: InformationLabel(text: label, title: _title, message: _message),
      ),
      size: const Size(320, 568),
      textScale: 2,
    );
    final textRect = tester.getRect(find.text(label));
    final iconRect = tester.getRect(find.byType(InformationIconButton));
    final rowRect = tester.getRect(find.byType(InformationLabel));
    expect(textRect.right, lessThanOrEqualTo(iconRect.left));
    expect(textRect.center.dy, closeTo(iconRect.center.dy, 1));
    expect(iconRect.width, greaterThanOrEqualTo(48));
    expect(iconRect.height, greaterThanOrEqualTo(48));
    expect(iconRect.right, lessThanOrEqualTo(rowRect.right));
    expect(textRect.left, greaterThanOrEqualTo(rowRect.left));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(InformationIconButton));
    await tester.pumpAndSettle();
    expect(find.text(_message), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
