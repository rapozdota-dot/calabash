import 'dart:async';

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/providers/live_detection_tracker.dart';
import 'package:calabash_maturity_detection/services/camera_image_converter.dart';
import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

enum LiveCameraStatus {
  initial,
  requestingPermission,
  initializingCamera,
  cameraReady,
  permissionDenied,
  permissionPermanentlyDenied,
  cameraError,
}

enum _PendingFrameReason { busy, cadence }

class LiveCameraProvider extends ChangeNotifier with WidgetsBindingObserver {
  LiveCameraProvider() {
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
  }

  CameraController? _cameraController;
  LiveInferenceWorker? _inferenceWorker;
  LiveCameraStatus _status = LiveCameraStatus.initial;
  List<LiveDetection> _liveDetections = [];
  final LiveDetectionTracker _detectionTracker = LiveDetectionTracker();
  Size? _latestFrameSize;
  _LiveCameraFrame? _pendingFrame;
  Timer? _inferenceCadenceTimer;
  Timer? _overlayEmergencyExpirationTimer;
  final _performanceTracker = _LivePerformanceTracker();
  int _nextFrameId = 1;
  int? _lastPublishedFrameId;
  DateTime? _lastInferenceStartedAt;
  DateTime? _lastDetectionPublishedAt;
  String? _errorMessage;
  bool _isInitializingSession = false;
  bool _isProcessingFrame = false;
  bool _hasProcessedFrame = false;
  bool _shouldRestoreOnResume = false;
  bool _isTorchOn = false;
  bool _isSettingTorch = false;
  String? _lastTorchError;
  bool _isDisposed = false;

  CameraController? get cameraController => _cameraController;
  LiveCameraStatus get status => _status;
  List<LiveDetection> get liveDetections => _liveDetections;
  Size? get latestFrameSize => _latestFrameSize;
  String? get errorMessage => _errorMessage;
  bool get isProcessingFrame => _isProcessingFrame;
  bool get hasProcessedFrame => _hasProcessedFrame;
  bool get isTorchOn => _isTorchOn;
  bool get isSettingTorch => _isSettingTorch;
  String? get lastTorchError => _lastTorchError;
  int get _pendingFrameCount => _pendingFrame == null ? 0 : 1;

  bool get isCameraReady =>
      _status == LiveCameraStatus.cameraReady &&
      _cameraController != null &&
      _cameraController!.value.isInitialized;

  bool get shouldShowNoCalabash =>
      isCameraReady &&
      _hasProcessedFrame &&
      !_isProcessingFrame &&
      _liveDetections.isEmpty &&
      _errorMessage == null;

  Future<void> initialize() {
    return _ensurePermissionAndStart(requestPermission: true);
  }

  Future<void> retryPermission() {
    return _ensurePermissionAndStart(requestPermission: true);
  }

  Future<void> openSettings() {
    return openAppSettings();
  }

  Future<bool> toggleTorch() async {
    if (_isDisposed || _isSettingTorch) {
      return false;
    }

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      _lastTorchError = 'Flashlight is available after the camera starts.';
      _safeNotifyListeners();
      return false;
    }

    final nextTorchState = !_isTorchOn;
    _isSettingTorch = true;
    _lastTorchError = null;
    _safeNotifyListeners();

    final success = await _setTorchMode(
      controller,
      enabled: nextTorchState,
      reportErrors: true,
    );

    if (_isDisposed) {
      return false;
    }
    if (_cameraController != controller) {
      _isSettingTorch = false;
      _isTorchOn = false;
      _safeNotifyListeners();
      return false;
    }

