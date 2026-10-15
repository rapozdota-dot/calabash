import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:calabash_maturity_detection/services/camera_image_converter.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/services/performance_probe.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Camera extends CameraPlatform {
  final frames = StreamController<CameraImageData>.broadcast();
  int captures = 0;
  int creations = 0;
  bool failCapture = false;
  Completer<XFile>? pendingCapture;
  Completer<void>? releasing;
  final orientations =
      StreamController<DeviceOrientationChangedEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => [
    const CameraDescription(
      name: 'rear',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];
  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async => ++creations;
  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          640,
          480,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      StreamController<CameraErrorEvent>().stream;
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      orientations.stream;
  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => frames.stream;
  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}
  @override
  Future<XFile> takePicture(int cameraId) async {
    if (pendingCapture != null) return pendingCapture!.future;
    if (failCapture) throw CameraException('capture', 'test failure');
    return XFile('capture-${++captures}.jpg');
  }

  @override
  Future<void> dispose(int cameraId) async => releasing?.future;
}

class _SlowWorker extends LiveInferenceWorker {
  final ready = Completer<void>();
  @override
  Future<void> start() => ready.future;
  @override
  bool get isReady => ready.isCompleted;
  @override
  Future<void> dispose() async {
    if (!ready.isCompleted) ready.complete();
  }
}

class _MeasuredWorker extends LiveInferenceWorker {
  final first = Completer<LiveInferenceResult>();
  final received = <LiveInferenceFrame>[];
  @override
  bool get isReady => true;
  @override
  Future<void> start() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<LiveInferenceResult> detect(LiveInferenceFrame frame) {
    received.add(frame);
    return received.length == 1 ? first.future : Future.value(result(frame));
  }

