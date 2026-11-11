// Runs in an iOS simulator/device, against the same native TFLite pod as Runner.
// Deterministic synthetic images prove execution/contract compatibility, not
// fruit recognition quality or physical-device performance.
import 'dart:io';
import 'dart:isolate';

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

import 'native_model_preflight.dart';

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
    (_) => stages.runWithCleanup<void>(
      'Standalone model runtime',
      timeout: smokeTestTimeout,
      operation: (cleanup) async {
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
          operation: () => verifyNativeModel(
            TransferableTypedData.fromList([
              asset.buffer.asUint8List(
                asset.offsetInBytes,
                asset.lengthInBytes,
              ),
            ]),
          ),
        );

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
    ),
    // The XCTest workflow limit also covers launch and native code stalls.
    timeout: const Timeout(smokeTestTimeout),
  );
}
