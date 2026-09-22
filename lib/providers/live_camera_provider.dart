import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/camera_image_converter.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/foundation.dart';
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
  LiveCameraProvider({required ModelService modelService})
    : _modelService = modelService {
    WidgetsBinding.instance.addObserver(this);
  }

  final ModelService _modelService;

  CameraController? _cameraController;
  LiveCameraStatus _status = LiveCameraStatus.initial;
  List<LiveDetection> _liveDetections = [];
  List<_StableDetectionTrack> _tracks = [];
  Size? _latestFrameSize;
  DateTime? _lastInferenceAt;
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

  void _handleCameraFrame(CameraImage frame) {
    if (_isDisposed || _isProcessingFrame) {
      return;
    }

    final now = DateTime.now();
    final lastInferenceAt = _lastInferenceAt;
    if (lastInferenceAt != null &&
        now.difference(lastInferenceAt) < AppConstants.liveInferenceInterval) {
      return;
    }

    _lastInferenceAt = now;
    unawaited(_processFrame(frame));
  }

  Future<void> _processFrame(CameraImage frame) async {
    final activeController = _cameraController;
    if (activeController == null || _isDisposed) {
      return;
    }

    _isProcessingFrame = true;
    _safeNotifyListeners();

    try {
      final rotationDegrees = _rotationDegrees(
        activeController.description,
        activeController.value.deviceOrientation,
      );
      final decodedFrame = CameraImageConverter.toImage(
        frame,
        rotationDegrees: rotationDegrees,
        lensDirection: activeController.description.lensDirection,
      );

      final detections = await _modelService.detectFruitsFromImage(
        decodedFrame,
      );
      if (_isDisposed || _cameraController != activeController) {
        return;
      }

      _latestFrameSize = Size(
        decodedFrame.width.toDouble(),
        decodedFrame.height.toDouble(),
      );
      _liveDetections = _stabilizeDetections(detections);
      _hasProcessedFrame = true;
      _errorMessage = null;
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
        _safeNotifyListeners();
      }
    }
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
    _cameraController = null;
    _lastInferenceAt = null;
    _isProcessingFrame = false;

    if (!keepLiveState) {
      _liveDetections = [];
      _tracks = [];
      _latestFrameSize = null;
      _hasProcessedFrame = false;
      _errorMessage = null;
    }

    if (controller == null) {
      return;
    }

    await _disposeController(controller);
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