    _isSettingTorch = false;
    if (success) {
      _isTorchOn = nextTorchState;
    } else if (nextTorchState) {
      _isTorchOn = false;
      await _setTorchMode(controller, enabled: false, reportErrors: false);
    }
    _safeNotifyListeners();
    return success;
  }

  Future<void> _ensurePermissionAndStart({
    required bool requestPermission,
  }) async {
    if (_isDisposed || _isInitializingSession) {
      return;
    }

    _isInitializingSession = true;
    _setStatus(LiveCameraStatus.requestingPermission);

    try {
      var permissionStatus = await Permission.camera.status;
      if (permissionStatus.isDenied && requestPermission) {
        permissionStatus = await Permission.camera.request();
      }

      if (_isDisposed) {
        return;
      }

      if (permissionStatus.isGranted) {
        await _initializeCamera();
        return;
      }

      await _releaseCamera(keepLiveState: true);
      if (permissionStatus.isPermanentlyDenied ||
          permissionStatus.isRestricted) {
        _setStatus(LiveCameraStatus.permissionPermanentlyDenied);
      } else {
        _setStatus(LiveCameraStatus.permissionDenied);
      }
    } catch (error) {
      _setStatus(
        LiveCameraStatus.cameraError,
        errorMessage: 'Camera permission failed: $error',
      );
    } finally {
      _isInitializingSession = false;
    }
  }

  Future<void> _initializeCamera() async {
    _setStatus(LiveCameraStatus.initializingCamera);
    await _releaseCamera(keepLiveState: true);

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('No camera is available on this device.');
      }

      final selectedCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        fps: 15,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      _cameraController = controller;
      await controller.initialize();
      if (_isDisposed || _cameraController != controller) {
        await controller.dispose();
        return;
      }

      try {
        await controller.setFlashMode(FlashMode.off);
        _isTorchOn = false;
        _lastTorchError = null;
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Unable to force flash off for live detection: $error');
        }
      }

      unawaited(_ensureInferenceWorkerStarted());
      await controller.startImageStream(_handleCameraFrame);
      if (_isDisposed || _cameraController != controller) {
        await _disposeController(controller);
        return;
      }

      _errorMessage = null;
      _setStatus(LiveCameraStatus.cameraReady);
    } catch (error) {
      await _releaseCamera(keepLiveState: true);
      _setStatus(
        LiveCameraStatus.cameraError,
        errorMessage: 'Camera could not be started: $error',
      );
    }
  }

  Future<void> _ensureInferenceWorkerStarted() async {
    if (_isDisposed || _inferenceWorker?.isReady == true) {
      return;
    }

    final worker = LiveInferenceWorker();
    _inferenceWorker = worker;
    try {
      await worker.start();
      if (_isDisposed || _inferenceWorker != worker) {
        await worker.dispose();
        return;
      }
      final backendInfo = worker.backendInfo;
      if (backendInfo != null) {
        _performanceTracker.recordBackendInfo(backendInfo);
      }
      _safeNotifyListeners();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Live inference worker failed to start: $error');
      }
      if (!_isDisposed && _inferenceWorker == worker) {
        _errorMessage = 'Live detection worker failed to start.';
        _safeNotifyListeners();
      }
      await worker.dispose();
      if (_inferenceWorker == worker) {
        _inferenceWorker = null;
      }
    }
  }

  void _handleCameraFrame(CameraImage frame) {
    final capturedAt = DateTime.now();
    _performanceTracker.recordFrameReceived(capturedAt);

    final activeController = _cameraController;
    if (_isDisposed ||
        activeController == null ||
        !activeController.value.isInitialized) {
      _performanceTracker.recordFrameDropped();
      _performanceTracker.maybeLog(pendingFrameCount: _pendingFrameCount);
      return;
    }

    final liveFrame = _LiveCameraFrame(
      id: _nextFrameId++,
      image: frame,
      capturedAt: capturedAt,
      camera: activeController.description,
      deviceOrientation: activeController.value.deviceOrientation,
    );
    if (_isProcessingFrame) {
      _storeLatestPendingFrame(liveFrame, reason: _PendingFrameReason.busy);
      _performanceTracker.maybeLog(pendingFrameCount: _pendingFrameCount);
      return;
    }

    final cadenceDelay = _remainingInferenceCadenceDelay(capturedAt);
    if (cadenceDelay > Duration.zero) {
      _storeLatestPendingFrame(liveFrame, reason: _PendingFrameReason.cadence);
      _schedulePendingFrameDrain(cadenceDelay);
      _performanceTracker.maybeLog(pendingFrameCount: _pendingFrameCount);
      return;
    }

    unawaited(_processFrame(liveFrame));
  }

  void _storeLatestPendingFrame(
    _LiveCameraFrame frame, {
    required _PendingFrameReason reason,
  }) {
    final replacedExistingFrame = _pendingFrame != null;
    _pendingFrame = frame;
    switch (reason) {
      case _PendingFrameReason.busy:
        _performanceTracker.recordFrameStoredWhileBusy(
          replacedExistingFrame: replacedExistingFrame,
        );
        break;
      case _PendingFrameReason.cadence:
        _performanceTracker.recordFrameDelayedByCadence(
          replacedExistingFrame: replacedExistingFrame,
        );
        break;
    }
  }

  Duration _remainingInferenceCadenceDelay(DateTime now) {
    final lastInferenceStartedAt = _lastInferenceStartedAt;
    if (lastInferenceStartedAt == null) {
      return Duration.zero;
    }

    final elapsed = now.difference(lastInferenceStartedAt);
    if (elapsed >= AppConstants.liveInferenceMinInterval) {
      return Duration.zero;
    }
    return AppConstants.liveInferenceMinInterval - elapsed;
  }

  void _schedulePendingFrameDrain(Duration delay) {
    if (_inferenceCadenceTimer?.isActive == true) {
      return;
    }

    _inferenceCadenceTimer = Timer(delay, _drainPendingFrame);
  }

  void _drainPendingFrame() {
    _inferenceCadenceTimer?.cancel();
    _inferenceCadenceTimer = null;

    if (_isDisposed || _isProcessingFrame) {
      return;
    }

    final frame = _pendingFrame;
    if (frame == null) {
      return;
    }

    final activeController = _cameraController;
    if (activeController == null || !activeController.value.isInitialized) {
      _pendingFrame = null;
      _performanceTracker.recordFrameDropped();
      _performanceTracker.maybeLog(pendingFrameCount: _pendingFrameCount);
      return;
    }

    final cadenceDelay = _remainingInferenceCadenceDelay(DateTime.now());
    if (cadenceDelay > Duration.zero) {
      _schedulePendingFrameDrain(cadenceDelay);
      return;
    }

    _pendingFrame = null;
    unawaited(_processFrame(frame));
  }

  Future<void> _processFrame(_LiveCameraFrame frame) async {
    final activeController = _cameraController;
    if (activeController == null || _isDisposed) {
      _performanceTracker.recordFrameDropped();
      return;
    }

    _isProcessingFrame = true;
    _safeNotifyListeners();

    try {
      final inferenceStartAt = DateTime.now();
      final worker = _inferenceWorker;
      if (worker == null || !worker.isReady) {
        _performanceTracker.recordFrameDropped();
        return;
      }

      _lastInferenceStartedAt = inferenceStartAt;
      final rotationDegrees = _rotationDegrees(
        frame.camera,
        frame.deviceOrientation,
      );
      final workerFrame = LiveInferenceFrame.fromCameraImage(
        frameId: frame.id,
        image: frame.image,
        rotationDegrees: rotationDegrees,
        lensDirection: frame.camera.lensDirection,
      );
      final modelResult = await worker.detect(workerFrame);
      final inferenceEndAt = DateTime.now();
      if (_isDisposed || _cameraController != activeController) {
        _performanceTracker.recordFrameDropped();
        return;
      }

      final publishAt = DateTime.now();
      final frameTelemetry = _LiveFrameTelemetry(
        frameId: frame.id,
        capturedAt: frame.capturedAt,
        inferenceStartAt: inferenceStartAt,
        inferenceEndAt: inferenceEndAt,
        publishedAt: publishAt,
      );
      _performanceTracker.recordFrameProcessed(
        _LiveFramePerformanceSample(
          frameTelemetry: frameTelemetry,
          conversionTiming: modelResult.conversionTiming,
          modelTimings: modelResult.modelTimings,
          frameTransferMicros: modelResult.frameTransferMicros,
          backendInfo: modelResult.backendInfo,
        ),
      );

      if (!_shouldPublishResult(frame, modelResult, publishAt)) {
        _performanceTracker.recordStaleResultSkipped();
        _expireOverlayIfEmergencyStale(publishAt);
        return;
      }

      final publishStopwatch = Stopwatch()..start();
      final detections = modelResult.toDetections();
      _latestFrameSize = Size(
        modelResult.imageWidth.toDouble(),
        modelResult.imageHeight.toDouble(),
      );
      _lastPublishedFrameId = modelResult.frameId;
      _hasProcessedFrame = true;
      _errorMessage = null;

      if (detections.isEmpty) {
        final didClear = _clearLiveDetections(cancelEmergencyExpiration: true);
        _performanceTracker.recordNoDetectionClear(didClear: didClear);
      } else {
        final update = _detectionTracker.update(detections);
        _liveDetections = update.detections;
        _lastDetectionPublishedAt = publishAt;
        _performanceTracker.recordOverlayRefreshed(update);
        _scheduleOverlayEmergencyExpiration(publishAt);
      }
      publishStopwatch.stop();
      _performanceTracker.recordResultPublished(
        publishStopwatch.elapsedMicroseconds,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Live frame detection failed: $error');
      }
      if (!_isDisposed) {
        _hasProcessedFrame = true;
        _errorMessage = 'Live detection failed. Keep the camera steady.';
      }
    } finally {
      if (!_isDisposed) {
        _isProcessingFrame = false;
        _performanceTracker.maybeLog(pendingFrameCount: _pendingFrameCount);
        _safeNotifyListeners();
        if (_pendingFrame != null) {
          if (_cameraController == activeController) {
            _drainPendingFrame();
          } else {
            _pendingFrame = null;
            _performanceTracker.recordFrameDropped();
          }
        }
      }
    }
  }

  bool _shouldPublishResult(
    _LiveCameraFrame frame,
    LiveInferenceResult result,
    DateTime publishAt,
  ) {
    final lastPublishedFrameId = _lastPublishedFrameId;
    if (result.frameId != frame.id ||
        (lastPublishedFrameId != null &&
            result.frameId <= lastPublishedFrameId)) {
      return false;
    }

    final resultAge = publishAt.difference(frame.capturedAt);
    return resultAge <= AppConstants.liveResultMaxAge;
  }

  bool _clearLiveDetections({required bool cancelEmergencyExpiration}) {
    final hadVisibleDetections =
        _liveDetections.isNotEmpty || _detectionTracker.activeTrackCount > 0;
    _liveDetections = [];
    _detectionTracker.clear();
    _lastDetectionPublishedAt = null;

    if (cancelEmergencyExpiration) {
      _overlayEmergencyExpirationTimer?.cancel();
      _overlayEmergencyExpirationTimer = null;
    }

    return hadVisibleDetections;
  }

  void _scheduleOverlayEmergencyExpiration(DateTime detectionPublishedAt) {
    _overlayEmergencyExpirationTimer?.cancel();
    _overlayEmergencyExpirationTimer = Timer(
      AppConstants.liveOverlayEmergencyStaleTimeout,
      () {
        if (_isDisposed || _lastDetectionPublishedAt != detectionPublishedAt) {
          return;
        }

        if (_clearLiveDetections(cancelEmergencyExpiration: false)) {
          _performanceTracker.recordOverlayExpired();
          _safeNotifyListeners();
        }
      },
    );
  }

  bool _expireOverlayIfEmergencyStale(DateTime now) {
    final lastDetectionPublishedAt = _lastDetectionPublishedAt;
    if (lastDetectionPublishedAt == null ||
        now.difference(lastDetectionPublishedAt) <
            AppConstants.liveOverlayEmergencyStaleTimeout) {
      return false;
    }

    final didClear = _clearLiveDetections(cancelEmergencyExpiration: true);
    if (didClear) {
      _performanceTracker.recordOverlayExpired();
    }
    return didClear;
  }

  void _handleFrameTimings(List<FrameTiming> timings) {
    _performanceTracker.recordUiFrameTimings(timings);
  }

  int _rotationDegrees(
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) {
    final deviceDegrees = switch (deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };

    if (camera.lensDirection == CameraLensDirection.front) {
      return (camera.sensorOrientation + deviceDegrees) % 360;
    }
    return (camera.sensorOrientation - deviceDegrees + 360) % 360;
  }

  Future<void> _releaseCamera({required bool keepLiveState}) async {
    final controller = _cameraController;
    final inferenceWorker = _inferenceWorker;
    _cameraController = null;
    _inferenceWorker = null;
    _pendingFrame = null;
    _inferenceCadenceTimer?.cancel();
    _inferenceCadenceTimer = null;
    _isProcessingFrame = false;
    _isSettingTorch = false;
    _isTorchOn = false;
    _lastTorchError = null;
    _performanceTracker.reset();

    if (!keepLiveState) {
      _clearLiveDetections(cancelEmergencyExpiration: true);
      _latestFrameSize = null;
      _lastPublishedFrameId = null;
      _lastInferenceStartedAt = null;
      _hasProcessedFrame = false;
      _errorMessage = null;
    }

    if (controller == null) {
      await inferenceWorker?.dispose();
      return;
    }

    await _turnTorchOffForRelease(controller);
    await _disposeController(controller);
    await inferenceWorker?.dispose();
  }

  Future<void> _turnTorchOffForRelease(CameraController controller) async {
    await _setTorchMode(controller, enabled: false, reportErrors: false);
    _isTorchOn = false;
    _isSettingTorch = false;
  }

  Future<bool> _setTorchMode(
    CameraController controller, {
    required bool enabled,
    required bool reportErrors,
  }) async {
    try {
      if (!controller.value.isInitialized) {
        if (reportErrors) {
          _lastTorchError = 'Flashlight is available after the camera starts.';
        }
        return false;
      }

      await controller.setFlashMode(enabled ? FlashMode.torch : FlashMode.off);
      return true;
    } on CameraException catch (error) {
      if (reportErrors) {
        _lastTorchError = enabled
            ? 'Flashlight is not available on this device.'
            : 'Unable to turn flashlight off.';
      }
      if (kDebugMode) {
        debugPrint('Unable to set live camera torch: $error');
      }
      return false;
    } catch (error) {
      if (reportErrors) {
        _lastTorchError = enabled
            ? 'Flashlight could not be turned on.'
            : 'Flashlight could not be turned off.';
      }
      if (kDebugMode) {
        debugPrint('Unable to set live camera torch: $error');
      }
      return false;
    }
  }

  Future<void> _disposeController(CameraController controller) async {
    try {
      if (controller.value.isInitialized &&
          controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Unable to stop camera image stream: $error');
      }
    }

    try {
      await controller.dispose();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Unable to dispose live camera controller: $error');
      }
    }
  }

  void _setStatus(LiveCameraStatus status, {String? errorMessage}) {
    if (_isDisposed) {
      return;
    }
    _status = status;
    _errorMessage = errorMessage;
    _safeNotifyListeners();
  }

  void _safeNotifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) {
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        if (_shouldRestoreOnResume) {
          _shouldRestoreOnResume = false;
          unawaited(_ensurePermissionAndStart(requestPermission: false));
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_cameraController != null) {
          _shouldRestoreOnResume = true;
          unawaited(_releaseCamera(keepLiveState: true));
        }
        break;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_handleFrameTimings);
    unawaited(_releaseCamera(keepLiveState: false));
    super.dispose();
  }
}

