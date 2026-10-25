import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/widgets/detection_box.dart';
import 'package:calabash_maturity_detection/widgets/detection_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingImageProvider extends ImageProvider<_CountingImageProvider> {
  _CountingImageProvider(this.image);
  final ui.Image image;
  int loads = 0;

  @override
  Future<_CountingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _CountingImageProvider key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: image.clone())),
    );
  }
}

void main() {
  for (final dimensions in [const Size(40, 160), const Size(160, 40)]) {
    testWidgets('preview fits $dimensions without letterboxing or mask drift', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final picture = ui.PictureRecorder();
      Canvas(picture).drawColor(Colors.green, BlendMode.src);
      final recording = picture.endRecording();
      final image = (await tester.runAsync(
        () => recording.toImage(
          dimensions.width.toInt(),
          dimensions.height.toInt(),
        ),
      ))!;
      recording.dispose();
      final provider = _CountingImageProvider(image);
      final mask = SegmentationMask(
        bounds: const Rect.fromLTWH(.2, .2, .4, .4),
        width: 2,
        height: 2,
        pixels: Uint8List.fromList([1, 0, 0, 1]),
      );
      final detection = Detection(
        boundingBox: Rect.fromLTWH(.2, .2, .4, .4),
        maturityClass: MaturityClass.mature,
        confidence: .864,
        mask: mask,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DetectionImage(
                imageFile: File('geometry.png'),
                imageProvider: provider,
                detections: [detection],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rawRect = tester.getRect(find.byType(RawImage));
      final previewRect = tester.getRect(find.byType(Card));
      expect(rawRect.size.aspectRatio, closeTo(dimensions.aspectRatio, .001));
      expect(previewRect.size, rawRect.size);
      expect(previewRect.height, lessThanOrEqualTo(568 * .5));
      final overlay = tester.widget<DetectionBox>(find.byType(DetectionBox));
      expect(overlay.detection, same(detection));
      expect(overlay.detection.mask, same(mask));
      expect(overlay.detection.mask!.pixels, orderedEquals([1, 0, 0, 1]));
      expect(overlay.imageWidth, closeTo(rawRect.width, .001));
      expect(overlay.imageHeight, closeTo(rawRect.height, .001));
      expect(overlay.offsetX, closeTo(0, .001));
      expect(overlay.offsetY, closeTo(0, .001));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.binding.imageCache.clear();
      tester.binding.imageCache.clearLiveImages();
      image.dispose();
    });
  }

  for (final maturity in [
    MaturityClass.immature,
    MaturityClass.mature,
    MaturityClass.overmature,
  ]) {
    testWidgets(
      '${maturity.label} overlay label has readable status contrast',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                height: 240,
                child: Stack(
                  children: [
                    DetectionBox(
                      detection: Detection(
                        boundingBox: const Rect.fromLTWH(.2, .2, .4, .4),
                        maturityClass: maturity,
                        confidence: .864,
                      ),
                      fruitNumber: 1,
                      imageWidth: 320,
                      imageHeight: 240,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final text = tester.widget<Text>(find.text('#1 ${maturity.label} 86%'));
        final foreground = text.style!.color!.computeLuminance();
        final background = maturity.color.computeLuminance();
        final contrast =
            (math.max(foreground, background) + .05) /
            (math.min(foreground, background) + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('changing overlays reuses the decoded image and dimensions', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 40, 20),
      Paint()..color = Colors.green,
    );
    final picture = recorder.endRecording();
    final image = (await tester.runAsync(() => picture.toImage(40, 20)))!;
    picture.dispose();
    final provider = _CountingImageProvider(image);
    final file = File('cached.jpg');
    Future<void> show(List<Detection> detections) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DetectionImage(
            imageFile: file,
            imageProvider: provider,
            detections: detections,
          ),
        ),
      ),
    );
    await show([]);
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget);
    expect(provider.loads, 1);
    await show([
      const Detection(
        boundingBox: Rect.fromLTWH(.2, .2, .4, .4),
        maturityClass: MaturityClass.mature,
        confidence: .95,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(DetectionBox), findsOneWidget);
    expect(provider.loads, 1);
    final rendered = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect([rendered.width, rendered.height], [40, 20]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.binding.imageCache.clear();
    tester.binding.imageCache.clearLiveImages();
    image.dispose();
    expect(tester.takeException(), isNull);
  });
}
