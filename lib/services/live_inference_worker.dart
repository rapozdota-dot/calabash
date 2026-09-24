import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/camera_image_converter.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

class LiveInferenceWorker {
  static TfliteBackendConfig? _cachedBackendConfig;

  ReceivePort? _receivePort;
  Isolate? _isolate;
  SendPort? _workerPort;
  StreamSubscription<dynamic>? _subscription;
  final _pendingRequests = <int, Completer<LiveInferenceResult>>{};
  Completer<void>? _disposeCompleter;
  var _nextRequestId = 1;
  bool _isDisposed = false;

  LiveInferenceBackendInfo? backendInfo;

  bool get isReady => _workerPort != null && !_isDisposed;

  Future<void> start() async {
    if (isReady) {
      return;
    }

    final modelData = await rootBundle.load(AppConstants.modelAssetPath);
    final modelBytes = Uint8List.sublistView(modelData);
    final receivePort = ReceivePort();
    _receivePort = receivePort;

    final readyCompleter = Completer<void>();
    _subscription = receivePort.listen((message) {
      if (message is _LiveInferenceWorkerReady) {
        _workerPort = message.sendPort;
        backendInfo = message.backendInfo;
        _cachedBackendConfig = message.backendInfo.selectedConfig;
        if (!readyCompleter.isCompleted) {
          readyCompleter.complete();
        }
        return;
      }

      if (message is _LiveInferenceWorkerInitError) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(message.error, message.stackTrace);
        }
        return;
      }

      if (message is _LiveInferenceWorkerResult) {
        _pendingRequests.remove(message.requestId)?.complete(message.result);
        return;
      }

      if (message is _LiveInferenceWorkerRequestError) {
        _pendingRequests
            .remove(message.requestId)
            ?.completeError(message.error, message.stackTrace);
        return;
      }

      if (message is _LiveInferenceWorkerDisposed) {
        _disposeCompleter?.complete();
      }
    });

    _isolate = await Isolate.spawn(
      _liveInferenceWorkerMain,
      _LiveInferenceWorkerInit(
        replyPort: receivePort.sendPort,
        modelBytes: TransferableTypedData.fromList([modelBytes]),
        cachedBackendConfig: _cachedBackendConfig,
      ),
      debugName: 'CalabashLiveYoloWorker',
    );

    await readyCompleter.future;
  }

  Future<LiveInferenceResult> detect(LiveInferenceFrame frame) {
    final sendPort = _workerPort;
    if (_isDisposed || sendPort == null) {
      throw StateError('Live inference worker is not ready.');
    }

    final requestId = _nextRequestId++;
    final completer = Completer<LiveInferenceResult>();
    _pendingRequests[requestId] = completer;
    sendPort.send(_LiveInferenceWorkerDetect(requestId, frame));
    return completer.future;
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }

    _isDisposed = true;
    final sendPort = _workerPort;
    if (sendPort != null) {
      final disposeCompleter = Completer<void>();
      _disposeCompleter = disposeCompleter;
      sendPort.send(const _LiveInferenceWorkerDispose());
      await disposeCompleter.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      _disposeCompleter = null;
    }
    _workerPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    await _subscription?.cancel();
    _subscription = null;
    _receivePort?.close();
    _receivePort = null;

    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Live inference worker disposed.'));
      }
    }
    _pendingRequests.clear();
  }
}

class LiveInferenceFrame {
  LiveInferenceFrame({
    required this.frameId,
    required this.transferStartedAtMicros,
    required this.width,
    required this.height,
    required this.format,
    required this.rotationDegrees,
    required this.isFrontCamera,
    required this.planes,
  });

  factory LiveInferenceFrame.fromCameraImage({
    required int frameId,
    required CameraImage image,
    required int rotationDegrees,
    required CameraLensDirection lensDirection,
  }) {
    final transferStartedAtMicros = DateTime.now().microsecondsSinceEpoch;
    return LiveInferenceFrame(
      frameId: frameId,
      transferStartedAtMicros: transferStartedAtMicros,
      width: image.width,
      height: image.height,
      format: LiveInferenceImageFormat.fromCameraFormat(image.format.group),
      rotationDegrees: rotationDegrees,
      isFrontCamera: lensDirection == CameraLensDirection.front,
      planes: image.planes
          .map(
            (plane) => LiveInferencePlane(
              bytes: TransferableTypedData.fromList([plane.bytes]),
              bytesPerRow: plane.bytesPerRow,
              bytesPerPixel: plane.bytesPerPixel ?? 1,
            ),
          )
          .toList(growable: false),
    );
  }