class _LiveCameraFrame {
  const _LiveCameraFrame({
    required this.id,
    required this.image,
    required this.capturedAt,
    required this.camera,
    required this.deviceOrientation,
  });

  final int id;
  final CameraImage image;
  final DateTime capturedAt;
  final CameraDescription camera;
  final DeviceOrientation deviceOrientation;
}

class _LiveFrameTelemetry {
  const _LiveFrameTelemetry({
    required this.frameId,
    required this.capturedAt,
    required this.inferenceStartAt,
    required this.inferenceEndAt,
    required this.publishedAt,
  });

  final int frameId;
  final DateTime capturedAt;
  final DateTime inferenceStartAt;
  final DateTime inferenceEndAt;
  final DateTime publishedAt;

  int get resultAgeMicros => publishedAt.difference(capturedAt).inMicroseconds;

  int get totalAiMicros =>
      inferenceEndAt.difference(inferenceStartAt).inMicroseconds;
}

class _LiveFramePerformanceSample {
  const _LiveFramePerformanceSample({
    required this.frameTelemetry,
    required this.conversionTiming,
    required this.modelTimings,
    required this.frameTransferMicros,
    required this.backendInfo,
  });

  final _LiveFrameTelemetry frameTelemetry;
  final CameraImageConversionTiming conversionTiming;
  final ModelPipelineTimings modelTimings;
  final int frameTransferMicros;
  final LiveInferenceBackendInfo backendInfo;
}

