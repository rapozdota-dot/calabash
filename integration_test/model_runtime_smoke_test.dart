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
  final stages = SmokeStageRunner();
  stages.mark('test initialization', 'START');
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  stages.mark('test initialization', 'PASS');

  testWidgets(
    'bundled model executes in native iOS TFLite workers and parses outputs',
    (tester) async {
      await tester.runAsync(() async {
        await stages.run<void>(
          'app/test initialization',
          timeout: smokeStageTimeouts['test initialization']!,
          operation: () {
            expect(
              Platform.isIOS,
              isTrue,
              reason: 'Run this smoke test with an iOS target.',
            );
          },
        );
        final cleanup = SmokeCleanupStack(stages);
        await runWithSmokeCleanup<void>(
          runner: stages,
          cleanup: cleanup,
          operation: () async {
            // Keep a direct native-runtime preflight before the app's worker
            // paths. This also ensures the simulator can load and invoke the
            // bundled TFLite library on the integration-test isolate.
            final options = InterpreterOptions()..threads = 2;
            var optionsDeleted = false;
            void deleteOptions() {
              if (optionsDeleted) return;
              optionsDeleted = true;
              options.delete();
            }

            Future<Interpreter>? interpreterLoad;
            late final Interpreter interpreter;
            try {
              interpreter = await stages.run<Interpreter>(
                'TFLite model loading and interpreter initialization',
                timeout: smokeStageTimeouts['interpreter initialization']!,
                operation: () {
                  interpreterLoad = Interpreter.fromAsset(
                    AppConstants.modelAssetPath,
                    options: options,
                  );
                  return interpreterLoad!;
                },
                onLateCompletion: () async {
                  try {
                    (await interpreterLoad!).close();
                  } finally {
                    deleteOptions();
                  }
                },
              );
            } catch (error) {
              if (error is! SmokeStageTimeoutException) deleteOptions();
              rethrow;
            }
            deleteOptions();
            cleanup.add('direct interpreter', interpreter.close);

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

            stages.runSync('direct model inference and output validation', () {
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
            });

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
            expect([photo.imageWidth, photo.imageHeight], [96, 64]);
            expect(photo.fileReadMicros, isNonNegative);
            expect(photo.decodeMicros, isNonNegative);
            expect(photo.modelInitializationMicros, isNonNegative);
            checkResult(photo.modelResult);
            // ignore: avoid_print
            print(
              'Native photo pipeline: ${photo.modelResult.detections.length} detections parsed',
            );

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
            // ignore: avoid_print
            print(
              'Native live pipeline: ${result.backendInfo.label}, ${result.detections.length} detections parsed',
            );
          },
        );
      });
      stages.mark(
        'smoke test',
        'PASS',
        details: 'all inference paths completed',
      );
    },
    // The test_api file-loading watchdog is a separate 12-minute timeout. This
    // explicit case timeout bounds the actual widget test before that watchdog.
    timeout: const Timeout(smokeTestTimeout),
  );
}