  final int frameId;
  final int transferStartedAtMicros;
  final int width;
  final int height;
  final LiveInferenceImageFormat format;
  final int rotationDegrees;
  final bool isFrontCamera;
  final List<LiveInferencePlane> planes;
}

class LiveInferencePlane {
  const LiveInferencePlane({
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
  });

  final TransferableTypedData bytes;
  final int bytesPerRow;
  final int bytesPerPixel;
}

class LiveInferenceResult {
  const LiveInferenceResult({
    required this.frameId,
    required this.imageWidth,
    required this.imageHeight,
    required this.detections,
    required this.conversionTiming,
    required this.modelTimings,
    required this.frameTransferMicros,
    required this.backendInfo,
  });

  final int frameId;
  final int imageWidth;
  final int imageHeight;
  final List<LiveInferenceDetection> detections;
  final CameraImageConversionTiming conversionTiming;
  final ModelPipelineTimings modelTimings;
  final int frameTransferMicros;
  final LiveInferenceBackendInfo backendInfo;

  List<Detection> toDetections() {
    return detections
        .map((detection) => detection.toDetection())
        .toList(growable: false);
  }
}

class LiveInferenceDetection {
  const LiveInferenceDetection({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.classIndex,
    required this.confidence,
    this.mask,
  });

  factory LiveInferenceDetection.fromDetection(Detection detection) {
    final box = detection.boundingBox;
    final maturityClass = detection.maturityClass;
    return LiveInferenceDetection(
      left: box.left,
      top: box.top,
      width: box.width,
      height: box.height,
      classIndex: switch (maturityClass) {
        MaturityClass.immature => 0,
        MaturityClass.mature => 1,
        MaturityClass.overmature => 2,
        MaturityClass.unknown => -1,
      },
      confidence: detection.confidence,
      mask: detection.mask == null
          ? null
          : LiveInferenceMask.fromMask(detection.mask!),
    );
  }

  final double left;
  final double top;
  final double width;
  final double height;
  final int classIndex;
  final double confidence;
  final LiveInferenceMask? mask;

  Detection toDetection() {
    return Detection(
      boundingBox: ui.Rect.fromLTWH(left, top, width, height),
      maturityClass: switch (classIndex) {
        0 => MaturityClass.immature,
        1 => MaturityClass.mature,
        2 => MaturityClass.overmature,
        _ => MaturityClass.unknown,
      },
      confidence: confidence,
      mask: mask?.toMask(),
    );
  }
}

class LiveInferenceMask {
  const LiveInferenceMask({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.maskWidth,
    required this.maskHeight,
    required this.pixels,
  });

  factory LiveInferenceMask.fromMask(SegmentationMask mask) {
    return LiveInferenceMask(
      left: mask.bounds.left,
      top: mask.bounds.top,
      width: mask.bounds.width,
      height: mask.bounds.height,
      maskWidth: mask.width,
      maskHeight: mask.height,
      pixels: mask.pixels,
    );
  }

  final double left;
  final double top;
  final double width;
  final double height;
  final int maskWidth;
  final int maskHeight;
  final Uint8List pixels;

  SegmentationMask toMask() {
    return SegmentationMask(
      bounds: ui.Rect.fromLTWH(left, top, width, height),
      width: maskWidth,
      height: maskHeight,
      pixels: pixels,
    );
  }
}

class LiveInferenceBackendInfo {
  const LiveInferenceBackendInfo({
    required this.selectedConfig,
    required this.attempts,
    required this.fromCache,
  });

  final TfliteBackendConfig selectedConfig;
  final List<TfliteBackendBenchmark> attempts;
  final bool fromCache;

  String get label =>
      '${selectedConfig.label} (${selectedConfig.threads} thread${selectedConfig.threads == 1 ? '' : 's'})';
}

enum LiveInferenceImageFormat {
  yuv420,
  bgra8888,
  unsupported;

  static LiveInferenceImageFormat fromCameraFormat(ImageFormatGroup format) {
    return switch (format) {
      ImageFormatGroup.yuv420 => LiveInferenceImageFormat.yuv420,
      ImageFormatGroup.bgra8888 => LiveInferenceImageFormat.bgra8888,
      _ => LiveInferenceImageFormat.unsupported,
    };
  }
}