class _LivePerformanceTracker {
  DateTime? _windowStartedAt;
  int _framesReceived = 0;
  int _framesProcessed = 0;
  int _framesReplaced = 0;
  int _framesDelayedByCadence = 0;
  int _framesDropped = 0;
  int _staleResultsSkipped = 0;
  int _overlaysExpired = 0;
  int _overlayRefreshes = 0;
  int _noDetectionClears = 0;
  int _trackCreations = 0;
  int _trackMatches = 0;
  int _trackRemovals = 0;
  int? _lastProcessedFrameId;
  LiveInferenceBackendInfo? _backendInfo;
  int _uiFrameCount = 0;
  int _jankyUiFrameCount = 0;

  final _TimingAccumulator _frameTransfer = _TimingAccumulator();
  final _TimingAccumulator _rgbConversion = _TimingAccumulator();
  final _TimingAccumulator _orientation = _TimingAccumulator();
  final _TimingAccumulator _preprocess = _TimingAccumulator();
  final _TimingAccumulator _resizeLetterbox = _TimingAccumulator();
  final _TimingAccumulator _tensorFill = _TimingAccumulator();
  final _TimingAccumulator _inference = _TimingAccumulator();
  final _TimingAccumulator _candidateParsing = _TimingAccumulator();
  final _TimingAccumulator _nms = _TimingAccumulator();
  final _TimingAccumulator _protoExtraction = _TimingAccumulator();
  final _TimingAccumulator _maskReconstruction = _TimingAccumulator();
  final _TimingAccumulator _postprocess = _TimingAccumulator();
  final _TimingAccumulator _totalAi = _TimingAccumulator();
  final _TimingAccumulator _resultAge = _TimingAccumulator();
  final _TimingAccumulator _resultPublication = _TimingAccumulator();
  final _TimingAccumulator _uiBuild = _TimingAccumulator();
  final _TimingAccumulator _uiRaster = _TimingAccumulator();
  final _TimingAccumulator _uiTotal = _TimingAccumulator();

