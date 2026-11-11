// Runs in an iOS simulator/device, against the same native TFLite pod as Runner.
// Deterministic synthetic images prove execution/contract compatibility, not
// fruit recognition quality or physical-device performance.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:calabash_maturity_detection/integration_test/smoke_stage_runner.dart';
import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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

Future<void> _verifyNativeModel(TransferableTypedData model) =>
    Isolate.run(() => _runNativePreflight(model));

Future<void> _runNativePreflight(TransferableTypedData model) async {
  final stages = SmokeStageRunner();
  final cleanup = SmokeCleanupStack(stages);
  await runWithSmokeCleanup<void>(
    runner: stages,
    cleanup: cleanup,
    operation: () async {
      final interpreter = stages.runSync(
        'TFLite interpreter creation and tensor allocation',
        () {
          final options = InterpreterOptions()..threads = 2;
          try {
            // tflite_flutter allocates tensors in the interpreter constructor.
            return Interpreter.fromBuffer(
              model.materialize().asUint8List(),
              options: options,
            );
          } finally {
            options.delete();
          }
        },
      );
      cleanup.add('direct interpreter', interpreter.close);

      final input = stages.runSync('Standalone YOLO tensor metadata', () {
        final input = interpreter.getInputTensors().single;
        expect(input.type, TensorType.float32);
        final size = AppConstants.modelInputSize;
        expect(input.shape, [1, 3, size, size]);
        final outputs = interpreter.getOutputTensors();
        // Shapes and layout from the standalone V7 FP32 export.
        expect(
          outputs.map((output) => output.shape.join(',')),
          unorderedEquals(['1,39,8400', '1,32,160,160']),
        );
        for (final output in outputs) {
          expect(output.type, TensorType.float32);
        }
        return input;
      });

      stages.runSync('Standalone YOLO inference', () {
        final pixels = Float32List(input.numElements())
          ..fillRange(0, input.numElements(), 114 / 255);
        input.data = pixels.buffer.asUint8List();
        interpreter.invoke();
      });

      stages.runSync('Segmentation output validation', () {
        for (final output in interpreter.getOutputTensors()) {
          final bytes = output.data;
          final elementCount = output.numElements();
          expect(
            bytes.lengthInBytes,
            elementCount * Float32List.bytesPerElement,
          );
          final values = bytes.buffer.asFloat32List(
            bytes.offsetInBytes,
            elementCount,
          );
          expect(
            values.every((value) => value.isFinite),
            isTrue,
            reason: 'Nonfinite native output: ${output.shape}',
          );
          if (output.shape[1] == 39) {
            // The detection tensor stores 4 box channels followed by 3 class
            // scores per anchor and 32 mask coefficients.
            final anchors = output.shape[2];
            expect(
              values
                  .getRange(4 * anchors, 7 * anchors)
                  .every((score) => score >= 0 && score <= 1),
              isTrue,
            );
          }
        }
      });
    },
  );
}

void main() {
  final stages = SmokeStageRunner();
  stages.mark('Flutter integration binding', 'START');
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  stages.mark('Flutter integration binding', 'PASS');

  testWidgets('Flutter startup', (tester) async {
    await stages.run<void>(
      'Flutter startup and first frame',
      timeout: smokeStageTimeouts['Flutter startup']!,
      operation: () async {
        expect(
          Platform.isIOS,
          isTrue,
          reason: 'Run this smoke test with an iOS target.',
        );
        const frame = ValueKey('ios-smoke-startup');
        await tester.pumpWidget(const SizedBox(key: frame));
        expect(find.byKey(frame), findsOneWidget);
      },
    );
  }, timeout: Timeout(smokeStageTimeouts['Flutter startup']!));

  testWidgets(
    'Standalone model runtime',
    (tester) async {
      await tester.runAsync(() async {
        final asset = await stages.run<ByteData>(
          'Standalone YOLO model asset loading',
          timeout: smokeStageTimeouts['model asset loading']!,
          operation: () => rootBundle.load(AppConstants.modelAssetPath),
        );
        // Native FFI work is synchronous. Keep it off the test isolate so the
        // timeout can still report a failure if creation or invocation stalls.
        await stages.run<void>(
          'Native TFLite preflight',
          timeout: smokeStageTimeouts['native preflight']!,
          operation: () => _verifyNativeModel(
            TransferableTypedData.fromList([
              asset.buffer.asUint8List(
                asset.offsetInBytes,
                asset.lengthInBytes,
              ),
            ]),
          ),
        );

        final cleanup = SmokeCleanupStack(stages);
        await runWithSmokeCleanup<void>(
          runner: stages,
          cleanup: cleanup,
          operation: () async {
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

            final directory = await stages.run<Directory>(
              'photo processing temporary directory setup',
              timeout: const Duration(seconds: 30),
              operation: () =>
                  Directory.systemTemp.createTemp('calabash-model-smoke-'),
            );
            var photoProcessingTimedOut = false;
            cleanup.add('photo temporary directory', () async {
              if (photoProcessingTimedOut) {
                stages.mark(
                  'photo processing temporary directory',
                  'CLEANUP_DEFERRED',
                  details: 'processing future is still using the file',
                );
                return;
              }
              if (await directory.exists()) {
                await directory.delete(recursive: true);
              }
            });

            final service = ModelService();
            cleanup.add('photo model service', service.dispose);
            Future<PhotoDetectionResult>? photoFuture;
            final photo = await stages.run<PhotoDetectionResult>(
              'photo/image processing',
              timeout: smokeStageTimeouts['photo processing']!,
              operation: () {
                photoFuture = () async {
                  final file = await File(
                    '${directory.path}/pattern.png',
                  ).writeAsBytes(img.encodePng(image));
                  return service.detectFruitsWithMetrics(file);
                }();
                return photoFuture!;
              },
              onTimeout: () => photoProcessingTimedOut = true,
              onLateCompletion: () async {
                if (await directory.exists()) {
                  await directory.delete(recursive: true);
                }
              },
            );
            stages.runSync('Photo postprocessing and segmentation', () {
              expect([photo.imageWidth, photo.imageHeight], [96, 64]);
              expect(photo.fileReadMicros, isNonNegative);
              expect(photo.decodeMicros, isNonNegative);
              expect(photo.modelInitializationMicros, isNonNegative);
              checkResult(photo.modelResult);
            });

            // This sends synthetic BGRA frames through the live worker. It does
            // not initialize a physical camera, which is unavailable in a simulator.
            final worker = LiveInferenceWorker();
            cleanup.add('live inference worker', worker.dispose);
            await stages.run<void>(
              'live worker startup',
              timeout: smokeStageTimeouts['live worker startup']!,
              operation: worker.start,
            );
            final bytes = Uint8List(96 * 64 * 4);
            for (var i = 0; i < bytes.length; i += 4) {
              bytes[i] = 114;
              bytes[i + 1] = 114;
              bytes[i + 2] = 114;
              bytes[i + 3] = 255;
            }
            final result = await stages.run<LiveInferenceResult>(
              'live worker inference',
              timeout: smokeStageTimeouts['live worker inference']!,
              operation: () => worker.detect(
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
              ),
            );
            stages.runSync('Live worker result validation', () {
              expect(result.frameTransferMicros, isNonNegative);
              checkResult(
                ModelDetectionResult(
                  detections: result.toDetections(),
                  timings: result.modelTimings,
                ),
              );
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
            });
          },
        );
      });
      stages.mark(
        'smoke test',
        'PASS',
        details: 'all inference paths completed',
      );
    },
    // The XCTest workflow limit also covers launch and native code stalls.
    timeout: const Timeout(smokeTestTimeout),
  );
}
