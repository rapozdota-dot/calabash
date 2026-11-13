import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/image_tensor_layout.dart';
import 'package:calabash_maturity_detection/services/segmentation_postprocessor.dart';
import 'package:calabash_maturity_detection/services/tensor_buffer_transfer.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Final fruit predictions plus timings for one complete model pipeline run.
class ModelDetectionResult {
  const ModelDetectionResult({required this.detections, required this.timings});

  final List<Detection> detections;
  final ModelPipelineTimings timings;
}

/// Photo acquisition/worker setup is separate from the shared model-stage timings.
class PhotoDetectionResult {
  const PhotoDetectionResult({
    required this.modelResult,
    required this.imageWidth,
    required this.imageHeight,
    this.fileReadMicros,
    this.decodeMicros,
    this.modelInitializationMicros,
  });

  final ModelDetectionResult modelResult;
  final int imageWidth;
  final int imageHeight;
  final int? fileReadMicros;
  final int? decodeMicros;
  final int? modelInitializationMicros;
}

/// Stage durations in microseconds, used to locate mobile performance bottlenecks.
class ModelPipelineTimings {
  const ModelPipelineTimings({
    required this.preprocessMicros,
    required this.resizeLetterboxMicros,
    required this.tensorFillMicros,
    required this.inferenceMicros,
    required this.candidateParsingMicros,
    required this.nmsMicros,
    required this.protoExtractionMicros,
    required this.maskReconstructionMicros,
    required this.postprocessMicros,
    required this.totalMicros,
    this.invokeMicros,
    this.inputTensorMicros,
    this.outputTensorMicros,
  });

  final int preprocessMicros;
  final int resizeLetterboxMicros;
  final int tensorFillMicros;

  /// Legacy aggregate: input assignment + invoke + output copies.
  final int inferenceMicros;

  /// Interpreter.invoke() only, using boundaries on the same monotonic clock.
  final int? invokeMicros;
  final int? inputTensorMicros;
  final int? outputTensorMicros;
  final int candidateParsingMicros;
  final int nmsMicros;
  final int protoExtractionMicros;
  final int maskReconstructionMicros;
  final int postprocessMicros;
  final int totalMicros;
}

enum TfliteBackendKind { cpu, xnnpack, nnapi, gpu }

class TfliteBackendConfig {
  const TfliteBackendConfig({
    required this.kind,
    required this.label,
    required this.threads,
  });

  final TfliteBackendKind kind;
  final String label;
  final int threads;

  /// Identifies a delegate/thread combination for cached selection and deduplication.
  String get cacheKey => '${kind.name}:$threads';

  /// Restricts this package's GPU/NNAPI options to supported Android execution paths.
  bool get isAndroidOnly =>
      kind == TfliteBackendKind.gpu || kind == TfliteBackendKind.nnapi;

  static const cpu2 = TfliteBackendConfig(
    kind: TfliteBackendKind.cpu,
    label: 'CPU',
    threads: 2,
  );
}

class TfliteBackendBenchmark {
  const TfliteBackendBenchmark({
    required this.config,
    required this.initialized,
    required this.warmupMicros,
    required this.averageMicros,
    required this.minMicros,
    required this.maxMicros,
    this.errorMessage,
  });

  final TfliteBackendConfig config;
  final bool initialized;
  final int warmupMicros;
  final int averageMicros;
  final int minMicros;
  final int maxMicros;
  final String? errorMessage;
}

/// Offline inference for the MobileNetV3-Small + YOLOv8 segmentation export.
/// The backbone and segmentation head run together in one interpreter.
/// One instance owns mutable reusable buffers and must process scans serially.
class ModelService {
  static const int _classCount = 3;
  static const int _maskChannelCount = 32;
  static const int _candidateCount = 1029;
  static const int _protoHeight = 56;
  static const int _protoWidth = 56;
  static const int _protoPlaneSize = _protoHeight * _protoWidth;
  static const int _debugLogCount = 5;
  static const int _detectionChannelCount = 4 + _classCount + _maskChannelCount;
  static const int _inputTensorElementCount =
      AppConstants.modelInputSize * AppConstants.modelInputSize * 3;
  static const double _letterboxFillValue = 114.0 / 255.0;
  static const bool _enableVerboseModelLogs = false;
  static const bool _traceNativeSmoke = bool.fromEnvironment(
    'CALABASH_TFLITE_SMOKE_TRACE',
  );

  static const List<int> _expectedDetectionShape = [
    1,
    _detectionChannelCount,
    _candidateCount,
  ];
  static const List<int> _expectedInputShape = [
    1,
    3,
    AppConstants.modelInputSize,
    AppConstants.modelInputSize,
  ];
  static const List<int> _expectedProtoShape = [
    1,
    _maskChannelCount,
    _protoHeight,
    _protoWidth,
  ];

  ModelService({
    Uint8List? modelBuffer,
    TfliteBackendConfig backendConfig = TfliteBackendConfig.cpu2,
    double confidenceThreshold = AppConstants.confidenceThreshold,
    int maxDetections = AppConstants.maxDetections,
  }) : _modelBuffer = modelBuffer,
       _backendConfig = backendConfig,
       _confidenceThreshold = confidenceThreshold,
       _maxDetections = maxDetections;

  final Uint8List? _modelBuffer;
  final TfliteBackendConfig _backendConfig;
  final double _confidenceThreshold;
  final int _maxDetections;