  void recordFrameReceived(DateTime receivedAt) {
    _ensureWindow(receivedAt);
    _framesReceived++;
  }

  void recordFrameStoredWhileBusy({required bool replacedExistingFrame}) {
    if (!replacedExistingFrame) {
      return;
    }
    _framesReplaced++;
    _framesDropped++;
  }

  void recordFrameDelayedByCadence({required bool replacedExistingFrame}) {
    _framesDelayedByCadence++;
    if (!replacedExistingFrame) {
      return;
    }
    _framesReplaced++;
    _framesDropped++;
  }

  void recordFrameDropped() {
    _framesDropped++;
  }

  void recordStaleResultSkipped() {
    _staleResultsSkipped++;
  }

  void recordOverlayExpired() {
    _overlaysExpired++;
  }

  void recordOverlayRefreshed(LiveDetectionUpdate update) {
    _overlayRefreshes++;
    _trackCreations += update.createdTrackCount;
    _trackMatches += update.matchedTrackCount;
    _trackRemovals += update.removedTrackCount;
  }

  void recordNoDetectionClear({required bool didClear}) {
    if (didClear) {
      _noDetectionClears++;
    }
  }

  void recordBackendInfo(LiveInferenceBackendInfo backendInfo) {
    _backendInfo = backendInfo;
  }

