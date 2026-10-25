import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:calabash_maturity_detection/widgets/detection_image.dart';
import 'package:calabash_maturity_detection/widgets/result_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'detection_provider_test.dart' show TestImageService, TestModelService;

const _confidenceExplanation =
    "The model confidence score indicates how strongly the model favors the predicted maturity class. It does not represent the model's measured accuracy or statistical margin of error.";
const _externalAssessment =
    'This application estimates calabash maturity based on visible surface characteristics. It cannot determine internal ripeness, internal quality, or fruit safety. Additional inspection is recommended before harvesting or use.';
const _segmentationExplanation =
    'The highlighted areas show the fruit regions identified by the detection model. These outlines are predictions and may not perfectly match the actual fruit boundaries.';
const _noDetectionExplanation =
    'No calabash fruit was detected in this image. This does not necessarily mean no fruit is present. Try using better lighting, moving closer, or capturing the fruit from another angle.';

// Synthetic UI fixtures; these scores are not model evaluation results.
final _mask = SegmentationMask(
  bounds: const Rect.fromLTWH(.2, .2, .5, .5),
  width: 2,
  height: 2,
  pixels: Uint8List.fromList([1, 1, 1, 1]),
);
final _mature = Detection(
  boundingBox: const Rect.fromLTWH(.2, .2, .5, .5),
  maturityClass: MaturityClass.mature,
  confidence: .864,
  mask: _mask,
);
final _multiple = [
  _mature,
  Detection(
    boundingBox: const Rect.fromLTWH(.05, .05, .3, .3),
    maturityClass: MaturityClass.immature,
    confidence: .735,
    mask: _mask,
  ),
  Detection(
    boundingBox: const Rect.fromLTWH(.6, .6, .3, .3),
    maturityClass: MaturityClass.overmature,
    confidence: .914,
    mask: _mask,
  ),
];

DetectionProvider _provider(Future<List<Detection>> Function() infer) {
  final provider = DetectionProvider(
    modelService: TestModelService(infer: infer),
    imageService: TestImageService(() async => null),
  );
  addTearDown(provider.dispose);
  return provider;
}

Future<void> _showResult(
  WidgetTester tester,
  DetectionProvider provider,
  File image, {
  double textScale = 1.8,
}) async {
  // Resolve the real file image outside the test's fake async zone.
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ChangeNotifierProvider<DetectionProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const ResultScreen(),
        ),
      ),
    );
    await precacheImage(
      FileImage(image),
      tester.element(find.byType(ResultScreen)),
    );
  });
  await tester.pump();
}

void _expectSingleNoticeBelowGuidance(WidgetTester tester) {
  expect(find.text('External Assessment Only'), findsOneWidget);
  expect(find.text(_externalAssessment), findsOneWidget);
  expect(
    tester.getTopLeft(find.text('External Assessment Only')).dy,
    greaterThan(tester.getBottomLeft(find.text('Suggested guidance')).dy),
  );
}

