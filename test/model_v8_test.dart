import 'dart:typed_data';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/image_tensor_layout.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

void main() {
  const input = (shape: [1, 3, 224, 224], type: TensorType.float32);
  const detections = (shape: [1, 39, 1029], type: TensorType.float32);
  const prototypes = (shape: [1, 32, 56, 56], type: TensorType.float32);
  test('requires the V8 FP32 signature and resolves either output order', () {
    expect(
      ModelService.validateModelSignature(
        inputs: [input],
        outputs: [prototypes, detections],
      ),
      (detection: 1, prototypes: 0),
    );
    for (final invalidInput in [
      (shape: [1, 3, 640, 640], type: TensorType.float32),
      (shape: [1, 224, 224, 3], type: TensorType.float32),
      (shape: input.shape, type: TensorType.uint8),
    ]) {
      expect(
        () => ModelService.validateModelSignature(
          inputs: [invalidInput],
          outputs: [detections, prototypes],
        ),
        throwsStateError,
      );
    }
    for (final invalidOutputs in [
      [detections, detections],
      [
        detections,
        (shape: [1, 56, 56, 32], type: TensorType.float32),
      ],
      [detections, (shape: prototypes.shape, type: TensorType.int8)],
      [detections, prototypes, prototypes],
    ]) {
      expect(
        () => ModelService.validateModelSignature(
          inputs: [input],
          outputs: invalidOutputs,
        ),
        throwsStateError,
      );
    }
  });

  const anchors = 1029;
  const side = 56;
  late Float32List raw;
  late Float32List proto;
  late LetterboxTransform letterbox;
  setUp(() {
    raw = Float32List(39 * anchors);
    proto = Float32List(32 * side * side);
    letterbox = LetterboxTransform(
      sourceWidth: 448,
      sourceHeight: 224,
      inputSize: 224,
    );
    // Positive upper-left half of each box comes from the last prototype plane.
    final offset = 31 * side * side;
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        proto[offset + y * side + x] = y < 28 && x % 14 < 7 ? 3 : -3;
      }
    }
  });

  void candidate(
    int anchor,
    double cx,
    int cls,
    double score, {
    double cy = 0.5,
    double coeff = 1,
    double width = 0.25,
  }) {
    raw[anchor] = cx;
    raw[anchors + anchor] = cy;
    raw[2 * anchors + anchor] = width;
    raw[3 * anchors + anchor] = 0.25;
    raw[(4 + cls) * anchors + anchor] = score;
    raw[38 * anchors + anchor] = coeff;
  }

  List<Detection> decode({double threshold = 0.45}) =>
      ModelService(confidenceThreshold: threshold).decodeOutputsForTest(
        detectionOutput: raw,
        prototypes: proto,
        letterbox: letterbox,
      );

  test('decodes distinct maturity stages and aligned instance silhouettes', () {
    candidate(0, 0.125, 0, 0.98);
    candidate(1, 0.130, 0, 0.70); // Same-stage duplicate.
    candidate(2, 0.375, 1, 0.92);
    candidate(1028, 0.625, 2, 0.87); // Last candidate in each channel.
    candidate(3, 0.875, 1, 0.44); // Below threshold.
    candidate(4, 0.875, 2, 0.9, cy: 0.1); // Entirely in letterbox padding.
    candidate(5, 0.875, 2, 0.9, coeff: 0); // No mask.
    final result = decode();
    expect(result.map((fruit) => fruit.maturityClass), [
      MaturityClass.immature,
      MaturityClass.mature,
      MaturityClass.overmature,
    ]);
    expect(result.first.confidence, closeTo(0.98, 1e-6));
    expect(result.first.boundingBox, const Rect.fromLTWH(0, 0.25, 0.25, 0.5));
    for (final fruit in result) {
      final mask = fruit.mask!;
      expect(mask.bounds, fruit.boundingBox);
      expect(mask.isActive(mask.width ~/ 4, mask.height ~/ 4), isTrue);
      expect(mask.isActive(3 * mask.width ~/ 4, mask.height ~/ 4), isFalse);
      expect(mask.isActive(mask.width ~/ 4, 3 * mask.height ~/ 4), isFalse);
    }
    expect(decode(threshold: 0.90).length, 2);
  });

  test('rejects malformed tensors and skips invalid or empty candidates', () {
    expect(
      () => ModelService().decodeOutputsForTest(
        detectionOutput: Float32List(39),
        prototypes: proto,
        letterbox: letterbox,
      ),
      throwsArgumentError,
    );
    candidate(0, 0.125, 0, 1.1);
    candidate(1, double.nan, 1, 0.95);
    candidate(2, 0.625, 2, 0.88, coeff: double.nan);
    candidate(3, 0.875, 2, 0.88, width: 0);
    expect(decode(), isEmpty);
  });
}