  void recordUiFrameTimings(List<FrameTiming> timings) {
    const jankThresholdMicros = 16667;
    final now = DateTime.now();
    _ensureWindow(now);

    for (final timing in timings) {
      final totalMicros = timing.totalSpan.inMicroseconds;
      _uiFrameCount++;
      if (totalMicros > jankThresholdMicros) {
        _jankyUiFrameCount++;
      }
      _uiBuild.add(timing.buildDuration.inMicroseconds);
      _uiRaster.add(timing.rasterDuration.inMicroseconds);
      _uiTotal.add(totalMicros);
    }
  }

  void recordFrameProcessed(_LiveFramePerformanceSample sample) {
    _ensureWindow(sample.frameTelemetry.publishedAt);
    _framesProcessed++;
    _lastProcessedFrameId = sample.frameTelemetry.frameId;
    _backendInfo = sample.backendInfo;

    _frameTransfer.add(sample.frameTransferMicros);
    _rgbConversion.add(sample.conversionTiming.rgbConversionMicros);
    _orientation.add(sample.conversionTiming.orientationMicros);
    _preprocess.add(sample.modelTimings.preprocessMicros);
    _resizeLetterbox.add(sample.modelTimings.resizeLetterboxMicros);
    _tensorFill.add(sample.modelTimings.tensorFillMicros);
    _inference.add(sample.modelTimings.inferenceMicros);
    _candidateParsing.add(sample.modelTimings.candidateParsingMicros);
    _nms.add(sample.modelTimings.nmsMicros);
    _protoExtraction.add(sample.modelTimings.protoExtractionMicros);
    _maskReconstruction.add(sample.modelTimings.maskReconstructionMicros);
    _postprocess.add(sample.modelTimings.postprocessMicros);
    _totalAi.add(sample.frameTelemetry.totalAiMicros);
    _resultAge.add(sample.frameTelemetry.resultAgeMicros);
  }