  Interpreter? _interpreter;
  Delegate? _delegate;
  Future<void>? _modelLoading;
  bool _didLogTensorShapes = false;
  int? _detectionOutputIndex;
  int? _protoOutputIndex;
  _ModelTensorWorkspace? _tensorWorkspace;
  Uint8List? _photoModelBytes;

  /// Reports interpreter availability; callers must still await loadModel for completed validation.
  bool get isModelReady => _interpreter != null;

  /// Exposes the selected delegate and thread settings for diagnostics.
  TfliteBackendConfig get backendConfig => _backendConfig;

  String get photoConfigurationDescription =>
      '${AppConstants.modelName} ${AppConstants.modelVersion};'
      'input=${AppConstants.modelInputSize};'
      'confidence=$_confidenceThreshold;iou=${AppConstants.iouThreshold};'
      'max_detections=$_maxDetections;CPU;threads=2;interpreter=new_per_photo';

  /// Enables detailed tensor/candidate logs only in debug builds when explicitly switched on.
  bool get _shouldVerboseLog => kDebugMode && _enableVerboseModelLogs;

  /// Smoke builds log from the worker before entering a synchronous FFI call.
  /// The test isolate can still time out if the worker never returns.
  void _logNativeSmoke(String event, String operation) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    debugPrintSynchronously(
      '[$timestamp][tflite-smoke][${Isolate.current.debugName}] '
      '$event $operation (backend=${_backendConfig.label})',
    );
  }

  void _validateNativeSmokeOutputs(_ModelTensorWorkspace workspace) {
    _logNativeSmoke('START', 'check raw output tensors');
    final outputs = {
      'detections': workspace.detectionOutputBuffer,
      'mask prototypes': workspace.protoOutputBuffer,
    };
    for (final output in outputs.entries) {
      final invalidIndex = output.value.indexWhere((value) => !value.isFinite);
      if (invalidIndex >= 0) {
        throw StateError(
          'Non-finite value at index $invalidIndex in ${output.key} output.',
        );
      }
    }
    _logNativeSmoke('PASS', 'check raw output tensors');
  }

  /// Shares one initialization future between concurrent callers.
  /// Repeated scans reuse the validated interpreter instead of loading weights each time.
  Future<void> loadModel() {
    // Concurrent callers must wait for validation, not skip initialization.
    final pending = _modelLoading;
    if (pending != null) return pending;
    if (_interpreter != null) return Future<void>.value();
    final loading = _loadModel().whenComplete(() => _modelLoading = null);
    _modelLoading = loading;
    return loading;
  }

  /// Creates the runtime, validates shapes/dtypes, and logs the tensor signature.
  /// Any failure frees partially initialized native resources and is rethrown to the caller.
  Future<void> _loadModel() async {
    try {
      final runtime = await _createInterpreter();
      _interpreter = runtime.interpreter;
      _delegate = runtime.delegate;
      if (_traceNativeSmoke) {
        _logNativeSmoke('START', 'validate tensor signature');
      }
      _validateModelSignature();
      if (_traceNativeSmoke) {
        _logNativeSmoke('PASS', 'validate tensor signature');
      }
      _logTensorShapes();
      debugPrint(
        'TFLite segmentation model loaded successfully '
        '(${_backendConfig.label}, threads=${_backendConfig.threads}).',
      );
    } catch (error) {
      debugPrint('Model loading failed. Error: $error');
      dispose();
      rethrow;
    }
  }

  /// Creates a TFLite interpreter from bundled assets or transferred model bytes.
  /// Sets thread/delegate options and releases native option objects on success or failure.
  Future<_InterpreterRuntime> _createInterpreter() async {
    if (_traceNativeSmoke) {
      _logNativeSmoke('START', 'create interpreter options');
    }
    final options = InterpreterOptions()..threads = _backendConfig.threads;
    if (_traceNativeSmoke) {
      _logNativeSmoke('PASS', 'create interpreter options');
    }
    Delegate? delegate;

    try {
      if (_traceNativeSmoke) {
        _logNativeSmoke('START', 'configure native delegate');
      }
      delegate = _createDelegateFor(_backendConfig, options);
      if (_traceNativeSmoke) {
        _logNativeSmoke('PASS', 'configure native delegate');
      }
      final modelBuffer = _modelBuffer;
      // tflite_flutter 0.11.0 creates and allocates tensors in one constructor.
      if (_traceNativeSmoke) {
        _logNativeSmoke('START', 'create interpreter and allocate tensors');
      }
      final interpreter = modelBuffer == null
          ? await Interpreter.fromAsset(
              AppConstants.modelAssetPath,
              options: options,
            )
          : Interpreter.fromBuffer(modelBuffer, options: options);
      if (_traceNativeSmoke) {
        _logNativeSmoke('PASS', 'create interpreter and allocate tensors');
      }
      options.delete();
      return _InterpreterRuntime(interpreter: interpreter, delegate: delegate);
    } catch (_) {
      options.delete();
      delegate?.delete();
      rethrow;
    }
  }

  /// Attaches the requested GPU/XNNPACK delegate or enables NNAPI; plain CPU needs none.
  /// Delegates accelerate execution, not change preprocessing or class interpretation.
  Delegate? _createDelegateFor(
    TfliteBackendConfig config,
    InterpreterOptions options,
  ) {
    switch (config.kind) {
      case TfliteBackendKind.cpu:
        return null;
      case TfliteBackendKind.nnapi:
        options.useNnApiForAndroid = true;
        return null;
      case TfliteBackendKind.xnnpack:
        final delegateOptions = XNNPackDelegateOptions(
          numThreads: config.threads,
        );
        final delegate = XNNPackDelegate(options: delegateOptions);
        delegateOptions.delete();
        options.addDelegate(delegate);
        return delegate;
      case TfliteBackendKind.gpu:
        final delegate = GpuDelegateV2();
        options.addDelegate(delegate);
        return delegate;
    }
  }

  /// Warms up and times interpreter execution with neutral input for backend selection.
  /// These timings exclude image conversion, preprocessing, and mask reconstruction.
  Future<TfliteBackendBenchmark> benchmarkInference({
    int warmupRuns = 1,
    int measuredRuns = 2,
  }) async {
    await loadModel();

    final workspace = _ensureTensorWorkspace();
    workspace.inputBuffer.fillRange(
      0,
      workspace.inputBuffer.length,
      _letterboxFillValue,
    );

    var warmupMicros = 0;
    for (var index = 0; index < warmupRuns; index++) {
      warmupMicros = _runInference(workspace);
    }

    final measured = <int>[];
    for (var index = 0; index < measuredRuns; index++) {
      measured.add(_runInference(workspace));
    }

    final total = measured.fold<int>(0, (sum, value) => sum + value);
    return TfliteBackendBenchmark(
      config: _backendConfig,
      initialized: true,
      warmupMicros: warmupMicros,
      averageMicros: measured.isEmpty ? 0 : total ~/ measured.length,
      minMicros: measured.isEmpty ? 0 : measured.reduce(math.min),
      maxMicros: measured.isEmpty ? 0 : measured.reduce(math.max),
    );
  }

  /// Keeps JPEG decoding, tensor filling, inference, and masks off the UI thread.
  /// A photo worker owns its interpreter; native handles are never shared across isolates.
  Future<List<Detection>> detectFruits(File imageFile) async {
    final result = await _detectPhoto(imageFile, collectMetrics: false);
    return result.modelResult.detections;
  }

  /// Preserves the photo worker and detector, retaining their existing stage timings.
  Future<PhotoDetectionResult> detectFruitsWithMetrics(File imageFile) =>
      _detectPhoto(imageFile, collectMetrics: true);

  Future<PhotoDetectionResult> _detectPhoto(
    File imageFile, {
    required bool collectMetrics,
  }) async {
    if (_traceNativeSmoke) _logNativeSmoke('START', 'load photo model asset');
    final bytes = _photoModelBytes ??=
        _modelBuffer ??
        Uint8List.sublistView(
          await rootBundle.load(AppConstants.modelAssetPath),
        );
    if (_traceNativeSmoke) _logNativeSmoke('PASS', 'load photo model asset');
    return compute(_inferPhoto, (
      bytes: bytes,
      path: imageFile.path,
      threshold: _confidenceThreshold,
      limit: _maxDetections,
      collectMetrics: collectMetrics,
    ));
  }

  /// Uses the same parser and preprocessing as live frames, with deterministic CPU inference.
  static Future<PhotoDetectionResult> _inferPhoto(
    ({
      Uint8List bytes,
      String path,
      double threshold,
      int limit,
      bool collectMetrics,
    })
    request,
  ) async {
    final service = ModelService(
      modelBuffer: request.bytes,
      confidenceThreshold: request.threshold,
      maxDetections: request.limit,
    );
    try {
      if (_traceNativeSmoke) {
        service._logNativeSmoke('START', 'read photo file');
      }
      final readTimer = request.collectMetrics ? (Stopwatch()..start()) : null;
      final bytes = await File(request.path).readAsBytes();
      readTimer?.stop();
      if (_traceNativeSmoke) {
        service._logNativeSmoke('PASS', 'read photo file');
        service._logNativeSmoke('START', 'decode photo file');
      }
      final decodeTimer = request.collectMetrics
          ? (Stopwatch()..start())
          : null;
      final image = service._decodeImageBytes(bytes);
      decodeTimer?.stop();
      if (_traceNativeSmoke) {
        service._logNativeSmoke('PASS', 'decode photo file');
      }
      final initializationTimer = request.collectMetrics
          ? (Stopwatch()..start())
          : null;
      if (initializationTimer != null) await service.loadModel();
      initializationTimer?.stop();
      final result = await service.detectFruitsFromImageWithMetrics(image);
      return PhotoDetectionResult(
        modelResult: result,
        imageWidth: image.width,
        imageHeight: image.height,
        fileReadMicros: readTimer?.elapsedMicroseconds,
        decodeMicros: decodeTimer?.elapsedMicroseconds,
        modelInitializationMicros: initializationTimer?.elapsedMicroseconds,
      );
    } finally {
      service.dispose();
    }
  }

  /// Runs inference on an already decoded RGB image and returns final detections only.
  Future<List<Detection>> detectFruitsFromImage(img.Image image) async {
    final result = await detectFruitsFromImageWithMetrics(image);
    return result.detections;
  }

  /// Awaits validated model loading, checks output availability, and returns detections plus stage timings.
  /// This async method does not itself create an isolate; the live worker provides that isolation.
  Future<ModelDetectionResult> detectFruitsFromImageWithMetrics(
    img.Image image,
  ) async {
    await loadModel();

    if (_interpreter == null) {
      throw StateError('TensorFlow Lite model is not available.');
    }
    if (_detectionOutputIndex == null || _protoOutputIndex == null) {
      throw StateError(
        'Model outputs do not match YOLOv8 segmentation tensors.',
      );
    }

    try {
      return _detectFruitsFromDecodedImage(image);
    } catch (error) {
      debugPrint('Inference failed. Error: $error');
      rethrow;
    }
  }

  /// Reads and decodes the photo, then bakes EXIF orientation into its pixels.
  /// Correct orientation is needed before resizing and mapping overlays back to the photo.
  img.Image _decodeImageBytes(Uint8List imageBytes) {
    final decodedImage = img.decodeImage(imageBytes);
    if (decodedImage == null) {
      throw StateError('Unable to decode image for inference.');
    }
    return img.bakeOrientation(decodedImage);
  }

  /// Orchestrates letterbox -> TFLite -> candidates -> class-aware NMS -> masks -> UI detections.
  /// Only surviving candidates reconstruct masks.
  ModelDetectionResult _detectFruitsFromDecodedImage(img.Image decodedImage) {
    final timings = _MutableModelPipelineTimings();
    final totalStopwatch = Stopwatch()..start();

    if (_traceNativeSmoke) {
      _logNativeSmoke('START', 'prepare input and tensor buffers');
    }
    final workspace = _ensureTensorWorkspace();
    final preprocessed = _preprocessImage(
      decodedImage,
      workspace: workspace,
      timings: timings,
    );
    if (_traceNativeSmoke) {
      _logNativeSmoke('PASS', 'prepare input and tensor buffers');
    }
    _runInference(workspace, timings);

    final detections = _decodeOutputs(
      detectionOutput: workspace.detectionOutputBuffer,
      prototypes: workspace.protoOutputBuffer,
      maskLogits: workspace.maskLogitsBuffer,
      metadata: preprocessed,
      timings: timings,
    );
    totalStopwatch.stop();
    timings.totalMicros = totalStopwatch.elapsedMicroseconds;
    return ModelDetectionResult(
      detections: detections,
      timings: timings.toImmutable(),
    );
  }

  @visibleForTesting
  List<Detection> decodeOutputsForTest({
    required Float32List detectionOutput,
    required Float32List prototypes,
    required LetterboxTransform letterbox,
  }) => _decodeOutputs(
    detectionOutput: detectionOutput,
    prototypes: prototypes,
    maskLogits: Float32List(_protoPlaneSize),
    metadata: letterbox,
    timings: _MutableModelPipelineTimings(),
  );

  List<Detection> _decodeOutputs({
    required Float32List detectionOutput,
    required Float32List prototypes,
    required Float32List maskLogits,
    required LetterboxTransform metadata,
    required _MutableModelPipelineTimings timings,
  }) {
    if (detectionOutput.length != _detectionChannelCount * _candidateCount ||
        prototypes.length != _maskChannelCount * _protoPlaneSize) {
      throw ArgumentError('Output buffer sizes do not match the V8 model.');
    }
    if (_traceNativeSmoke) _logNativeSmoke('START', 'decode model outputs');
    final postprocessStopwatch = Stopwatch()..start();
    final candidateParsingStopwatch = Stopwatch()..start();
    final candidates = _parseSegmentationCandidates(
      detectionOutput: detectionOutput,
      metadata: metadata,
    );
    candidateParsingStopwatch.stop();
    timings.candidateParsingMicros =
        candidateParsingStopwatch.elapsedMicroseconds;

    final nmsStopwatch = Stopwatch()..start();
    final nmsCandidates = SegmentationPostprocessor.suppressDuplicates(
      candidates,
      boxOf: (candidate) => candidate.modelSpaceBox,
      confidenceOf: (candidate) => candidate.confidence,
      classOf: (candidate) => candidate.classIndex,
      iouThreshold: AppConstants.iouThreshold,
      maxDetections: _maxDetections,
    );
    nmsStopwatch.stop();
    timings.nmsMicros = nmsStopwatch.elapsedMicroseconds;

    var finalCandidates = nmsCandidates;
    if (nmsCandidates.isNotEmpty) {
      // Prototype planes are already contiguous in the output buffer.
      final maskStopwatch = Stopwatch()..start();
      finalCandidates = _attachMasksAndFilterCandidates(
        candidates: nmsCandidates,
        protoTensor: prototypes,
        maskLogitsBuffer: maskLogits,
        metadata: metadata,
      );
      maskStopwatch.stop();
      timings.maskReconstructionMicros = maskStopwatch.elapsedMicroseconds;
    }

    final detections = finalCandidates
        .map((candidate) => candidate.toDetection(metadata))
        .toList(growable: false);

    if (_shouldVerboseLog) {
      debugPrint(
        'Postprocess summary: parsed=${candidates.length} '
        'afterNms=${nmsCandidates.length} final=${detections.length}',
      );
      _logDetectionPreview(
        detections: detections,
        label: 'Top detections after NMS/mask filter',
      );
    }

    postprocessStopwatch.stop();
    timings.postprocessMicros = postprocessStopwatch.elapsedMicroseconds;
    if (_traceNativeSmoke) _logNativeSmoke('PASS', 'decode model outputs');
    return detections;
  }

  /// Fits the image proportionally inside the model canvas.
  /// Centers the resized image in RGB-114 padding, writes normalized float32 RGB, and saves
  /// scale/padding metadata so both boxes and masks can be remapped to the original image.
  LetterboxTransform _preprocessImage(
    img.Image decodedImage, {
    required _ModelTensorWorkspace workspace,
    required _MutableModelPipelineTimings timings,
  }) {
    final preprocessStopwatch = Stopwatch()..start();
    final letterbox = LetterboxTransform(
      sourceWidth: decodedImage.width,
      sourceHeight: decodedImage.height,
      inputSize: AppConstants.modelInputSize,
    );

    final resizeStopwatch = Stopwatch()..start();
    final resized = letterbox.resizeRgb(decodedImage);
    resizeStopwatch.stop();
    timings.resizeLetterboxMicros = resizeStopwatch.elapsedMicroseconds;

    final tensorStopwatch = Stopwatch()..start();
    final range = letterbox.writeRgbImage(
      image: resized,
      buffer: workspace.inputBuffer,
      collectRange: _shouldVerboseLog,
    );

    tensorStopwatch.stop();
    timings.tensorFillMicros = tensorStopwatch.elapsedMicroseconds;

    if (_shouldVerboseLog) {
      debugPrint(
        'Preprocess: shape=${_interpreter!.getInputTensor(0).shape} '
        'layout=NCHW '
        'range=[${range.minValue.toStringAsFixed(4)}, ${range.maxValue.toStringAsFixed(4)}] '
        'content=${letterbox.contentBounds}',
      );
    }
    preprocessStopwatch.stop();
    timings.preprocessMicros = preprocessStopwatch.elapsedMicroseconds;

    return letterbox;
  }

  /// Keeps the legacy call-path duration while exposing its three sequential parts.
  /// These parts sum to inferenceMicros; never add them to that aggregate again.
  int _runInference(
    _ModelTensorWorkspace workspace, [
    _MutableModelPipelineTimings? measuredTimings,
  ]) {
    final timings = measuredTimings ?? _MutableModelPipelineTimings();
    final stopwatch = Stopwatch()..start();
    final interpreter = _interpreter!;
    // The validated, fixed-size interpreter is already allocated. Avoid the
    // plugin's ByteBuffer copyTo path, which writes output one byte at a time.
    if (_traceNativeSmoke) _logNativeSmoke('START', 'copy input tensor');
    interpreter.getInputTensor(0).data = workspace.inputBuffer.buffer
        .asUint8List();
    final inputFinished = stopwatch.elapsedMicroseconds;
    if (_traceNativeSmoke) {
      _logNativeSmoke('PASS', 'copy input tensor');
      _logNativeSmoke('START', 'Interpreter.invoke');
    }
    interpreter.invoke();
    final invokeFinished = stopwatch.elapsedMicroseconds;
    if (_traceNativeSmoke) {
      _logNativeSmoke('PASS', 'Interpreter.invoke');
      _logNativeSmoke('START', 'copy output tensors');
    }
    for (final output in workspace.rawOutputs.entries) {
      // Native output is volatile: bulk-copy it before the next invocation.
      TensorBufferTransfer.copyExact(
        interpreter.getOutputTensor(output.key).data,
        output.value,
      );
    }
    stopwatch.stop();
    if (_traceNativeSmoke) _logNativeSmoke('PASS', 'copy output tensors');
    timings.inferenceMicros = stopwatch.elapsedMicroseconds;
    timings.inputTensorMicros = inputFinished;
    timings.invokeMicros = invokeFinished - inputFinished;
    timings.outputTensorMicros = timings.inferenceMicros - invokeFinished;
    if (_traceNativeSmoke) _validateNativeSmokeOutputs(workspace);
    return timings.inferenceMicros;
  }

  /// Allocates tensor buffers once per interpreter and reuses them across scans/frames.
  _ModelTensorWorkspace _ensureTensorWorkspace() {
    final existingWorkspace = _tensorWorkspace;
    if (existingWorkspace != null) {
      return existingWorkspace;
    }

    final workspace = _createTensorWorkspace();
    _tensorWorkspace = workspace;
    return workspace;
  }

  /// Allocates reusable float32 buffers after validating the interpreter's signature.
  _ModelTensorWorkspace _createTensorWorkspace() {
    final detections = Float32List(_detectionChannelCount * _candidateCount);
    final prototypes = Float32List(_maskChannelCount * _protoPlaneSize);
    return _ModelTensorWorkspace(
      inputBuffer: Float32List(_inputTensorElementCount),
      rawOutputs: {
        _detectionOutputIndex!: detections.buffer,
        _protoOutputIndex!: prototypes.buffer,
      },
      detectionOutputBuffer: detections,
      protoOutputBuffer: prototypes,
      maskLogitsBuffer: Float32List(_protoPlaneSize),
    );
  }

  /// Reads [1,39,1029] as 39 contiguous channel planes.
  /// Channels 0-3 are xywh, 4-6 are the three class scores, and 7-38 are mask coefficients.
  /// Selects the best of classes 0-2, applies the confidence threshold, rejects invalid
  /// geometry/scores, and retains coefficients separately; there is no separate objectness channel.
  List<_SegmentationCandidate> _parseSegmentationCandidates({
    required Float32List detectionOutput,
    required LetterboxTransform metadata,
  }) {
    final candidates = <_SegmentationCandidate>[];
    final collectDebugCandidates = _shouldVerboseLog;
    final topRawCandidates = collectDebugCandidates
        ? <_DebugCandidate>[]
        : null;
    final topThresholdedCandidates = collectDebugCandidates
        ? <_DebugCandidate>[]
        : null;
    var invalidBoxes = 0;

    for (var anchor = 0; anchor < _candidateCount; anchor++) {
      var bestClass = -1;
      var bestScore = double.negativeInfinity;

      for (var classIndex = 0; classIndex < _classCount; classIndex++) {
        final score = _detectionValueAt(
          detectionOutput,
          channel: 4 + classIndex,
          anchor: anchor,
        );
        if (score.isFinite && score >= 0 && score <= 1 && score > bestScore) {
          bestScore = score;
          bestClass = classIndex;
        }
      }

      if (collectDebugCandidates) {
        _pushDebugCandidate(
          topRawCandidates!,
          _DebugCandidate(
            anchor: anchor,
            classIndex: bestClass,
            confidence: bestScore,
          ),
        );
      }

      if (!_isValidClassIndex(bestClass) || bestScore <= _confidenceThreshold) {
        continue;
      }

      final cx = _detectionValueAt(detectionOutput, channel: 0, anchor: anchor);
      final cy = _detectionValueAt(detectionOutput, channel: 1, anchor: anchor);
      final width = _detectionValueAt(
        detectionOutput,
        channel: 2,
        anchor: anchor,
      );
      final height = _detectionValueAt(
        detectionOutput,
        channel: 3,
        anchor: anchor,
      );
      if (!cx.isFinite ||
          !cy.isFinite ||
          !width.isFinite ||
          !height.isFinite ||
          width <= 0 ||
          height <= 0) {
        invalidBoxes++;
        continue;
      }
      final box = _decodeModelSpaceBox(
        cx: cx,
        cy: cy,
        width: width,
        height: height,
      );
      final clippedModelBox = box.intersect(metadata.contentBounds);
      if (clippedModelBox.isEmpty) {
        invalidBoxes++;
        continue;
      }

      final maskCoefficients = Float32List(_maskChannelCount);
      for (var maskIndex = 0; maskIndex < _maskChannelCount; maskIndex++) {
        maskCoefficients[maskIndex] = _detectionValueAt(
          detectionOutput,
          channel: 4 + _classCount + maskIndex,
          anchor: anchor,
        );
      }
      if (maskCoefficients.any((value) => !value.isFinite)) continue;

      final candidate = _SegmentationCandidate(
        modelSpaceBox: clippedModelBox,
        classIndex: bestClass,
        confidence: bestScore,
        maskCoefficients: maskCoefficients,
      );
      candidates.add(candidate);
      if (collectDebugCandidates) {
        _pushDebugCandidate(
          topThresholdedCandidates!,
          _DebugCandidate(
            anchor: anchor,
            classIndex: bestClass,
            confidence: bestScore,
          ),
        );
      }
    }

    if (collectDebugCandidates) {
      debugPrint(
        'Raw candidates=$_candidateCount '
        'afterThreshold=${candidates.length} '
        'invalidBoxes=$invalidBoxes',
      );
      _logDebugCandidates(
        label: 'Top raw candidates',
        candidates: topRawCandidates!,
      );
      _logDebugCandidates(
        label: 'Top thresholded candidates',
        candidates: topThresholdedCandidates!,
      );
    }

    return candidates;
  }

  /// Converts the export's normalized center/size values into input-pixel corners.
  Rect _decodeModelSpaceBox({
    required double cx,
    required double cy,
    required double width,
    required double height,
  }) {
    final inputSize = AppConstants.modelInputSize.toDouble();
    final centerX = cx * inputSize;
    final centerY = cy * inputSize;
    final boxWidth = width * inputSize;
    final boxHeight = height * inputSize;

    return Rect.fromLTRB(
      centerX - (boxWidth / 2),
      centerY - (boxHeight / 2),
      centerX + (boxWidth / 2),
      centerY + (boxHeight / 2),
    );
  }

  /// Combines each NMS survivor's coefficients with prototypes and checks foreground support.
  /// Rejects unsupported/empty masks as a sanity filter, not a guarantee against model false positives.
  List<_SegmentationCandidate> _attachMasksAndFilterCandidates({
    required List<_SegmentationCandidate> candidates,
    required Float32List protoTensor,
    required Float32List maskLogitsBuffer,
    required LetterboxTransform metadata,
  }) {
    if (candidates.isEmpty) {
      return candidates;
    }

    final kept = <_SegmentationCandidate>[];
    var droppedByMask = 0;

    for (final candidate in candidates) {
      SegmentationPostprocessor.reconstructMask(
        coefficients: candidate.maskCoefficients,
        prototypes: protoTensor,
        logits: maskLogitsBuffer,
        modelBox: candidate.modelSpaceBox,
        modelSize: AppConstants.modelInputSize,
        width: _protoWidth,
        height: _protoHeight,
      );
      if (SegmentationPostprocessor.hasMaskSupport(
        logits: maskLogitsBuffer,
        modelBox: candidate.modelSpaceBox,
        modelSize: AppConstants.modelInputSize,
        width: _protoWidth,
        height: _protoHeight,
        threshold: AppConstants.maskLogitThreshold,
        minimumPixels: AppConstants.minimumMaskPixels,
        minimumFraction: AppConstants.minimumMaskFraction,
      )) {
        final mask = _buildDisplayMask(
          candidate: candidate,
          maskLogits: maskLogitsBuffer,
          metadata: metadata,
        );
        if (!mask.isEmpty) {
          kept.add(candidate.copyWith(visualMask: mask));
        } else {
          droppedByMask++;
        }
      } else {
        droppedByMask++;
      }
    }

    if (_shouldVerboseLog) {
      debugPrint('Mask filter kept=${kept.length} dropped=$droppedByMask');
    }

    return kept;
  }

  /// Bilinearly samples cropped prototype logits before thresholding. Sampling
  /// within the unpadded box keeps the binary grid aligned to the source image.
  SegmentationMask _buildDisplayMask({
    required _SegmentationCandidate candidate,
    required Float32List maskLogits,
    required LetterboxTransform metadata,
  }) {
    final box = candidate.modelSpaceBox;
    final normalizedBox = metadata.toNormalizedSource(box);
    final aspect =
        (normalizedBox.width * metadata.sourceWidth) /
        (normalizedBox.height * metadata.sourceHeight);
    const maxMaskSide = 72;
    const minMaskSide = 18;
    final maskWidth = (maxMaskSide * aspect).round().clamp(
      minMaskSide,
      maxMaskSide,
    );
    final maskHeight = (maxMaskSide / aspect).round().clamp(
      minMaskSide,
      maxMaskSide,
    );
    const scaleX = _protoWidth / AppConstants.modelInputSize;
    const scaleY = _protoHeight / AppConstants.modelInputSize;

    final pixels = Uint8List(maskWidth * maskHeight);
    for (var y = 0; y < maskHeight; y++) {
      final py =
          ((box.top + (y + 0.5) * box.height / maskHeight) * scaleY - 0.5)
              .clamp(0.0, _protoHeight - 1.0);
      final y0 = py.floor();
      final y1 = math.min(y0 + 1, _protoHeight - 1);
      final row0 = y0 * _protoWidth;
      final row1 = y1 * _protoWidth;
      final fy = py - y0;
      for (var x = 0; x < maskWidth; x++) {
        final px =
            ((box.left + (x + 0.5) * box.width / maskWidth) * scaleX - 0.5)
                .clamp(0.0, _protoWidth - 1.0);
        final x0 = px.floor();
        final x1 = math.min(x0 + 1, _protoWidth - 1);
        final fx = px - x0;
        final top =
            maskLogits[row0 + x0] * (1 - fx) + maskLogits[row0 + x1] * fx;
        final bottom =
            maskLogits[row1 + x0] * (1 - fx) + maskLogits[row1 + x1] * fx;
        if (top * (1 - fy) + bottom * fy > AppConstants.maskLogitThreshold) {
          pixels[y * maskWidth + x] = 1;
        }
      }
    }

    return SegmentationMask(
      bounds: normalizedBox,
      width: maskWidth,
      height: maskHeight,
      pixels: pixels,
    );
  }

  /// Resolves the two exact V8 FP32 outputs by shape regardless of output order.
  @visibleForTesting
  static ({int detection, int prototypes}) validateModelSignature({
    required List<({List<int> shape, TensorType type})> inputs,
    required List<({List<int> shape, TensorType type})> outputs,
  }) {
    if (inputs.length != 1 ||
        !listEquals(inputs.single.shape, _expectedInputShape) ||
        inputs.single.type != TensorType.float32) {
      throw StateError(
        'Expected FP32 input $_expectedInputShape, found $inputs.',
      );
    }

    final detection = outputs.indexWhere(
      (tensor) =>
          listEquals(tensor.shape, _expectedDetectionShape) &&
          tensor.type == TensorType.float32,
    );
    final prototypes = outputs.indexWhere(
      (tensor) =>
          listEquals(tensor.shape, _expectedProtoShape) &&
          tensor.type == TensorType.float32,
    );
    if (outputs.length != 2 || detection < 0 || prototypes < 0) {
      throw StateError(
        'Expected FP32 outputs $_expectedDetectionShape and $_expectedProtoShape, '
        'found $outputs.',
      );
    }
    return (detection: detection, prototypes: prototypes);
  }

  void _validateModelSignature() {
    final interpreter = _interpreter!;
    final signature = validateModelSignature(
      inputs: interpreter
          .getInputTensors()
          .map((tensor) => (shape: tensor.shape, type: tensor.type))
          .toList(),
      outputs: interpreter
          .getOutputTensors()
          .map((tensor) => (shape: tensor.shape, type: tensor.type))
          .toList(),
    );
    _detectionOutputIndex = signature.detection;
    _protoOutputIndex = signature.prototypes;
  }

  /// Prints tensor names, dimensions, and dtypes once per load in debug mode.
  void _logTensorShapes() {
    if (!kDebugMode || _interpreter == null || _didLogTensorShapes) {
      return;
    }

    _didLogTensorShapes = true;
    final inputTensor = _interpreter!.getInputTensors().first;
    debugPrint(
      'Input tensor: name=${inputTensor.name} '
      'shape=${inputTensor.shape} type=${inputTensor.type}',
    );
    for (
      var index = 0;
      index < _interpreter!.getOutputTensors().length;
      index++
    ) {
      final outputTensor = _interpreter!.getOutputTensor(index);
      debugPrint(
        'Output tensor $index: name=${outputTensor.name} '
        'shape=${outputTensor.shape} type=${outputTensor.type}',
      );
    }
  }

  /// Prints a small confidence-ranked candidate sample rather than all candidates.
  void _logDebugCandidates({
    required String label,
    required List<_DebugCandidate> candidates,
  }) {
    if (!kDebugMode || candidates.isEmpty) {
      return;
    }

    debugPrint(
      '$label: ${candidates.reversed.map(_formatDebugCandidate).join(' | ')}',
    );
  }

  /// Logs final stage/confidence/normalized-box values for pipeline inspection.
  void _logDetectionPreview({
    required List<Detection> detections,
    required String label,
  }) {
    if (!kDebugMode || detections.isEmpty) {
      return;
    }

    final preview = detections
        .take(_debugLogCount)
        .map((detection) {
          final box = detection.boundingBox;
          return '${detection.maturityClass.label} '
              '${detection.confidence.toStringAsFixed(3)} '
              'box=[${box.left.toStringAsFixed(3)},${box.top.toStringAsFixed(3)},'
              '${box.width.toStringAsFixed(3)},${box.height.toStringAsFixed(3)}]';
        })
        .join(' | ');
    debugPrint('$label: $preview');
  }

  /// Keeps only the highest-scoring debug candidates in a bounded sample.
  void _pushDebugCandidate(
    List<_DebugCandidate> bucket,
    _DebugCandidate candidate,
  ) {
    bucket.add(candidate);
    bucket.sort((a, b) => a.confidence.compareTo(b.confidence));
    if (bucket.length > _debugLogCount) {
      bucket.removeAt(0);
    }
  }

  /// Formats an anchor's score and validates its class before producing a debug label.
  String _formatDebugCandidate(_DebugCandidate candidate) {
    final className = _isValidClassIndex(candidate.classIndex)
        ? _SegmentationCandidate.maturityClasses[candidate.classIndex].label
        : 'Invalid';
    return '#${candidate.anchor} $className ${candidate.confidence.toStringAsFixed(3)}';
  }

  /// Allows only the trained class indices 0, 1, and 2, never mask channels as labels.
  bool _isValidClassIndex(int classIndex) {
    return classIndex >= 0 && classIndex < _classCount;
  }

  /// Channel-major indexing for the fixed V8 detection tensor.
  double _detectionValueAt(
    Float32List detectionOutput, {
    required int channel,
    required int anchor,
  }) => detectionOutput[channel * _candidateCount + anchor];

  /// Closes the interpreter and delegate and drops cached tensor buffers/layout metadata.
  void dispose() {
    _interpreter?.close();
    _delegate?.delete();
    _interpreter = null;
    _delegate = null;
    _detectionOutputIndex = null;
    _protoOutputIndex = null;
    _tensorWorkspace = null;
    _didLogTensorShapes = false;
  }
}

