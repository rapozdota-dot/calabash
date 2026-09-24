import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/models/detection.dart';
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

enum LiveConfidenceTier { normal, weak, low }

class LiveDetection {
  const LiveDetection({required this.detection, required this.confidenceTier});

  final Detection detection;
  final LiveConfidenceTier confidenceTier;
}

class LiveCameraProvider extends ChangeNotifier with WidgetsBindingObserver {
  LiveCameraProvider() {
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
  }

  CameraController? _cameraController;
  LiveInferenceWorker? _inferenceWorker;
  LiveCameraStatus _status = LiveCameraStatus.initial;
  List<LiveDetection> _liveDetections = [];
  List<_StableDetectionTrack> _tracks = [];
  Size? _latestFrameSize;
  _LiveCameraFrame? _pendingFrame;
  _LiveFrameTelemetry? _latestFrameTelemetry;
  final _performanceTracker = _LivePerformanceTracker();
  int _nextFrameId = 1;
  String? _errorMessage;
  bool _isInitializingSession = false;
  bool _isProcessingFrame = false;
  bool _hasProcessedFrame = false;
  bool _shouldRestoreOnResume = false;
  bool _isDisposed = false;

  CameraController? get cameraController => _cameraController;
  LiveCameraStatus get status => _status;
  List<LiveDetection> get liveDetections => _liveDetections;
  Size? get latestFrameSize => _latestFrameSize;
  String? get errorMessage => _errorMessage;
  bool get isProcessingFrame => _isProcessingFrame;
  bool get hasProcessedFrame => _hasProcessedFrame;
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
      final replacedExistingFrame = _pendingFrame != null;
      _pendingFrame = liveFrame;
      _performanceTracker.recordFrameStoredWhileBusy(
        replacedExistingFrame: replacedExistingFrame,
      );
      _performanceTracker.maybeLog(pendingFrameCount: _pendingFrameCount);
      return;
    }

    unawaited(_processFrame(liveFrame));
  }

  Future<void> _processFrame(_LiveCameraFrame frame) async {
    final activeController = _cameraController;
    if (activeController == null || _isDisposed) {
      _performanceTracker.recordFrameDropped();
      return;
    }

    _isProcessingFrame = true;

    var shouldNotify = false;
    try {
      final inferenceStartAt = DateTime.now();
      final rotationDegrees = _rotationDegrees(
        frame.camera,
        frame.deviceOrientation,
      );

      final worker = _inferenceWorker;
      if (worker == null || !worker.isReady) {
        _performanceTracker.recordFrameDropped();
        return;
      }

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
      _latestFrameTelemetry = _LiveFrameTelemetry(
        frameId: frame.id,
        capturedAt: frame.capturedAt,
        inferenceStartAt: inferenceStartAt,
        inferenceEndAt: inferenceEndAt,
        publishedAt: publishAt,
      );
      _latestFrameSize = Size(
        modelResult.imageWidth.toDouble(),
        modelResult.imageHeight.toDouble(),
      );
      _liveDetections = _stabilizeDetections(modelResult.toDetections());
      _hasProcessedFrame = true;
      _errorMessage = null;
      shouldNotify = true;
      _performanceTracker.recordFrameProcessed(
        _LiveFramePerformanceSample(
          frameTelemetry: _latestFrameTelemetry!,
          conversionTiming: modelResult.conversionTiming,
          modelTimings: modelResult.modelTimings,
          frameTransferMicros: modelResult.frameTransferMicros,
          backendInfo: modelResult.backendInfo,
        ),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Live frame detection failed: $error');
      }
      if (!_isDisposed) {
        _hasProcessedFrame = true;
        _errorMessage = 'Live detection failed. Keep the camera steady.';
        shouldNotify = true;
      }
    } finally {
      if (!_isDisposed) {
        final nextFrame = _pendingFrame;
        _pendingFrame = null;
        _isProcessingFrame = false;
        _performanceTracker.maybeLog(pendingFrameCount: _pendingFrameCount);
        if (shouldNotify) {
          _safeNotifyListeners();
        }
        if (nextFrame != null) {
          if (_cameraController == activeController) {
            unawaited(_processFrame(nextFrame));
          } else {
            _performanceTracker.recordFrameDropped();
          }
        }
      }
    }
  }

  void _handleFrameTimings(List<FrameTiming> timings) {
    _performanceTracker.recordUiFrameTimings(timings);
  }

  List<LiveDetection> _stabilizeDetections(List<Detection> detections) {
    if (detections.isEmpty) {
      _tracks = [];
      return [];
    }

    final oldTracks = _tracks;
    final usedTrackIndexes = <int>{};
    final updatedTracks = <_StableDetectionTrack>[];
    final stabilized = <LiveDetection>[];

    for (final detection in detections) {
      final matchIndex = _findBestTrackIndex(
        detection,
        oldTracks,
        usedTrackIndexes,
      );

      final track = matchIndex == null
          ? _StableDetectionTrack.fromDetection(detection)
          : oldTracks[matchIndex];
      if (matchIndex != null) {
        track.updateWith(detection);
        usedTrackIndexes.add(matchIndex);
      }

      updatedTracks.add(track);
      stabilized.add(
        LiveDetection(
          detection: Detection(
            boundingBox: detection.boundingBox,
            maturityClass: track.stableClass,
            confidence: detection.confidence,
            mask: detection.mask,
          ),
          confidenceTier: _confidenceTierFor(detection.confidence),
        ),
      );
    }

    _tracks = updatedTracks;
    return stabilized;
  }

  int? _findBestTrackIndex(
    Detection detection,
    List<_StableDetectionTrack> tracks,
    Set<int> usedTrackIndexes,
  ) {
    var bestIndex = -1;
    var bestScore = 0.0;

    for (var index = 0; index < tracks.length; index++) {
      if (usedTrackIndexes.contains(index)) {
        continue;
      }

      final track = tracks[index];
      final iou = _iou(detection.boundingBox, track.boundingBox);
      final centerDistance = _centerDistance(
        detection.boundingBox,
        track.boundingBox,
      );
      final centerScore = 1.0 - centerDistance;
      final score = math.max(iou, centerScore);

      if (score > bestScore &&
          (iou >= AppConstants.liveTrackIouThreshold ||
              centerDistance <=
                  AppConstants.liveTrackCenterDistanceThreshold)) {
        bestScore = score;
        bestIndex = index;
      }
    }

    return bestIndex == -1 ? null : bestIndex;
  }

  LiveConfidenceTier _confidenceTierFor(double confidence) {
    if (confidence >= AppConstants.liveHighConfidenceThreshold) {
      return LiveConfidenceTier.normal;
    }
    if (confidence >= AppConstants.liveWeakConfidenceThreshold) {
      return LiveConfidenceTier.weak;
    }
    return LiveConfidenceTier.low;
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

  double _iou(Rect a, Rect b) {
    final left = math.max(a.left, b.left);
    final top = math.max(a.top, b.top);
    final right = math.min(a.right, b.right);
    final bottom = math.min(a.bottom, b.bottom);
    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) {
      return 0.0;
    }

    final intersection = width * height;
    final union = (a.width * a.height) + (b.width * b.height) - intersection;
    if (union <= 0) {
      return 0.0;
    }

    return intersection / union;
  }

  double _centerDistance(Rect a, Rect b) {
    final dx = a.center.dx - b.center.dx;
    final dy = a.center.dy - b.center.dy;
    return math.sqrt((dx * dx) + (dy * dy));
  }

  Future<void> _releaseCamera({required bool keepLiveState}) async {
    final controller = _cameraController;
    final inferenceWorker = _inferenceWorker;
    _cameraController = null;
    _inferenceWorker = null;
    _pendingFrame = null;
    _isProcessingFrame = false;
    _performanceTracker.reset();

    if (!keepLiveState) {
      _liveDetections = [];
      _tracks = [];
      _latestFrameSize = null;
      _latestFrameTelemetry = null;
      _hasProcessedFrame = false;
      _errorMessage = null;
    }

    if (controller == null) {
      await inferenceWorker?.dispose();
      return;
    }

    await _disposeController(controller);
    await inferenceWorker?.dispose();
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

class _StableDetectionTrack {
  _StableDetectionTrack({required this.boundingBox, required this.stableClass});

  factory _StableDetectionTrack.fromDetection(Detection detection) {
    return _StableDetectionTrack(
      boundingBox: detection.boundingBox,
      stableClass: detection.maturityClass,
    );
  }

  Rect boundingBox;
  MaturityClass stableClass;
  MaturityClass? pendingClass;
  int pendingCount = 0;

  void updateWith(Detection detection) {
    boundingBox = detection.boundingBox;

    if (detection.maturityClass == stableClass) {
      pendingClass = null;
      pendingCount = 0;
      return;
    }

    if (pendingClass == detection.maturityClass) {
      pendingCount++;
    } else {
      pendingClass = detection.maturityClass;
      pendingCount = 1;
    }

    if (pendingCount >= AppConstants.liveStableClassFrames) {
      stableClass = detection.maturityClass;
      pendingClass = null;
      pendingCount = 0;
    }
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
  int _framesDropped = 0;
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

  void recordFrameDropped() {
    _framesDropped++;
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
      'Frames dropped/skipped: $_framesDropped\n'
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
    _framesDropped = 0;
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