class _MaterializedPlane {
  const _MaterializedPlane({
    required this.bytes,
    required this.bytesPerRow,
    required this.bytesPerPixel,
  });

  final Uint8List bytes;
  final int bytesPerRow;
  final int bytesPerPixel;
}

class _LiveInferenceWorkerInit {
  const _LiveInferenceWorkerInit({
    required this.replyPort,
    required this.modelBytes,
    required this.cachedBackendConfig,
  });

  final SendPort replyPort;
  final TransferableTypedData modelBytes;
  final TfliteBackendConfig? cachedBackendConfig;
}

class _LiveInferenceWorkerReady {
  const _LiveInferenceWorkerReady({
    required this.sendPort,
    required this.backendInfo,
  });

  final SendPort sendPort;
  final LiveInferenceBackendInfo backendInfo;
}

class _LiveInferenceWorkerInitError {
  const _LiveInferenceWorkerInitError(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

class _LiveInferenceWorkerDetect {
  const _LiveInferenceWorkerDetect(this.requestId, this.frame);

  final int requestId;
  final LiveInferenceFrame frame;
}

class _LiveInferenceWorkerResult {
  const _LiveInferenceWorkerResult({
    required this.requestId,
    required this.result,
  });

  final int requestId;
  final LiveInferenceResult result;
}

class _LiveInferenceWorkerRequestError {
  const _LiveInferenceWorkerRequestError({
    required this.requestId,
    required this.error,
    required this.stackTrace,
  });

  final int requestId;
  final Object error;
  final StackTrace stackTrace;
}

class _LiveInferenceWorkerDispose {
  const _LiveInferenceWorkerDispose();
}

class _LiveInferenceWorkerDisposed {
  const _LiveInferenceWorkerDisposed();
}

Future<void> _liveInferenceWorkerMain(_LiveInferenceWorkerInit init) async {
  final commandPort = ReceivePort();
  final runtime = _LiveInferenceWorkerRuntime();

  try {
    final modelBytes = init.modelBytes.materialize().asUint8List();
    final backendInfo = await runtime.initialize(
      modelBytes: modelBytes,
      cachedBackendConfig: init.cachedBackendConfig,
    );
    init.replyPort.send(
      _LiveInferenceWorkerReady(
        sendPort: commandPort.sendPort,
        backendInfo: backendInfo,
      ),
    );
  } catch (error, stackTrace) {
    init.replyPort.send(_LiveInferenceWorkerInitError(error, stackTrace));
    commandPort.close();
    runtime.dispose();
    return;
  }

  await for (final message in commandPort) {
    if (message is _LiveInferenceWorkerDispose) {
      runtime.dispose();
      init.replyPort.send(const _LiveInferenceWorkerDisposed());
      commandPort.close();
      return;
    }

    if (message is _LiveInferenceWorkerDetect) {
      try {
        final result = await runtime.detect(message.frame);
        init.replyPort.send(
          _LiveInferenceWorkerResult(
            requestId: message.requestId,
            result: result,
          ),
        );
      } catch (error, stackTrace) {
        init.replyPort.send(
          _LiveInferenceWorkerRequestError(
            requestId: message.requestId,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }
  }
}

class _LiveInferenceWorkerRuntime {
  ModelService? _modelService;
  LiveInferenceBackendInfo? _backendInfo;

  Future<LiveInferenceBackendInfo> initialize({
    required Uint8List modelBytes,
    required TfliteBackendConfig? cachedBackendConfig,
  }) async {
    final cachedConfig = cachedBackendConfig;
    if (cachedConfig != null) {
      final cachedAttempt = await _tryBackend(
        modelBytes: modelBytes,
        config: cachedConfig,
        warmupRuns: 1,
        measuredRuns: 1,
      );
      if (cachedAttempt.service != null) {
        _modelService = cachedAttempt.service;
        _backendInfo = LiveInferenceBackendInfo(
          selectedConfig: cachedConfig,
          attempts: [cachedAttempt.benchmark],
          fromCache: true,
        );
        return _backendInfo!;
      }
    }

    final attempts = <TfliteBackendBenchmark>[];
    _BackendAttempt? bestAttempt;

    for (final config in _candidateBackends(cachedConfig)) {
      final attempt = await _tryBackend(
        modelBytes: modelBytes,
        config: config,
        warmupRuns: 1,
        measuredRuns: 2,
      );
      attempts.add(attempt.benchmark);

      final service = attempt.service;
      if (service == null) {
        continue;
      }

      if (bestAttempt == null ||
          attempt.benchmark.averageMicros <
              bestAttempt.benchmark.averageMicros) {
        bestAttempt?.service?.dispose();
        bestAttempt = attempt;
      } else {
        service.dispose();
      }
    }

    if (bestAttempt == null) {
      throw StateError(
        'No compatible TensorFlow Lite backend initialized for live inference.',
      );
    }

    _modelService = bestAttempt.service;
    _backendInfo = LiveInferenceBackendInfo(
      selectedConfig: bestAttempt.benchmark.config,
      attempts: attempts,
      fromCache: false,
    );
    return _backendInfo!;
  }

  Future<_BackendAttempt> _tryBackend({
    required Uint8List modelBytes,
    required TfliteBackendConfig config,
    required int warmupRuns,
    required int measuredRuns,
  }) async {
    if (config.isAndroidOnly && !Platform.isAndroid) {
      return _BackendAttempt(
        benchmark: TfliteBackendBenchmark(
          config: config,
          initialized: false,
          warmupMicros: 0,
          averageMicros: 0,
          minMicros: 0,
          maxMicros: 0,
          errorMessage: 'Backend is Android-only on this package.',
        ),
      );
    }

    final service = ModelService(
      modelBuffer: Uint8List.fromList(modelBytes),
      backendConfig: config,
    );

    try {
      final benchmark = await service.benchmarkInference(
        warmupRuns: warmupRuns,
        measuredRuns: measuredRuns,
      );
      return _BackendAttempt(service: service, benchmark: benchmark);
    } catch (error) {
      service.dispose();
      return _BackendAttempt(
        benchmark: TfliteBackendBenchmark(
          config: config,
          initialized: false,
          warmupMicros: 0,
          averageMicros: 0,
          minMicros: 0,
          maxMicros: 0,
          errorMessage: error.toString(),
        ),
      );
    }
  }

  List<TfliteBackendConfig> _candidateBackends(
    TfliteBackendConfig? cachedConfig,
  ) {
    final highThreadCount = math.max(
      2,
      math.min(4, Platform.numberOfProcessors ~/ 2),
    );
    final candidates = <TfliteBackendConfig>[
      if (Platform.isAndroid)
        const TfliteBackendConfig(
          kind: TfliteBackendKind.gpu,
          label: 'GPU delegate',
          threads: 1,
        ),
      if (Platform.isAndroid)
        const TfliteBackendConfig(
          kind: TfliteBackendKind.nnapi,
          label: 'NNAPI',
          threads: 2,
        ),
      TfliteBackendConfig(
        kind: TfliteBackendKind.xnnpack,
        label: 'XNNPACK CPU',
        threads: highThreadCount,
      ),
      const TfliteBackendConfig(
        kind: TfliteBackendKind.xnnpack,
        label: 'XNNPACK CPU',
        threads: 2,
      ),
      TfliteBackendConfig(
        kind: TfliteBackendKind.cpu,
        label: 'CPU',
        threads: highThreadCount,
      ),
      TfliteBackendConfig.cpu2,
    ];

    final seen = <String>{};
    return candidates
        .where((config) => config.cacheKey != cachedConfig?.cacheKey)
        .where((config) => seen.add(config.cacheKey))
        .toList(growable: false);
  }

  Future<LiveInferenceResult> detect(LiveInferenceFrame frame) async {
    final modelService = _modelService;
    final backendInfo = _backendInfo;
    if (modelService == null || backendInfo == null) {
      throw StateError('Live inference runtime has not been initialized.');
    }

    final workerReceivedAtMicros = DateTime.now().microsecondsSinceEpoch;
    final conversionTiming = CameraImageConversionTiming();
    final decodedFrame = _toImage(frame, timing: conversionTiming);
    final modelResult = await modelService.detectFruitsFromImageWithMetrics(
      decodedFrame,
    );

    return LiveInferenceResult(
      frameId: frame.frameId,
      imageWidth: decodedFrame.width,
      imageHeight: decodedFrame.height,
      detections: modelResult.detections
          .map(LiveInferenceDetection.fromDetection)
          .toList(growable: false),
      conversionTiming: conversionTiming,
      modelTimings: modelResult.timings,
      frameTransferMicros:
          workerReceivedAtMicros - frame.transferStartedAtMicros,
      backendInfo: backendInfo,
    );
  }

  img.Image _toImage(
    LiveInferenceFrame frame, {
    required CameraImageConversionTiming timing,
  }) {
    final materializedPlanes = frame.planes
        .map(
          (plane) => _MaterializedPlane(
            bytes: plane.bytes.materialize().asUint8List(),
            bytesPerRow: plane.bytesPerRow,
            bytesPerPixel: plane.bytesPerPixel,
          ),
        )
        .toList(growable: false);

    final rgbStopwatch = Stopwatch()..start();
    final rgbImage = switch (frame.format) {
      LiveInferenceImageFormat.yuv420 => _fromYuv420(frame, materializedPlanes),
      LiveInferenceImageFormat.bgra8888 => _fromBgra8888(
        frame,
        materializedPlanes,
      ),
      LiveInferenceImageFormat.unsupported => throw UnsupportedError(
        'Unsupported camera image format for live inference worker.',
      ),
    };
    rgbStopwatch.stop();
    timing.rgbConversionMicros = rgbStopwatch.elapsedMicroseconds;

    final orientationStopwatch = Stopwatch()..start();
    final normalizedRotation = frame.rotationDegrees % 360;
    var orientedImage = normalizedRotation == 0
        ? rgbImage
        : img.copyRotate(rgbImage, angle: normalizedRotation);
    if (frame.isFrontCamera) {
      orientedImage = img.flipHorizontal(orientedImage);
    }
    orientationStopwatch.stop();
    timing.orientationMicros = orientationStopwatch.elapsedMicroseconds;

    return orientedImage;
  }

  img.Image _fromYuv420(
    LiveInferenceFrame frame,
    List<_MaterializedPlane> planes,
  ) {
    if (planes.length < 3) {
      throw StateError('YUV420 frames must include Y, U, and V planes.');
    }

    final image = img.Image(
      width: frame.width,
      height: frame.height,
      numChannels: 3,
    );
    final yPlane = planes[0];
    final uPlane = planes[1];
    final vPlane = planes[2];

    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel;

    for (var y = 0; y < frame.height; y++) {
      final yRowOffset = yPlane.bytesPerRow * y;
      final uvRowOffset = uvRowStride * (y >> 1);

      for (var x = 0; x < frame.width; x++) {
        final uvOffset = uvRowOffset + ((x >> 1) * uvPixelStride);
        final yValue = yPlane.bytes[yRowOffset + x].toDouble();
        final uValue = uPlane.bytes[uvOffset].toDouble() - 128.0;
        final vValue = vPlane.bytes[uvOffset].toDouble() - 128.0;

        final red = _clampToByte(yValue + (1.402 * vValue));
        final green = _clampToByte(
          yValue - (0.344136 * uValue) - (0.714136 * vValue),
        );
        final blue = _clampToByte(yValue + (1.772 * uValue));

        image.setPixelRgb(x, y, red, green, blue);
      }
    }

    return image;
  }

  img.Image _fromBgra8888(
    LiveInferenceFrame frame,
    List<_MaterializedPlane> planes,
  ) {
    if (planes.isEmpty) {
      throw StateError('BGRA frames must include one image plane.');
    }

    final plane = planes.first;
    final image = img.Image(
      width: frame.width,
      height: frame.height,
      numChannels: 3,
    );

    for (var y = 0; y < frame.height; y++) {
      final rowOffset = y * plane.bytesPerRow;
      for (var x = 0; x < frame.width; x++) {
        final pixelOffset = rowOffset + (x * plane.bytesPerPixel);
        final blue = plane.bytes[pixelOffset];
        final green = plane.bytes[pixelOffset + 1];
        final red = plane.bytes[pixelOffset + 2];
        image.setPixelRgb(x, y, red, green, blue);
      }
    }

    return image;
  }

  int _clampToByte(double value) {
    return math.max(0, math.min(255, value.round()));
  }

  void dispose() {
    _modelService?.dispose();
    _modelService = null;
  }
}

class _BackendAttempt {
  const _BackendAttempt({this.service, required this.benchmark});

  final ModelService? service;
  final TfliteBackendBenchmark benchmark;
}
