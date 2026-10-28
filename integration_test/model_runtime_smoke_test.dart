// Runs in an iOS simulator/device, against the same native TFLite pod as Runner.
// Deterministic synthetic images prove execution/contract compatibility, not
// fruit recognition quality or physical-device performance.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

void checkResult(ModelDetectionResult result) {
  final times = result.timings;
  expect(times.invokeMicros, isNonNegative);
  expect(times.inputTensorMicros, isNonNegative);
  expect(times.outputTensorMicros, isNonNegative);
  expect(
    times.inferenceMicros,
    times.inputTensorMicros! + times.invokeMicros! + times.outputTensorMicros!,
  );
  expect(times.totalMicros, greaterThanOrEqualTo(times.inferenceMicros));
  for (final detection in result.detections) {
    expect(detection.maturityClass, isNot(MaturityClass.unknown));
    expect(detection.confidence.isFinite, isTrue);
    expect(detection.confidence, inInclusiveRange(0, 1));
    expect(detection.boundingBox.width, greaterThan(0));
    expect(detection.boundingBox.height, greaterThan(0));
    final mask = detection.mask;
    expect(mask, isNotNull);
    expect(mask!.pixels.length, mask.width * mask.height);
    expect(mask.pixels.any((pixel) => pixel != 0), isTrue);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bundled model executes in native iOS TFLite and parses every output',
    (tester) async {
      expect(
        Platform.isIOS,
        isTrue,
        reason: 'Run this smoke test with an iOS target.',
      );
      await tester.runAsync(() async {
        final options = InterpreterOptions()..threads = 2;
        final interpreter = await Interpreter.fromAsset(
          AppConstants.modelAssetPath,
          options: options,
        );
        options.delete();
        try {
          final input = interpreter.getInputTensor(0);
          expect(input.type, TensorType.float32);
          expect(input.shape.join(','), anyOf('1,3,640,640', '1,640,640,3'));
          final outputs = interpreter.getOutputTensors();
          expect(outputs, hasLength(2));
          expect(
            outputs.map((output) => output.shape.join(',')),
            contains('1,39,8400'),
          );
          expect(
            outputs.map((output) => output.shape.join(',')),
            contains(anyOf('1,32,160,160', '1,160,160,32')),
          );
          // A neutral RGB input is independent of NHWC/NCHW layout.
          final pixels = Float32List(640 * 640 * 3)
            ..fillRange(0, 640 * 640 * 3, 114 / 255);
          input.data = pixels.buffer.asUint8List();
          interpreter.invoke();
          for (final output in interpreter.getOutputTensors()) {
            expect(output.type, TensorType.float32);
            final values = output.data.buffer.asFloat32List();
            expect(
              values.every((value) => value.isFinite),
              isTrue,
              reason: 'Nonfinite native output: ${output.shape}',
            );
            if (output.shape.join(',') == '1,39,8400') {
              for (var channel = 4; channel < 7; channel++) {
                expect(
                  values
                      .sublist(channel * 8400, (channel + 1) * 8400)
                      .every((score) => score >= 0 && score <= 1),
                  isTrue,
                );
              }
            }
            // Contract evidence only; these are not device benchmark results.
            // ignore: avoid_print
            print(
              'Native iOS TFLite output ${output.shape}: ${output.type}, finite',
            );
          }
        } finally {
          interpreter.close();
        }

        final image = img.Image(width: 96, height: 64);
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            image.setPixelRgb(
              x,
              y,
              x * 255 ~/ 95,
              y * 255 ~/ 63,
              (x + y) % 256,
            );
          }
        }
        // Exercise real file decode/EXIF, non-square letterbox, parsing and masks
        // through the application's photo worker, at unchanged production thresholds.
        final directory = await Directory.systemTemp.createTemp(
          'calabash-model-smoke-',
        );
        final service = ModelService();
        try {
          final file = await File(
            '${directory.path}/pattern.png',
          ).writeAsBytes(img.encodePng(image));
          final photo = await service.detectFruitsWithMetrics(file);
          expect([photo.imageWidth, photo.imageHeight], [96, 64]);
          expect(photo.fileReadMicros, isNonNegative);
          expect(photo.decodeMicros, isNonNegative);
          expect(photo.modelInitializationMicros, isNonNegative);
          checkResult(photo.modelResult);
          // ignore: avoid_print
          print(
            'Native photo pipeline: ${photo.modelResult.detections.length} detections parsed',
          );
        } finally {
          service.dispose();
          await directory.delete(recursive: true);
        }

        // Exercise native live backend fallback, BGRA conversion and real isolate
        // transport. Startup or invocation incompatibility must fail before packaging.
        final worker = LiveInferenceWorker();
        try {
          await worker.start();
          final bytes = Uint8List(96 * 64 * 4);
          for (var i = 0; i < bytes.length; i += 4) {
            bytes[i] = 114;
            bytes[i + 1] = 114;
            bytes[i + 2] = 114;
            bytes[i + 3] = 255;
          }
          final result = await worker.detect(
            LiveInferenceFrame(
              frameId: 1,
              transferTimer: Stopwatch()..start(),
              width: 96,
              height: 64,
              format: LiveInferenceImageFormat.bgra8888,
              rotationDegrees: 0,
              isFrontCamera: false,
              planes: [
                LiveInferencePlane(
                  bytes: TransferableTypedData.fromList([bytes]),
                  bytesPerRow: 96 * 4,
                  bytesPerPixel: 4,
                ),
              ],
            ),
          );
          expect(result.frameTransferMicros, isNonNegative);
          checkResult(
            ModelDetectionResult(
              detections: result.toDetections(),
              timings: result.modelTimings,
            ),
          );
          // Metadata ordering is also checked by tool/validate_ios_release.py.
          for (var index = 0; index < 3; index++) {
            expect(
              LiveInferenceDetection(
                left: 0,
                top: 0,
                width: 1,
                height: 1,
                classIndex: index,
                confidence: 1,
              ).toDetection().maturityClass,
              [
                MaturityClass.immature,
                MaturityClass.mature,
                MaturityClass.overmature,
              ][index],
            );
          }
          // ignore: avoid_print
          print(
            'Native live pipeline: ${result.backendInfo.label}, ${result.detections.length} detections parsed',
          );
        } finally {
          await worker.dispose();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
