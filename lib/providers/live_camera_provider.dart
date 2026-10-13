import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/providers/live_detection_tracker.dart';
import 'package:calabash_maturity_detection/providers/live_result_policy.dart';
import 'package:calabash_maturity_detection/services/camera_image_converter.dart';
import 'package:calabash_maturity_detection/services/camera_frame_policy.dart';
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
  Completer<void>? _activeFrameCompleter;
  final _performanceTracker = _LivePerformanceTracker();
  int _nextFrameId = 1;
  int? _lastPublishedFrameId;
  DateTime? _lastInferenceStartedAt;
  DateTime? _lastDetectionPublishedAt;
  String? _errorMessage;
  bool _isInitializingSession = false;
  bool _isProcessingFrame = false;
  bool _hasProcessedFrame = false;
  Duration _lastProcessingTime = Duration.zero;

  /// Flags live inference taking over 1.2 seconds so the UI can suggest capture.
  bool get isLiveSlow =>
      _lastProcessingTime > const Duration(milliseconds: 1200);
  bool _shouldRestoreOnResume = false;
  bool _isTorchOn = false;
  bool _isSettingTorch = false;
  bool _isCapturingStill = false;
  bool _isPausedForStillResult = false;
  String? _lastTorchError;
  String? _captureErrorMessage;
  LiveStabilityStatus _stabilityStatus = LiveStabilityStatus.noCalabashDetected;
  int _readyGraceFramesRemaining = 0;
  bool _isDisposed = false;

  /// Exposes the active native camera controller for preview rendering.
  CameraController? get cameraController => _cameraController;

  /// Exposes the permission/startup/ready/error state of the camera session.
  LiveCameraStatus get status => _status;

  /// Returns confirmed tracked detections currently eligible for live rendering.
  List<LiveDetection> get liveDetections => _liveDetections;

  /// Returns oriented frame dimensions used to align masks with the preview.
  Size? get latestFrameSize => _latestFrameSize;

  /// Exposes camera or live-inference failures without treating them as detections.
  String? get errorMessage => _errorMessage;

  /// Indicates that one frame is currently being analyzed in the worker.
  bool get isProcessingFrame => _isProcessingFrame;

  /// Distinguishes startup from a completed inference with zero detections.
  bool get hasProcessedFrame => _hasProcessedFrame;

  /// Exposes the last successfully applied flashlight state.
  bool get isTorchOn => _isTorchOn;

  /// Prevents overlapping native flashlight requests.
  bool get isSettingTorch => _isSettingTorch;

  /// Indicates that a full photo capture is in progress.
  bool get isCapturingStill => _isCapturingStill;

  /// Keeps capture controls disabled during capture and while its result is open.
  bool get isCaptureWorkflowActive =>
      _isCapturingStill || _isPausedForStillResult;

  /// Exposes a friendly flashlight error for the snackbar.
  String? get lastTorchError => _lastTorchError;

  /// Exposes the most recent still-photo capture failure.
  String? get captureErrorMessage => _captureErrorMessage;

  /// Exposes whether to show no calabash, hold steady, or ready to capture.
  LiveStabilityStatus get stabilityStatus => _stabilityStatus;

  /// Reports the bounded queue size: only the newest waiting frame is retained.
  int get _pendingFrameCount => _pendingFrame == null ? 0 : 1;

  /// Requires both the ready status and a successfully initialized controller.
  bool get isCameraReady =>
      _status == LiveCameraStatus.cameraReady &&
      _cameraController != null &&
      _cameraController!.value.isInitialized;

  /// Shows the empty message only after successful processing, not during startup or errors.
  bool get shouldShowNoCalabash =>
      isCameraReady &&
      _hasProcessedFrame &&
      _stabilityStatus == LiveStabilityStatus.noCalabashDetected &&
      _liveDetections.isEmpty &&
      _errorMessage == null;

  /// Requests camera permission and starts the live session when allowed.
  Future<void> initialize() {
    return _ensurePermissionAndStart(requestPermission: true);
  }

  /// Rechecks permission and retries camera initialization after a denied/failed attempt.
  Future<void> retryPermission() {
    return _ensurePermissionAndStart(requestPermission: true);
  }

  /// Opens system app settings when camera permission cannot be requested again.
  Future<void> openSettings() {
    return openAppSettings();
  }

  /// Pauses streaming, waits briefly for active inference, and captures a full photo.
  /// Live detection stays paused while the captured photo's result is displayed.
  Future<File?> captureStillImage() async {
    if (_isDisposed || _isCapturingStill) {
      return null;
    }

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      _captureErrorMessage = 'Camera is not ready yet.';
      _safeNotifyListeners();
      return null;
    }

    _isCapturingStill = true;
    _captureErrorMessage = null;
    _safeNotifyListeners();

    try {
      await _pauseImageStreamForStillCapture(controller);
      await _waitForActiveFrameToFinish();

      if (_isDisposed ||
          _cameraController != controller ||
          !controller.value.isInitialized) {
        throw StateError('Camera became unavailable during capture.');
      }

      final capturedFile = await controller.takePicture();
      _isPausedForStillResult = true;
      return File(capturedFile.path);
    } on CameraException catch (error) {
      _captureErrorMessage =
          'Image capture failed: ${error.description ?? error.code}';
      if (kDebugMode) {
        debugPrint('Live still capture failed: $error');
      }
      return null;
    } catch (error) {
      _captureErrorMessage = 'Image capture failed. Please try again.';
      if (kDebugMode) {
        debugPrint('Live still capture failed: $error');
      }
      return null;
    } finally {
      _isCapturingStill = false;
      _safeNotifyListeners();
    }
  }

  /// Restarts streaming after leaving a still result, recreating the session if needed.
  Future<void> resumeLiveDetection() async {
    if (_isDisposed || _isCapturingStill || _isInitializingSession) {
      return;
    }

    _isPausedForStillResult = false;
    _shouldRestoreOnResume = false;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      await _ensurePermissionAndStart(requestPermission: false);
      return;
    }

    if (controller.value.isStreamingImages) {
      _captureErrorMessage = null;
      _setStatus(LiveCameraStatus.cameraReady);
      return;
    }

    try {
      await _ensureInferenceWorkerStarted();
      if (_isDisposed ||
          _cameraController != controller ||
          !controller.value.isInitialized) {
        return;
      }

      _pendingFrame = null;
      _inferenceCadenceTimer?.cancel();
      _inferenceCadenceTimer = null;
      _lastInferenceStartedAt = null;
      await controller.startImageStream(_handleCameraFrame);
      _captureErrorMessage = null;
      _setStatus(LiveCameraStatus.cameraReady);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Unable to resume live detection: $error');
      }
      _setStatus(
        LiveCameraStatus.cameraError,
        errorMessage: 'Camera could not resume live detection: $error',
      );
    }
  }

  /// Toggles the native torch with duplicate-request and disposed-session guards.
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

  /// Serializes permission checks and starts the camera only when access is granted.
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

  /// Selects a rear camera, applies the platform frame format, and starts streaming.
  /// The inference worker starts separately so preview startup need not wait for benchmarking.
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
        fps: AppConstants.liveCameraFps,
        imageFormatGroup: CameraFramePolicy.imageFormat(defaultTargetPlatform),
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

  /// Starts the background model worker and records its selected backend.
  /// Initialization failures become UI errors and the failed worker is disposed.
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

  /// Drops pending frames and stops streaming before the native still-photo capture.
  Future<void> _pauseImageStreamForStillCapture(
    CameraController controller,
  ) async {
    _pendingFrame = null;
    _inferenceCadenceTimer?.cancel();
    _inferenceCadenceTimer = null;

    if (!controller.value.isInitialized ||
        !controller.value.isStreamingImages) {
      return;
    }

    await controller.stopImageStream();
  }

  /// Waits for current inference, with a timeout, before proceeding with capture.
  Future<void> _waitForActiveFrameToFinish() async {
    final activeFrameCompleter = _activeFrameCompleter;
    if (activeFrameCompleter == null || activeFrameCompleter.isCompleted) {
      return;
    }

    await activeFrameCompleter.future.timeout(
      AppConstants.liveResultMaxAge,
      onTimeout: () {},
    );
  }

  /// Receives camera frames and either submits one or replaces the pending frame.
  /// A one-frame queue and minimum inference interval prevent a growing stale backlog.
  void _handleCameraFrame(CameraImage frame) {
    final capturedAt = DateTime.now();
    _performanceTracker.recordFrameReceived(capturedAt);

    final activeController = _cameraController;
    if (_isDisposed ||
        activeController == null ||
        _isCapturingStill ||
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

  /// Keeps only the newest queued frame and records why the previous one was replaced.
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

  /// Calculates how long to wait before the next inference may start.
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

  /// Schedules one queue-drain timer instead of creating a timer for every camera frame.
  void _schedulePendingFrameDrain(Duration delay) {
    if (_inferenceCadenceTimer?.isActive == true) {
      return;
    }

    _inferenceCadenceTimer = Timer(delay, _drainPendingFrame);
  }

  /// Submits the newest waiting frame when inference and the cadence limit permit it.
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

  /// Transfers a frame to the isolate, awaits inference, and publishes fresh results.
  /// Confirmed tracks drive overlays; stale results and changed camera sessions are rejected.
  Future<void> _processFrame(_LiveCameraFrame frame) async {
    final activeController = _cameraController;
    if (activeController == null || _isDisposed) {
      _performanceTracker.recordFrameDropped();
      return;
    }

    final activeFrameCompleter = Completer<void>();
    _activeFrameCompleter = activeFrameCompleter;
    _isProcessingFrame = true;
    // Subsequent frames publish once on completion instead of flickering busy/idle.
    if (!_hasProcessedFrame) _safeNotifyListeners();

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
      _lastProcessingTime = inferenceEndAt.difference(inferenceStartAt);
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
        if (publishAt.difference(frame.capturedAt) >
            LiveResultPolicy.maxResultAge) {
          _errorMessage =
              'Live preview is taking longer. Tap capture for a clear result.';
        }
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
        _applyStabilityStatus(update.stabilityStatus);
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
        if (_activeFrameCompleter == activeFrameCompleter) {
          _activeFrameCompleter = null;
        }
        if (!activeFrameCompleter.isCompleted) {
          activeFrameCompleter.complete();
        }
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

  /// Rejects mismatched/out-of-order frame IDs and results exceeding the age policy.
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

    return LiveResultPolicy.canPublish(
      capturedAt: frame.capturedAt,
      startedAt: _lastInferenceStartedAt ?? frame.capturedAt,
      publishedAt: publishAt,
    );
  }

  /// Clears overlays, track memory, and readiness so old fruit masks do not linger.
  bool _clearLiveDetections({required bool cancelEmergencyExpiration}) {
    final hadVisibleDetections =
        _liveDetections.isNotEmpty || _detectionTracker.activeTrackCount > 0;
    _liveDetections = [];
    _detectionTracker.clear();
    _lastDetectionPublishedAt = null;
    _stabilityStatus = LiveStabilityStatus.noCalabashDetected;
    _readyGraceFramesRemaining = 0;

    if (cancelEmergencyExpiration) {
      _overlayEmergencyExpirationTimer?.cancel();
      _overlayEmergencyExpirationTimer = null;
    }

    return hadVisibleDetections;
  }

  /// Applies readiness with a short grace period to reduce hold-steady/ready flicker.
  void _applyStabilityStatus(LiveStabilityStatus nextStatus) {
    if (nextStatus == LiveStabilityStatus.ready) {
      _stabilityStatus = LiveStabilityStatus.ready;
      _readyGraceFramesRemaining = AppConstants.liveReadyGraceFrames;
      return;
    }

    if (nextStatus == LiveStabilityStatus.noCalabashDetected) {
      _stabilityStatus = LiveStabilityStatus.noCalabashDetected;
      _readyGraceFramesRemaining = 0;
      return;
    }

    if (_stabilityStatus == LiveStabilityStatus.ready &&
        _readyGraceFramesRemaining > 0) {
      _readyGraceFramesRemaining--;
      return;
    }

    _stabilityStatus = nextStatus;
    _readyGraceFramesRemaining = 0;
  }

  /// Removes overlays if no fresh result arrives within the processing-aware lifetime.
  void _scheduleOverlayEmergencyExpiration(DateTime detectionPublishedAt) {
    _overlayEmergencyExpirationTimer?.cancel();
    _overlayEmergencyExpirationTimer = Timer(
      LiveResultPolicy.overlayLifetime(_lastProcessingTime),
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

  /// Immediately clears expired overlays when a result is too stale to publish.
  bool _expireOverlayIfEmergencyStale(DateTime now) {
    final lastDetectionPublishedAt = _lastDetectionPublishedAt;
    if (lastDetectionPublishedAt == null ||
        now.difference(lastDetectionPublishedAt) <
            LiveResultPolicy.overlayLifetime(_lastProcessingTime)) {
      return false;
    }

    final didClear = _clearLiveDetections(cancelEmergencyExpiration: true);
    if (didClear) {
      _performanceTracker.recordOverlayExpired();
    }
    return didClear;
  }

  /// Passes Flutter build/raster timings to the debug performance tracker.
  void _handleFrameTimings(List<FrameTiming> timings) {
    _performanceTracker.recordUiFrameTimings(timings);
  }

  /// Uses the platform policy to rotate inference pixels consistently with the preview.
  int _rotationDegrees(
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) {
    return CameraFramePolicy.rotationDegrees(
      platform: defaultTargetPlatform,
      camera: camera,
      orientation: deviceOrientation,
    );
  }

  /// Cancels timers and releases the torch, stream, controller, and inference worker.
  /// Optionally retains live UI state during a temporary lifecycle interruption.
  Future<void> _releaseCamera({required bool keepLiveState}) async {
    final controller = _cameraController;
    final inferenceWorker = _inferenceWorker;
    _cameraController = null;
    _inferenceWorker = null;
    _pendingFrame = null;
    _inferenceCadenceTimer?.cancel();
    _inferenceCadenceTimer = null;
    final activeFrameCompleter = _activeFrameCompleter;
    if (activeFrameCompleter != null && !activeFrameCompleter.isCompleted) {
      activeFrameCompleter.complete();
    }
    _activeFrameCompleter = null;
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
      _captureErrorMessage = null;
      _isPausedForStillResult = false;
      _stabilityStatus = LiveStabilityStatus.noCalabashDetected;
      _readyGraceFramesRemaining = 0;
    }

    if (controller == null) {
      await inferenceWorker?.dispose();
      return;
    }

    await _turnTorchOffForRelease(controller);
    await _disposeController(controller);
    await inferenceWorker?.dispose();
  }

  /// Attempts to turn off the flashlight before releasing the native camera.
  Future<void> _turnTorchOffForRelease(CameraController controller) async {
    await _setTorchMode(controller, enabled: false, reportErrors: false);
    _isTorchOn = false;
    _isSettingTorch = false;
  }

  /// Applies torch/off mode and converts unsupported-device errors into optional UI messages.
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

  /// Stops streaming and disposes the controller, logging cleanup failures in debug mode.
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

  /// Changes session status and error text only while this provider is alive.
  void _setStatus(LiveCameraStatus status, {String? errorMessage}) {
    if (_isDisposed) {
      return;
    }
    _status = status;
    _errorMessage = errorMessage;
    _safeNotifyListeners();
  }

  /// Avoids notifying widgets after the provider has been disposed.
  void _safeNotifyListeners() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  /// Releases camera resources in the background and restores them when appropriate.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) {
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        if (_shouldRestoreOnResume && !_isPausedForStillResult) {
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

  /// Unregisters lifecycle/timing callbacks and starts asynchronous camera cleanup.
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

  /// Measures capture-to-publication age, including queueing and inference.
  int get resultAgeMicros => publishedAt.difference(capturedAt).inMicroseconds;

  /// Measures elapsed time between inference submission and completion.
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

  /// Starts the measurement window if needed and counts incoming camera frames.
  void recordFrameReceived(DateTime receivedAt) {
    _ensureWindow(receivedAt);
    _framesReceived++;
  }

  /// Counts a pending frame replaced because inference was already busy.
  void recordFrameStoredWhileBusy({required bool replacedExistingFrame}) {
    if (!replacedExistingFrame) {
      return;
    }
    _framesReplaced++;
    _framesDropped++;
  }

  /// Counts cadence-delayed frames and any older pending frame they replace.
  void recordFrameDelayedByCadence({required bool replacedExistingFrame}) {
    _framesDelayedByCadence++;
    if (!replacedExistingFrame) {
      return;
    }
    _framesReplaced++;
    _framesDropped++;
  }

  /// Counts frames intentionally skipped rather than submitted for inference.
  void recordFrameDropped() {
    _framesDropped++;
  }

  /// Counts completed results rejected by the freshness policy.
  void recordStaleResultSkipped() {
    _staleResultsSkipped++;
  }

  /// Counts overlays removed because their safety lifetime elapsed.
  void recordOverlayExpired() {
    _overlaysExpired++;
  }

  /// Counts overlay refreshes and associated track creations, matches, and removals.
  void recordOverlayRefreshed(LiveDetectionUpdate update) {
    _overlayRefreshes++;
    _trackCreations += update.createdTrackCount;
    _trackMatches += update.matchedTrackCount;
    _trackRemovals += update.removedTrackCount;
  }

  /// Counts an empty result that actually removed visible or tracked detections.
  void recordNoDetectionClear({required bool didClear}) {
    if (didClear) {
      _noDetectionClears++;
    }
  }

  /// Stores the active backend for the next performance report.
  void recordBackendInfo(LiveInferenceBackendInfo backendInfo) {
    _backendInfo = backendInfo;
  }

  /// Accumulates Flutter frame costs and counts frames above the 60 FPS time budget.
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

  /// Accumulates conversion, inference, mask, and result-age timings for a completed frame.
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

  /// Adds the main-isolate result-publication cost to the timing report.
  void recordResultPublished(int micros) {
    _resultPublication.add(micros);
  }

  /// Prints debug-only FPS, queue, tracking, and pipeline statistics about once per second.
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

  /// Clears session-level performance state when camera resources are released.
  void reset() {
    _windowStartedAt = null;
    _backendInfo = null;
    _resetCounters();
  }

  /// Sets the measurement window's start time on its first sample.
  void _ensureWindow(DateTime timestamp) {
    _windowStartedAt ??= timestamp;
  }

  /// Starts a new reporting window and clears its counters and timing samples.
  void _resetWindow(DateTime startedAt) {
    _windowStartedAt = startedAt;
    _resetCounters();
  }

  /// Resets every per-window frame counter and timing accumulator.
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

  /// Adds one microsecond sample to the running total and sample count.
  void add(int micros) {
    _sampleCount++;
    _totalMicros += micros;
  }

  /// Clears samples before collecting the next reporting window.
  void reset() {
    _sampleCount = 0;
    _totalMicros = 0;
  }

  /// Formats mean latency in milliseconds, or n/a when no samples exist.
  String get averageMsLabel {
    if (_sampleCount == 0) {
      return 'n/a';
    }
    final averageMs = (_totalMicros / _sampleCount) / 1000;
    return '${averageMs.toStringAsFixed(1)} ms';
  }
}
