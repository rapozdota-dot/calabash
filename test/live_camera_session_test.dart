import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Camera extends CameraPlatform {
  int captures = 0;
  int creations = 0;
  bool failCapture = false;
  Completer<XFile>? pendingCapture;
  Completer<void>? releasing;

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
      const Stream.empty();
  @override
  bool supportsImageStreaming() => true;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => StreamController<CameraImageData>().stream;
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
    CameraPlatform.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

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