  LiveInferenceResult result(LiveInferenceFrame frame) => LiveInferenceResult(
    frameId: frame.frameId,
    imageWidth: 4,
    imageHeight: 4,
    detections: [],
    conversionTiming: CameraImageConversionTiming()..rgbConversionMicros = 1,
    modelTimings: const ModelPipelineTimings(
      preprocessMicros: 1,
      resizeLetterboxMicros: 1,
      tensorFillMicros: 0,
      inferenceMicros: 1,
      candidateParsingMicros: 0,
      nmsMicros: 0,
      protoExtractionMicros: 0,
      maskReconstructionMicros: 0,
      postprocessMicros: 1,
      totalMicros: 3,
    ),
    frameTransferMicros: 1,
    backendInfo: const LiveInferenceBackendInfo(
      selectedConfig: TfliteBackendConfig.cpu2,
      attempts: [],
      fromCache: false,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Camera camera;
  late CameraPlatform original;
  const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );
  setUp(() {
    original = CameraPlatform.instance;
    camera = _Camera();
    CameraPlatform.instance = camera;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (_) async => 1);
  });
  tearDown(() {
    camera.frames.close();
    camera.orientations.close();
    CameraPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

  test(
    'live recording preserves one newest pending frame and measures queue separately',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'calabash-live-test-',
      );
      final probe = PerformanceProbe(
        enabled: true,
        documentsDirectory: () async => directory,
      );
      final worker = _MeasuredWorker();
      final provider = LiveCameraProvider(
        workerFactory: () => worker,
        performanceProbe: probe,
      );
      addTearDown(() async {
        provider.dispose();
        await probe.close();
        await directory.delete(recursive: true);
      });
      final frame = CameraImageData(
        format: const CameraImageFormat(
          ImageFormatGroup.bgra8888,
          raw: 1111970369,
        ),
        width: 4,
        height: 4,
        planes: [
          CameraImagePlane(
            bytes: Uint8List(64),
            bytesPerRow: 16,
            bytesPerPixel: 4,
          ),
        ],
      );
      await provider.initialize();
      camera.frames.add(frame);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(worker.received.length, 1);
      camera.frames.add(frame);
      camera.frames.add(frame);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(worker.received.length, 1);
      worker.first.complete(worker.result(worker.received.first));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(worker.received.map((f) => f.frameId).toList(), [1, 3]);
      final summary = probe.summaryFor(PerformanceScanMethod.live);
      expect(summary.successfulCount, 2);
      expect(summary.warmUpCount, 1);
      expect(summary.validCount, 1);
      await probe.flush();
      final rows = (await probe.rawFile!.readAsString()).trim().split('\r\n');
      final header = rows[0].split(',');
      final last = rows[2].split(',');
      final complete = double.parse(
        last[header.indexOf('complete_processing_ms')],
      );
      final processing = double.parse(last[header.indexOf('processing_ms')]);
      final queue = double.parse(last[header.indexOf('queue_ms')]);
      expect(queue, greaterThan(0));
      expect(complete, closeTo(processing + queue, .002));
      expect(last[header.indexOf('processed_fps')], isNotEmpty);
      expect(last[header.indexOf('yolo_inference_ms')], '0.001');
    },
  );
  test('rotation updates preview without restarting the camera', () async {
    final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
    await provider.initialize();
    var notifications = 0;
    provider.addListener(() => notifications++);
    camera.orientations.add(
      DeviceOrientationChangedEvent(DeviceOrientation.landscapeLeft),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      provider.cameraController!.value.deviceOrientation,
      DeviceOrientation.landscapeLeft,
    );
    expect(provider.isCameraReady, isTrue);
    expect(provider.latestFrameSize, isNull);
    expect(provider.liveDetections, isEmpty);
    expect(notifications, greaterThan(0));
    expect(camera.creations, 1);
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  for (final resumeBeforeGrant in [true, false]) {
    test(
      'first permission grant recovers (resume first: $resumeBeforeGrant)',
      () async {
        final permission = Completer<Map<int, int>>();
        var granted = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(permissionChannel, (call) async {
              if (call.method == 'requestPermissions') return permission.future;
              return granted ? 1 : 0;
            });
        final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
        final startup = provider.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        provider.didChangeAppLifecycleState(AppLifecycleState.inactive);
        granted = true;
        if (resumeBeforeGrant) {
          provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
        }
        permission.complete({1: 1}); // permission_handler camera ID.
        await startup;
        if (!resumeBeforeGrant) {
          expect(camera.creations, 0);
          provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(provider.isCameraReady, isTrue);
        expect(camera.creations, 1);
        expect(provider.isCaptureWorkflowActive, isFalse);
        provider.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      },
    );
  }

  test('TC19/59 granting permission in Settings recovers on resume', () async {
    var permission = 4; // Permanently denied.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, (call) async {
          if (call.method == 'openAppSettings') return true;
          return permission;
        });
    final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
    await provider.initialize();
    expect(provider.status, LiveCameraStatus.permissionPermanentlyDenied);
    await provider.openSettings();
    provider.didChangeAppLifecycleState(AppLifecycleState.inactive);
    permission = 1;
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(provider.isCameraReady, isTrue);
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test(
    'capture again stays usable while a single worker is still starting',
    () async {
      var workers = 0;
      final worker = _SlowWorker();
      final provider = LiveCameraProvider(
        workerFactory: () {
          workers++;
          return worker;
        },
      );
      await provider.initialize();
      expect(provider.isCameraReady, isTrue);
      for (var i = 0; i < 3; i++) {
        expect(await provider.captureStillImage(), isNotNull);
        expect(provider.isCaptureWorkflowActive, isTrue);
        expect(await provider.captureStillImage(), isNull);
        await provider.resumeLiveDetection().timeout(
          const Duration(seconds: 1),
        );
        expect(provider.isCaptureWorkflowActive, isFalse);
        expect(provider.cameraController!.value.isStreamingImages, isTrue);
      }
      expect(workers, 1);
      expect(camera.captures, 3);
      provider.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    },
  );

  test('failed capture releases the shutter for the next attempt', () async {
    final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
    await provider.initialize();
    camera.failCapture = true;
    expect(await provider.captureStillImage(), isNull);
    await provider.resumeLiveDetection();
    expect(provider.isCaptureWorkflowActive, isFalse);
    camera.failCapture = false;
    expect(await provider.captureStillImage(), isNotNull);
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test(
    'a stalled native capture times out and a fresh camera can capture',
    () async {
      final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
      await provider.initialize();
      camera.pendingCapture = Completer<XFile>();
      final pending = camera.pendingCapture!;
      expect(await provider.captureStillImage(), isNull);
      expect(provider.captureErrorMessage, contains('timed out'));
      camera.pendingCapture = null;
      await provider.resumeLiveDetection();
      expect(camera.creations, 2);
      expect(provider.isCaptureWorkflowActive, isFalse);
      expect(await provider.captureStillImage(), isNotNull);
      pending.complete(XFile('late-photo.jpg'));
      provider.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    },
  );

  test(
    'lifecycle resume waits for old camera release before creating another',
    () async {
      final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
      await provider.initialize();
      camera.releasing = Completer<void>();
      provider.didChangeAppLifecycleState(AppLifecycleState.inactive);
      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(camera.creations, 1);
      camera.releasing!.complete();
      await provider.resumeLiveDetection();
      expect(camera.creations, 2);
      expect(provider.isCaptureWorkflowActive, isFalse);
      provider.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    },
  );
}