class _InterpreterRuntime {
  const _InterpreterRuntime({
    required this.interpreter,
    required this.delegate,
  });

  final Interpreter interpreter;
  final Delegate? delegate;
}

/// Reusable native-facing tensor storage; avoids large allocations every frame.
class _ModelTensorWorkspace {
  const _ModelTensorWorkspace({
    required this.inputBuffer,
    required this.rawOutputs,
    required this.detectionOutputBuffer,
    required this.protoOutputBuffer,
    required this.maskLogitsBuffer,
  });

  final Float32List inputBuffer;
  final Map<int, ByteBuffer> rawOutputs;
  final Float32List detectionOutputBuffer;
  final Float32List protoOutputBuffer;
  final Float32List maskLogitsBuffer;
}

class _MutableModelPipelineTimings {
  int preprocessMicros = 0;
  int resizeLetterboxMicros = 0;
  int tensorFillMicros = 0;
  int inferenceMicros = 0;
  int? invokeMicros;
  int? inputTensorMicros;
  int? outputTensorMicros;
  int candidateParsingMicros = 0;
  int nmsMicros = 0;
  int protoExtractionMicros = 0;
  int maskReconstructionMicros = 0;
  int postprocessMicros = 0;
  int totalMicros = 0;

  /// Freezes measured pipeline durations for reporting outside the processing routine.
  ModelPipelineTimings toImmutable() {
    return ModelPipelineTimings(
      preprocessMicros: preprocessMicros,
      resizeLetterboxMicros: resizeLetterboxMicros,
      tensorFillMicros: tensorFillMicros,
      inferenceMicros: inferenceMicros,
      invokeMicros: invokeMicros,
      inputTensorMicros: inputTensorMicros,
      outputTensorMicros: outputTensorMicros,
      candidateParsingMicros: candidateParsingMicros,
      nmsMicros: nmsMicros,
      protoExtractionMicros: protoExtractionMicros,
      maskReconstructionMicros: maskReconstructionMicros,
      postprocessMicros: postprocessMicros,
      totalMicros: totalMicros,
    );
  }
}

