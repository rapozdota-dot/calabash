import 'dart:typed_data';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/segmentation_postprocessor.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'near-identical conflicting maturity predictions count as one fruit',
    () {
      final candidates = [
        const Detection(
          boundingBox: Rect.fromLTWH(.1, .1, .3, .3),
          maturityClass: MaturityClass.mature,
          confidence: .95,
        ),
        const Detection(
          boundingBox: Rect.fromLTWH(.105, .1, .3, .3),
          maturityClass: MaturityClass.immature,
          confidence: .85,
        ),
      ];
      expect(
        SegmentationPostprocessor.suppressDuplicates(
          candidates,
          boxOf: (d) => d.boundingBox,
          confidenceOf: (d) => d.confidence,
          classOf: (d) => d.maturityClass.index,
          iouThreshold: .6,
          maxDetections: 20,
        ),
        [candidates.first],
      );
    },
  );

  test('mask support rejects sparse speckles and nonfinite crop pixels', () {
    bool supported(Float32List logits) =>
        SegmentationPostprocessor.hasMaskSupport(
          logits: logits,
          modelBox: const Rect.fromLTWH(0, 0, 640, 640),
          modelSize: 640,
          width: 10,
          height: 10,
          threshold: 0,
          minimumPixels: 4,
          minimumFraction: .10,
        );
    final sparse = Float32List(100)..fillRange(0, 4, 1);
    expect(supported(sparse), isFalse);
    final valid = Float32List(100)..fillRange(0, 60, 1);
    expect(supported(valid), isTrue);
    valid[99] = double.nan;
    expect(supported(valid), isFalse);
  });

  test('NMS rejects invalid scores, class IDs and degenerate boxes', () {
    final candidates = [
      (box: const Rect.fromLTWH(0, 0, 1, 1), score: double.nan, cls: 0),
      (box: const Rect.fromLTWH(0, 0, 1, 1), score: 1.1, cls: 0),
      (box: const Rect.fromLTWH(0, 0, 1, 1), score: .9, cls: 3),
      (box: const Rect.fromLTWH(0, 0, 0, 1), score: .9, cls: 0),
    ];
    expect(
      SegmentationPostprocessor.suppressDuplicates(
        candidates,
        boxOf: (d) => d.box,
        confidenceOf: (d) => d.score,
        classOf: (d) => d.cls,
        iouThreshold: .6,
        maxDetections: 20,
      ),
      isEmpty,
    );
  });
  test('suppresses same-stage duplicates, keeps adjacent fruits', () {
    const box = Rect.fromLTWH(0.1, 0.1, 0.3, 0.3);
    const strong = Detection(
      boundingBox: box,
      maturityClass: MaturityClass.mature,
      confidence: 0.95,
    );
    const duplicate = Detection(
      boundingBox: Rect.fromLTWH(0.11, 0.1, 0.3, 0.3),
      maturityClass: MaturityClass.mature,
      confidence: 0.78,
    );
    const adjacent = Detection(
      boundingBox: Rect.fromLTWH(0.35, 0.1, 0.3, 0.3),
      maturityClass: MaturityClass.immature,
      confidence: 0.85,
    );
    final result = SegmentationPostprocessor.suppressDuplicates(
      [duplicate, adjacent, strong],
      boxOf: (d) => d.boundingBox,
      confidenceOf: (d) => d.confidence,
      classOf: (d) => d.maturityClass.index,
      iouThreshold: 0.6,
      maxDetections: 20,
    );
    expect(result, [strong, adjacent]);
  });

  test(
    'keeps overlapping fruits of different stages in live and photo NMS',
    () {
      const mature = Detection(
        boundingBox: Rect.fromLTWH(.1, .1, .3, .3),
        maturityClass: MaturityClass.mature,
        confidence: .95,
      );
      const immature = Detection(
        boundingBox: Rect.fromLTWH(.17, .1, .3, .3),
        maturityClass: MaturityClass.immature,
        confidence: .90,
      );
      expect(
        SegmentationPostprocessor.intersectionOverUnion(
          mature.boundingBox,
          immature.boundingBox,
        ),
        greaterThan(.6),
      );
      for (final limit in [20, 300]) {
        final kept = SegmentationPostprocessor.suppressDuplicates(
          [immature, mature],
          boxOf: (d) => d.boundingBox,
          confidenceOf: (d) => d.confidence,
          classOf: (d) => d.maturityClass.index,
          iouThreshold: .6,
          maxDetections: limit,
        );
        expect(kept, [mature, immature]);
      }
    },
  );

  test(
    'cropped mask math matches full dot product inside box and clears stale pixels',
    () {
      final coefficients = Float32List.fromList([2, -1]);
      final prototypes = Float32List.fromList(
        List.generate(32, (i) => i.toDouble()),
      );
      final logits = Float32List(16)..fillRange(0, 16, 99);
      SegmentationPostprocessor.reconstructMask(
        coefficients: coefficients,
        prototypes: prototypes,
        logits: logits,
        modelBox: const Rect.fromLTWH(1, 1, 2, 2),
        modelSize: 4,
        width: 4,
        height: 4,
      );
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final index = y * 4 + x;
          final expected = x >= 1 && x < 3 && y >= 1 && y < 3
              ? coefficients[0] * prototypes[index] +
                    coefficients[1] * prototypes[16 + index]
              : 0.0;
          expect(logits[index], expected);
        }
      }
    },
  );

  test('one positive prototype pixel is not sufficient mask evidence', () {
    final logits = Float32List(16)..[5] = 1;
    bool supported() => SegmentationPostprocessor.hasMaskSupport(
      logits: logits,
      modelBox: const Rect.fromLTWH(0, 0, 4, 4),
      modelSize: 4,
      width: 4,
      height: 4,
      threshold: 0,
      minimumPixels: 4,
      minimumFraction: 0.01,
    );
    expect(supported(), isFalse);
    for (final i in [6, 9, 10]) {
      logits[i] = 1;
    }
    expect(supported(), isTrue);
  });

  test('sparse masks can vanish after smoothing and must not be counted', () {
    final source = Uint8List(16)..[5] = 1;
    final smoothed = SegmentationPostprocessor.smoothMask(source, 4, 4);
    final mask = SegmentationMask(
      bounds: const Rect.fromLTWH(0, 0, 1, 1),
      width: 4,
      height: 4,
      pixels: smoothed,
    );
    expect(mask.isEmpty, isTrue);
  });

  test(
    'invalid coefficients fail explicitly rather than producing a maskless label',
    () {
      expect(
        () => SegmentationPostprocessor.reconstructMask(
          coefficients: Float32List.fromList([double.nan]),
          prototypes: Float32List(16),
          logits: Float32List(16),
          modelBox: const Rect.fromLTWH(0, 0, 4, 4),
          modelSize: 4,
          width: 4,
          height: 4,
        ),
        throwsStateError,
      );
    },
  );
}
