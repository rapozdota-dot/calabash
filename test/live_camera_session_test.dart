import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:calabash_maturity_detection/services/camera_image_converter.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/services/performance_probe.dart';
import 'package:flutter/foundation.dart';
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
  Completer<void>? discovering;
  Completer<void>? initializing;
  final errors = <int, StreamController<CameraErrorEvent>>{};
  final disposed = <int>[];
  final orientations =
      StreamController<DeviceOrientationChangedEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async {
    await discovering?.future;
    return [
      const CameraDescription(
        name: 'rear',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      ),
    ];
  }

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async => ++creations;
  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async => initializing?.future;
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
      errors.putIfAbsent(cameraId, StreamController.broadcast).stream;
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
  Future<void> dispose(int cameraId) async {
    disposed.add(cameraId);
    await releasing?.future;
  }
}

class _ControlledWorker extends LiveInferenceWorker {
  final startup = Completer<void>();
  bool _ready = false;
  bool disposed = false;
  @override
  Future<void> start() async {
    await startup.future;
    if (!disposed) _ready = true;
  }

  @override
  bool get isReady => _ready;
  @override
  Future<void> dispose() async {
    disposed = true;
    _ready = false;
  }
}

class _FailingWorker extends LiveInferenceWorker {
  @override
  Future<void> start() async => throw StateError('fixture worker failure');
  @override
  bool get isReady => false;
  @override
  Future<void> dispose() async {}
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
      invokeMicros: 1,
      inputTensorMicros: 0,
      outputTensorMicros: 0,
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
  tearDown(() async {
    // CameraController listens with .first, including on controllers that never
    // failed. Resolve those futures before closing the fixture streams.
    for (final entry in camera.errors.entries) {
      entry.value.add(CameraErrorEvent(entry.key, 'fixture cleanup'));
      await entry.value.close();
    }
    await camera.frames.close();
    await camera.orientations.close();
    debugDefaultTargetPlatformOverride = null;
    CameraPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    group('$platform camera error recovery', () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);

      test('H1 camera startup preserves an earlier worker failure', () async {
        camera.discovering = Completer<void>();
        final healthy = _SlowWorker()..ready.complete();
        var workers = 0;
        final provider = LiveCameraProvider(
          workerFactory: () => ++workers == 1 ? _FailingWorker() : healthy,
        );
        addTearDown(provider.dispose);
        final startup = provider.initialize();
        await Future<void>.delayed(Duration.zero);
        expect(provider.errorMessage, contains('worker failed to start'));
        camera.discovering!.complete();
        await startup;
        expect(provider.isCameraReady, isTrue);
        expect(provider.isInferenceReady, isFalse);
        expect(provider.errorMessage, contains('worker failed to start'));

        // Navigation/resume can retry just the worker on a healthy stream.
        await Future.wait([
          provider.resumeLiveDetection(),
          provider.resumeLiveDetection(),
        ]);
        await Future<void>.delayed(Duration.zero);
        expect(provider.isInferenceReady, isTrue);
        expect(provider.errorMessage, isNull);
        expect(workers, 2);
        expect(camera.creations, 1);
      });

      test('H1 late worker failure persists until retry succeeds', () async {
        final failed = _ControlledWorker();
        final healthy = _ControlledWorker();
        var workers = 0;
        final provider = LiveCameraProvider(
          workerFactory: () => ++workers == 1 ? failed : healthy,
        );
        addTearDown(provider.dispose);
        // Camera startup must finish without waiting for the AI worker.
        await provider.initialize();
        expect(provider.isCameraReady, isTrue);
        expect(provider.isInferenceReady, isFalse);
        failed.startup.completeError(StateError('fixture delayed failure'));
        await Future<void>.delayed(Duration.zero);
        expect(provider.errorMessage, contains('worker failed to start'));
        expect(failed.disposed, isTrue);

        await provider.retryPermission();
        expect(provider.isCameraReady, isTrue);
        expect(provider.isInferenceReady, isFalse);
        expect(provider.errorMessage, contains('worker failed to start'));
        healthy.startup.complete();
        await Future<void>.delayed(Duration.zero);
        expect(provider.errorMessage, isNull);
        expect(provider.isInferenceReady, isTrue);
        expect(workers, 2);
      });

      test('H2 native runtime error is recoverable without rotation', () async {
        final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
        addTearDown(provider.dispose);
        await provider.initialize();
        final oldController = provider.cameraController!;
        final oldId = oldController.cameraId;
        camera.releasing = Completer<void>();
        camera.errors[oldId]!.add(
          CameraErrorEvent(oldId, 'fixture native camera failure'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(provider.status, LiveCameraStatus.cameraError);
        expect(provider.isCameraReady, isFalse);
        expect(
          provider.errorMessage,
          contains('fixture native camera failure'),
        );
        expect(await provider.captureStillImage(), isNull);
        expect(camera.captures, 0);

        final retry = Future.wait([
          provider.retryPermission(),
          provider.retryPermission(),
        ]);
        await Future<void>.delayed(Duration.zero);
        expect(camera.creations, 1);
        camera.releasing!.complete();
        await retry;
        expect(provider.isCameraReady, isTrue);
        expect(provider.errorMessage, isNull);
        expect(camera.creations, 2);
        expect(camera.disposed.where((id) => id == oldId), hasLength(1));
        var notifications = 0;
        provider.addListener(() => notifications++);
        camera.orientations.add(
          DeviceOrientationChangedEvent(DeviceOrientation.landscapeLeft),
        );
        await Future<void>.delayed(Duration.zero);
        expect(notifications, 1);
        expect(provider.isCameraReady, isTrue);
        expect(await provider.captureStillImage(), isNotNull);
        await provider.resumeLiveDetection();
        expect(provider.isCameraReady, isTrue);
      });

      test('H2 native startup error cannot become camera ready', () async {
        camera.initializing = Completer<void>();
        final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
        addTearDown(provider.dispose);
        final startup = provider.initialize();
        await Future<void>.delayed(Duration.zero);
        final id = provider.cameraController!.cameraId;
        camera.errors[id]!.add(CameraErrorEvent(id, 'fixture startup failure'));
        await Future<void>.delayed(Duration.zero);
        expect(provider.status, LiveCameraStatus.cameraError);
        expect(provider.isCameraReady, isFalse);
        camera.initializing!.complete();
        await startup;
        expect(provider.status, LiveCameraStatus.cameraError);
        expect(provider.errorMessage, contains('fixture startup failure'));
        expect(provider.isCameraReady, isFalse);
        await provider.resumeLiveDetection();
        expect(provider.isCameraReady, isTrue);
        expect(provider.errorMessage, isNull);
      });

      test('H1/H2 worker completion cannot clear a native error', () async {
        final worker = _ControlledWorker();
        final provider = LiveCameraProvider(workerFactory: () => worker);
        addTearDown(provider.dispose);
        await provider.initialize();
        final id = provider.cameraController!.cameraId;
        camera.errors[id]!.add(CameraErrorEvent(id, 'fixture native failure'));
        await Future<void>.delayed(Duration.zero);
        worker.startup.completeError(StateError('fixture late worker failure'));
        await Future<void>.delayed(Duration.zero);
        expect(provider.status, LiveCameraStatus.cameraError);
        expect(provider.errorMessage, contains('fixture native failure'));
        expect(provider.isCameraReady, isFalse);
      });

      test('H2 invalidates active inference and drops later frames', () async {
        final worker = _MeasuredWorker();
        final provider = LiveCameraProvider(workerFactory: () => worker);
        addTearDown(provider.dispose);
        await provider.initialize();
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
        camera.frames.add(frame);
        await Future<void>.delayed(Duration.zero);
        expect(worker.received, hasLength(1));
        final id = provider.cameraController!.cameraId;
        camera.errors[id]!.add(
          CameraErrorEvent(id, 'fixture inference interruption'),
        );
        await Future<void>.delayed(Duration.zero);
        camera.frames.add(frame);
        worker.first.complete(worker.result(worker.received.first));
        await Future<void>.delayed(const Duration(milliseconds: 110));
        expect(worker.received, hasLength(1));
        expect(provider.hasProcessedFrame, isFalse);
        expect(provider.latestFrameSize, isNull);
        expect(provider.liveDetections, isEmpty);
        expect(
          provider.errorMessage,
          contains('fixture inference interruption'),
        );
        expect(provider.isProcessingFrame, isFalse);
      });

      for (final outcome in [
        'camera error',
        'timeout',
        'other error',
        'photo',
      ]) {
        test('H2 late capture $outcome cannot release a replacement', () async {
          final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
          addTearDown(provider.dispose);
          await provider.initialize();
          final oldId = provider.cameraController!.cameraId;
          final pending = Completer<XFile>();
          camera.pendingCapture = pending;
          final capture = provider.captureStillImage();
          await Future<void>.delayed(Duration.zero);
          camera.errors[oldId]!.add(
            CameraErrorEvent(oldId, 'fixture capture interruption'),
          );
          await Future<void>.delayed(Duration.zero);
          await provider.retryPermission();
          final replacement = provider.cameraController;
          expect(replacement, isNotNull);
          expect(provider.isCameraReady, isTrue);
          camera.pendingCapture = null;
          switch (outcome) {
            case 'camera error':
              pending.completeError(
                CameraException('capture', 'fixture obsolete failure'),
              );
            case 'timeout':
              pending.completeError(
                TimeoutException('fixture obsolete timeout'),
              );
            case 'other error':
              pending.completeError(StateError('fixture obsolete failure'));
            case 'photo':
              pending.complete(XFile('obsolete-photo.jpg'));
          }
          expect(await capture, isNull);
          expect(provider.cameraController, same(replacement));
          expect(provider.isCameraReady, isTrue);
          expect(provider.captureErrorMessage, isNull);
          expect(provider.isCaptureWorkflowActive, isFalse);
          expect(camera.disposed, [oldId]);
          expect(await provider.captureStillImage(), isNotNull);
          await provider.resumeLiveDetection();
          expect(camera.creations, 2);
        });
      }

      test('H1 late worker failure after disposal is ignored', () async {
        final worker = _ControlledWorker();
        final provider = LiveCameraProvider(workerFactory: () => worker);
        await provider.initialize();
        var notifications = 0;
        provider.addListener(() => notifications++);
        provider.dispose();
        worker.startup.completeError(StateError('fixture disposed startup'));
        await Future<void>.delayed(Duration.zero);
        expect(worker.disposed, isTrue);
        expect(notifications, 0);
        expect(camera.frames.hasListener, isFalse);
        expect(camera.orientations.hasListener, isFalse);
      });

      test('H1 replaced worker cannot clear the current failure', () async {
        final oldWorker = _ControlledWorker();
        var workers = 0;
        final provider = LiveCameraProvider(
          workerFactory: () => ++workers == 1 ? oldWorker : _FailingWorker(),
        );
        addTearDown(provider.dispose);
        await provider.initialize();
        await provider.retryPermission();
        expect(provider.errorMessage, contains('worker failed to start'));
        oldWorker.startup.complete();
        await Future<void>.delayed(Duration.zero);
        expect(oldWorker.disposed, isTrue);
        expect(provider.errorMessage, contains('worker failed to start'));
        expect(provider.isCameraReady, isTrue);
        expect(provider.isInferenceReady, isFalse);
      });

      test('H2 empty native description uses a recoverable error', () async {
        final provider = LiveCameraProvider(workerFactory: _SlowWorker.new);
        addTearDown(provider.dispose);
        await provider.initialize();
        final id = provider.cameraController!.cameraId;
        camera.errors[id]!.add(CameraErrorEvent(id, '  '));
        await Future<void>.delayed(Duration.zero);
        expect(provider.status, LiveCameraStatus.cameraError);
        expect(provider.errorMessage, 'Camera failed. Please try again.');
        expect(provider.isCameraReady, isFalse);
        await provider.retryPermission();
        expect(provider.isCameraReady, isTrue);
        expect(provider.errorMessage, isNull);
      });
    });
  }

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
      expect(rows, hasLength(3), reason: 'header plus the two inferred frames');
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
      expect(last[header.indexOf('interpreter_invoke_ms')], '0.001');
      expect(last[header.indexOf('model_preprocess_ms')], '0.001');
      expect(last[header.indexOf('preprocess_ms')], '0.002');
      expect(last[header.indexOf('conversion_ms')], '0.001');
      expect(last[header.indexOf('frame_transfer_ms')], '0.001');
      expect(worker.received.first.transferTimer, isNotNull);
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