  void recordResultPublished(int micros) {
    _resultPublication.add(micros);
  }

  void maybeLog({required int pendingFrameCount}) {
    if (!kDebugMode) {
      return;
    }

    final now = DateTime.now();
    _ensureWindow(now);
    final elapsed = now.difference(_windowStartedAt!);
    if (elapsed < const Duration(seconds: 1)) {
      return;
    }

    final elapsedSeconds =
        elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final cameraFps = _framesReceived / elapsedSeconds;
    final aiFps = _framesProcessed / elapsedSeconds;
    final backendInfo = _backendInfo;

    debugPrint(
      'LIVE PERF\n'
      'Backend: ${backendInfo?.label ?? 'initializing'}\n'
      'Camera FPS: ${cameraFps.toStringAsFixed(1)}\n'
      'AI FPS: ${aiFps.toStringAsFixed(1)}\n'
      'Frames received: $_framesReceived\n'
      'Frames processed: $_framesProcessed\n'
      'Frames replaced: $_framesReplaced\n'
      'Frames cadence-delayed: $_framesDelayedByCadence\n'
      'Frames dropped/skipped: $_framesDropped\n'
      'Stale results skipped: $_staleResultsSkipped\n'
      'Overlays expired: $_overlaysExpired\n'
      'Overlay refreshes: $_overlayRefreshes\n'
      'No-detection clears: $_noDetectionClears\n'
      'Track create/match/remove: $_trackCreations/$_trackMatches/$_trackRemovals\n'
      'Pending: $pendingFrameCount\n'
      'Last frame ID: ${_lastProcessedFrameId ?? '-'}\n\n'
      'UI frames: $_uiFrameCount\n'
      'UI janky frames: $_jankyUiFrameCount\n'
      'UI build: ${_uiBuild.averageMsLabel}\n'
      'UI raster: ${_uiRaster.averageMsLabel}\n'
      'UI total: ${_uiTotal.averageMsLabel}\n\n'
      'Frame transfer: ${_frameTransfer.averageMsLabel}\n'
      'Conversion: ${_rgbConversion.averageMsLabel}\n'
      'Rotation/flip: ${_orientation.averageMsLabel}\n'
      'Preprocess: ${_preprocess.averageMsLabel}\n'
      'Resize/letterbox: ${_resizeLetterbox.averageMsLabel}\n'
      'Tensor fill: ${_tensorFill.averageMsLabel}\n'
      'Inference: ${_inference.averageMsLabel}\n'
      'Candidate parse: ${_candidateParsing.averageMsLabel}\n'
      'NMS: ${_nms.averageMsLabel}\n'
      'Proto extraction: ${_protoExtraction.averageMsLabel}\n'
      'Masks: ${_maskReconstruction.averageMsLabel}\n'
      'Postprocess: ${_postprocess.averageMsLabel}\n'
      'Total AI: ${_totalAi.averageMsLabel}\n'
      'Result publication: ${_resultPublication.averageMsLabel}\n'
      'Result age: ${_resultAge.averageMsLabel}',
    );
    _resetWindow(now);
  }