void main() {
  late Directory directory;
  late File image;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('calabash-result-info-');
    image = File('${directory.path}/photo.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 32, height: 32)));
  });

  tearDown(() {
    image.deleteSync();
    directory.deleteSync();
  });

  testWidgets('single result explains confidence without changing the score', (
    tester,
  ) async {
    final provider = _provider(() async => [_mature]);
    await provider.scanFile(image);
    await _showResult(tester, provider, image);

    expect(find.text('86% Model confidence score'), findsOneWidget);
    expect(find.textContaining('AI confidence'), findsNothing);
    expect(find.text('MATURE'), findsOneWidget);
    expect(find.text('#1 Mature 86%'), findsOneWidget);
    expect(provider.detections.single.confidence, .864);

    final info = find.byTooltip('About model confidence score');
    await tester.ensureVisible(info);
    await tester.pumpAndSettle();
    final infoSemantics = tester.getSemantics(info).getSemanticsData();
    expect(infoSemantics.tooltip, 'About model confidence score');
    expect(infoSemantics.flagsCollection.isButton, isTrue);
    expect(infoSemantics.hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(info);
    await tester.pumpAndSettle();
    expect(find.text(_confidenceExplanation), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text(_confidenceExplanation), findsNothing);
    expect(provider.detections.single.confidence, .864);
  });

  for (final detections in [
    <Detection>[_mature],
    _multiple,
  ]) {
    testWidgets(
      'shows one visible assessment notice for ${detections.length} fruits',
      (tester) async {
        final provider = _provider(() async => detections);
        await provider.scanFile(image);
        await _showResult(tester, provider, image);

        _expectSingleNoticeBelowGuidance(tester);
        await tester.ensureVisible(find.text(_externalAssessment));
        await tester.pumpAndSettle();
        expect(find.text(_externalAssessment).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('multiple results retain counts, labels, and rounded scores', (
    tester,
  ) async {
    final provider = _provider(() async => _multiple);
    await provider.scanFile(image);
    await _showResult(tester, provider, image);

    expect(find.text('3 calabash fruits detected'), findsOneWidget);
    for (final label in ['1 Mature', '1 Immature', '1 Overmature']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(ResultCard), findsNWidgets(3));
    for (final score in ['86%', '74%', '91%']) {
      expect(find.text('$score Model confidence score'), findsOneWidget);
    }
    final info = find.byTooltip('About model confidence score').last;
    await tester.ensureVisible(info);
    await tester.pumpAndSettle();
    await tester.tap(info);
    await tester.pumpAndSettle();
    expect(find.text(_confidenceExplanation), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('segmentation help preserves the image and original detections', (
    tester,
  ) async {
    final provider = _provider(() async => _multiple);
    await provider.scanFile(image);
    await _showResult(tester, provider, image);

    final displayedImage = tester.widget<DetectionImage>(
      find.byType(DetectionImage),
    );
    expect(displayedImage.imageFile, image);
    expect(displayedImage.detections, same(provider.detections));
    expect(displayedImage.detections.first.mask, same(_mask));
    await tester.tap(find.byTooltip('About highlighted fruit regions'));
    await tester.pumpAndSettle();
    expect(find.text(_segmentationExplanation), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty result clarifies missed detection and preserves retries', (
    tester,
  ) async {
    final provider = _provider(() async => []);
    await provider.scanFile(image);
    await _showResult(tester, provider, image);

    expect(find.text('No calabash fruits detected'), findsOneWidget);
    expect(find.text(_noDetectionExplanation), findsOneWidget);
    expect(find.text('External Assessment Only'), findsNothing);
    expect(find.byTooltip('About model confidence score'), findsNothing);
    await tester.ensureVisible(find.text('Try Another Image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try Another Image'));
    await tester.pumpAndSettle();
    expect(find.text(_noDetectionExplanation), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Capture Again'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('analysis failure does not show successful result explanations', (
    tester,
  ) async {
    final provider = _provider(() async => throw StateError('test failure'));
    await provider.scanFile(image);
    await _showResult(tester, provider, image);

    expect(find.text('Analysis could not be completed'), findsOneWidget);
    expect(find.text(_noDetectionExplanation), findsNothing);
    expect(find.text('External Assessment Only'), findsNothing);
    expect(find.byTooltip('About model confidence score'), findsNothing);
    expect(find.byTooltip('About highlighted fruit regions'), findsNothing);
  });

  testWidgets('assessment notice waits until analysis completes successfully', (
    tester,
  ) async {
    final pending = Completer<List<Detection>>();
    final provider = _provider(() => pending.future);
    final scan = provider.scanFile(image);
    await _showResult(tester, provider, image);
    expect(find.text('Analyzing image...'), findsOneWidget);
    expect(find.text('External Assessment Only'), findsNothing);
    pending.complete([_mature]);
    await scan;
    await tester.pumpAndSettle();
    _expectSingleNoticeBelowGuidance(tester);
  });

  for (final size in [
    const Size(320, 568),
    const Size(568, 320),
    const Size(844, 390),
  ]) {
    for (final detections in [
      <Detection>[],
      <Detection>[_mature],
      _multiple,
    ]) {
      testWidgets('result ${detections.length} fruits fits $size at 2x text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final provider = _provider(() async => detections);
        await provider.scanFile(image);
        await _showResult(tester, provider, image, textScale: 2);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Capture Again'));
        await tester.pumpAndSettle();
        expect(find.text('Capture Again').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (detections.isNotEmpty) {
          await tester.ensureVisible(
            find.byTooltip('About model confidence score').first,
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byTooltip('About model confidence score').first,
          );
          await tester.pumpAndSettle();
          expect(find.text(_confidenceExplanation), findsOneWidget);
          await tester.ensureVisible(find.text('Close'));
          await tester.pumpAndSettle();
          expect(find.text('Close').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
