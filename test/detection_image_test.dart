import 'dart:io';
import 'dart:ui' as ui;

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