  void reset() {
    _windowStartedAt = null;
    _backendInfo = null;
    _resetCounters();
  }

  void _ensureWindow(DateTime timestamp) {
    _windowStartedAt ??= timestamp;
  }

  void _resetWindow(DateTime startedAt) {
    _windowStartedAt = startedAt;
    _resetCounters();
  }

  void _resetCounters() {
    _framesReceived = 0;
    _framesProcessed = 0;
    _framesReplaced = 0;
    _framesDelayedByCadence = 0;
    _framesDropped = 0;
    _staleResultsSkipped = 0;
    _overlaysExpired = 0;
    _overlayRefreshes = 0;
    _noDetectionClears = 0;
    _trackCreations = 0;
    _trackMatches = 0;
    _trackRemovals = 0;
    _lastProcessedFrameId = null;
    _uiFrameCount = 0;
    _jankyUiFrameCount = 0;
    _frameTransfer.reset();
    _rgbConversion.reset();
    _orientation.reset();
    _preprocess.reset();
    _resizeLetterbox.reset();
    _tensorFill.reset();
    _inference.reset();
    _candidateParsing.reset();
    _nms.reset();
    _protoExtraction.reset();
    _maskReconstruction.reset();
    _postprocess.reset();
    _totalAi.reset();
    _resultAge.reset();
    _resultPublication.reset();
    _uiBuild.reset();
    _uiRaster.reset();
    _uiTotal.reset();
  }
}

class _TimingAccumulator {
  int _sampleCount = 0;
  int _totalMicros = 0;

  void add(int micros) {
    _sampleCount++;
    _totalMicros += micros;
  }

  void reset() {
    _sampleCount = 0;
    _totalMicros = 0;
  }

  String get averageMsLabel {
    if (_sampleCount == 0) {
      return 'n/a';
    }
    final averageMs = (_totalMicros / _sampleCount) / 1000;
    return '${averageMs.toStringAsFixed(1)} ms';
  }
}
