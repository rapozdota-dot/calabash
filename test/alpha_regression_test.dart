import 'dart:async';
import 'dart:io';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:calabash_maturity_detection/widgets/detection_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'detection_provider_test.dart' show TestImageService, TestModelService;

const fruit = Detection(
  boundingBox: Rect.fromLTWH(.8, .85, .18, .14),
  maturityClass: MaturityClass.overmature,
  confidence: .91,
);

DetectionProvider detector(Future<List<Detection>> Function() infer) =>
    DetectionProvider(
      modelService: TestModelService(infer: infer),
      imageService: TestImageService(() async => null),
    );

Future<void> showResult(WidgetTester tester, DetectionProvider provider) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<DetectionProvider>.value(
      value: provider,
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: const ResultScreen(),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'TC51/52 all theme fonts load from assets with fetching disabled',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      await tester.runAsync(() async {
        GoogleFonts.nunitoSansTextTheme(
          ThemeData(useMaterial3: true).textTheme,
        );
        await GoogleFonts.pendingFonts();
      });
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'TC14 cancelling replacement preserves nonempty detections and guidance',
    () async {
      final provider = detector(() async => [fruit]);
      addTearDown(provider.dispose);
      final image = File('original.jpg');
      await provider.scanFile(image);
      final guidance = provider.recommendation;
      expect(await provider.scanFromSource(ImageSource.gallery), isFalse);
      expect(provider.selectedImage, image);
      expect(provider.detections, [fruit]);
      expect(provider.recommendation, guidance);
    },
  );

  test(
    'TC81/98 consecutive empty and fruit results replace all counts',
    () async {
      var empty = true;
      final provider = detector(() async => empty ? [] : [fruit]);
      addTearDown(provider.dispose);
      for (var i = 0; i < 10; i++) {
        empty = i.isEven;
        final image = File('photo-$i.jpg');
        expect(await provider.scanFile(image), isTrue);
        expect(provider.selectedImage, image);
        expect(provider.totalDetected, empty ? 0 : 1);
        expect(provider.overmatureCount, empty ? 0 : 1);
        expect(
          provider.matureCount +
              provider.immatureCount +
              provider.overmatureCount,
          provider.totalDetected,
        );
        expect(provider.errorMessage, isNull);
      }
    },
  );

  testWidgets('TC83 Back from replacement analysis discards its late result', (
    tester,
  ) async {
    final pending = Completer<List<Detection>>();
    var replacing = false;
    final provider = detector(
      () => replacing ? pending.future : Future.value([]),
    );
    addTearDown(provider.dispose);
    await provider.scanFile(File('first.jpg'));
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ChangeNotifierProvider<DetectionProvider>.value(
        value: provider,
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const ResultScreen()),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    replacing = true;
    final scan = provider.scanFile(File('second.jpg'));
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    pending.complete([fruit]);
    expect(await scan, isFalse);
    await tester.pump();
    expect(find.text('Home'), findsOneWidget);
    expect(provider.selectedImage, isNull);
    expect(provider.detections, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test(
    'TC83 clearing a pending scan prevents late result publication',
    () async {
      final pending = Completer<List<Detection>>();
      final provider = detector(() => pending.future);
      addTearDown(provider.dispose);
      final scan = provider.scanFile(File('cancelled.jpg'));
      provider.clearCurrentResult();
      pending.complete([fruit]);
      expect(await scan, isFalse);
      expect(provider.selectedImage, isNull);
      expect(provider.detections, isEmpty);
      expect(provider.isBusy, isFalse);
    },
  );

  test(
    'TC87 disposal during inference does not notify disposed listeners',
    () async {
      final pending = Completer<List<Detection>>();
      final provider = detector(() => pending.future);
      final scan = provider.scanFile(File('pending.jpg'));
      provider.dispose();
      pending.complete([fruit]);
      expect(await scan, isFalse);
    },
  );

  test('TC79 failed replacement clears previous harvest guidance', () async {
    var fails = false;
    final provider = detector(() async {
      if (fails) throw StateError('invalid image');
      return [fruit];
    });
    addTearDown(provider.dispose);
    await provider.scanFile(File('good.jpg'));
    fails = true;
    expect(await provider.scanFile(File('bad.jpg')), isFalse);
    expect(provider.detections, isEmpty);
    expect(provider.recommendation, isNot(contains('overripe')));
    expect(provider.isBusy, isFalse);
  });

  testWidgets(
    'TC79 failed inference is not presented as a negative detection',
    (tester) async {
      final provider = detector(() async => throw StateError('invalid image'));
      addTearDown(provider.dispose);
      await provider.scanFile(File('bad.jpg'));
      await showResult(tester, provider);
      expect(find.text('No calabash fruits detected'), findsNothing);
      expect(find.text('Analysis could not be completed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TC08 result guidance fits narrow screens with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = detector(() async => [fruit]);
    addTearDown(provider.dispose);
    await provider.scanFile(File('fruit.jpg'));
    await showResult(tester, provider);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Capture Again'), 120);
    expect(tester.takeException(), isNull);
    expect(find.text('Try Another Image'), findsOneWidget);
  });

  for (final size in [const Size(80, 240), const Size(320, 180)]) {
    testWidgets('TC74/75 edge labels stay inside image $size', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: Center(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(
                  key: const ValueKey('image'),
                  children: [
                    DetectionBox(
                      detection: fruit,
                      fruitNumber: 1,
                      imageWidth: size.width,
                      imageHeight: size.height,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final image = tester.getRect(find.byKey(const ValueKey('image')));
      final label = tester.getRect(find.text('#1 Overmature 91%'));
      expect(label.left, greaterThanOrEqualTo(image.left));
      expect(label.right, lessThanOrEqualTo(image.right));
      expect(label.bottom, lessThanOrEqualTo(image.bottom));
    });
  }
}
