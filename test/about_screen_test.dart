import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/about_screen.dart';
import 'package:calabash_maturity_detection/screens/home_screen.dart';
import 'package:calabash_maturity_detection/utils/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'detection_provider_test.dart' show TestImageService, TestModelService;

const _purpose =
    'This mobile application assists users in identifying the visually estimated maturity stages of calabash fruits through image-based detection and classification.';
const _confidence =
    "This is the detection model's score for the predicted maturity class of this fruit region. It describes how strongly the model supports the prediction. It does not represent measured accuracy, a calibrated probability, or a statistical margin of error.";
const _limitations =
    'This application evaluates visible surface characteristics only. It cannot determine internal fruit maturity, internal quality, or safety. Results may also be affected by lighting, image quality, background conditions, and fruit visibility.';
const _inspection =
    'The application supports visual assessment and does not replace additional inspection or expert judgment.';
const _offline =
    'Offline-ready: after installation, image analysis can run without internet access.';
const _developers =
    'Ralph Laurenz G. Medino\nMaxine Grace C. Emnas\nJohn Carlo M. Bino\nDarren A. Zuniega\n\nInstitution: Leyte Normal University';
const _sections = [
  'How It Works',
  'Maturity Stages',
  'Understanding Model Confidence',
  'Important Limitations',
  'Tips for Better Detection',
  'Developers',
];

Future<void> _showAbout(WidgetTester tester, {double textScale = 1}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const AboutScreen(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('offline heading keeps whole words at narrow 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _showAbout(tester, textScale: 2);
    final heading = find.text('Offline Functionality');
    await tester.ensureVisible(heading);
    final paragraph = tester.renderObject<RenderParagraph>(heading);
    expect(
      paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 8, extentOffset: 21),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('About explains the current workflow and visual maturity labels', (
    tester,
  ) async {
    await _showAbout(tester);

    expect(find.text('About Calabash Maturity Detection'), findsOneWidget);
    expect(find.text(_purpose), findsOneWidget);
    for (final section in _sections) {
      expect(find.text(section), findsOneWidget);
    }
    expect(
      find.textContaining(
        'Take a photo using the camera or choose an image from the gallery.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'The trained detection model identifies calabash fruits.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Segmentation highlights the detected fruit regions.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'The app displays the predicted maturity stage for each detected fruit.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('visually predicted maturity categories'),
      findsOneWidget,
    );
    for (final label in ['Immature:', 'Mature:', 'Overmature:']) {
      expect(find.textContaining(label), findsOneWidget);
    }
    expect(find.textContaining('faster and more accurate'), findsNothing);
    expect(find.textContaining('MobileNetV3'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'About explains score limits and tips with existing credits and offline notice',
    (tester) async {
      await _showAbout(tester);

      expect(find.text(_confidence), findsOneWidget);
      expect(find.textContaining(_limitations), findsOneWidget);
      expect(find.textContaining(_inspection), findsOneWidget);
      for (final tip in [
        'Use adequate lighting.',
        'Keep the fruit clearly visible.',
        'Hold the camera steady.',
        'Avoid excessive distance.',
        'Try another angle if detection fails.',
      ]) {
        expect(find.textContaining(tip), findsOneWidget);
      }
      expect(find.text(_offline), findsOneWidget);
      expect(find.text(_developers), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(2));
    },
  );

  testWidgets(
    'Home still opens About and Back returns to the same Home route',
    (tester) async {
      final provider = DetectionProvider(
        modelService: TestModelService(),
        imageService: TestImageService(() async => null),
      );
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<DetectionProvider>.value(
          value: provider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final home = tester.element(find.byType(HomeScreen));
      await tester.tap(find.byTooltip('About this project'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'About'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(AboutScreen), findsNothing);
      expect(tester.element(find.byType(HomeScreen)), same(home));
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in [
    (size: const Size(320, 568), scale: 1.0),
    (size: const Size(320, 568), scale: 2.0),
    (size: const Size(568, 320), scale: 2.0),
    (size: const Size(844, 390), scale: 2.0),
  ]) {
    testWidgets(
      'About scrolls without overflow at ${layout.size}, ${layout.scale}x text',
      (tester) async {
        tester.view.physicalSize = layout.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _showAbout(tester, textScale: layout.scale);

        expect(tester.takeException(), isNull);
        for (final section in _sections) {
          await tester.ensureVisible(find.text(section));
          await tester.pumpAndSettle();
          expect(find.text(section).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.ensureVisible(find.text(_offline));
        await tester.pumpAndSettle();
        expect(find.text(_offline).hitTestable(), findsOneWidget);
        expect(
          tester.getSize(find.byType(SingleChildScrollView)).width,
          lessThanOrEqualTo(layout.size.width),
        );
        expect(
          MediaQuery.textScalerOf(
            tester.element(find.text(_offline)),
          ).scale(14),
          closeTo(14 * layout.scale, .01),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