/// Internal prediction before conversion to UI coordinates and final mask filtering.
class _SegmentationCandidate {
  const _SegmentationCandidate({
    required this.modelSpaceBox,
    required this.classIndex,
    required this.confidence,
    required this.maskCoefficients,
    this.visualMask,
  });

  final Rect modelSpaceBox;
  final int classIndex;
  final double confidence;
  final Float32List maskCoefficients;
  final SegmentationMask? visualMask;

  /// Attaches a reconstructed display mask without changing the candidate's model prediction.
  _SegmentationCandidate copyWith({SegmentationMask? visualMask}) {
    return _SegmentationCandidate(
      modelSpaceBox: modelSpaceBox,
      classIndex: classIndex,
      confidence: confidence,
      maskCoefficients: maskCoefficients,
      visualMask: visualMask ?? this.visualMask,
    );
  }

  /// Verified from both V8's embedded metadata and its dataset YAML.
  static const maturityClasses = [
    MaturityClass.immature,
    MaturityClass.mature,
    MaturityClass.overmature,
  ];

  Detection toDetection(LetterboxTransform letterbox) => Detection(
    boundingBox: letterbox.toNormalizedSource(modelSpaceBox),
    maturityClass: maturityClasses[classIndex],
    confidence: confidence,
    mask: visualMask,
  );
}

class _DebugCandidate {
  const _DebugCandidate({
    required this.anchor,
    required this.classIndex,
    required this.confidence,
  });

  final int anchor;
  final int classIndex;
  final double confidence;
}
