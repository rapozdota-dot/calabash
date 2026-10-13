import 'dart:io';
import 'dart:math' as math;

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/image_tensor_layout.dart';
import 'package:calabash_maturity_detection/services/segmentation_postprocessor.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class ModelDetectionResult {
  const ModelDetectionResult({required this.detections, required this.timings});

  final List<Detection> detections;
  final ModelPipelineTimings timings;
}

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
  });

  final int preprocessMicros;
  final int resizeLetterboxMicros;
  final int tensorFillMicros;
  final int inferenceMicros;
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

  String get cacheKey => '${kind.name}:$threads';

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

class ModelService {
  static const int _classCount = 3;
  static const int _maskChannelCount = 32;
  static const int _candidateCount = 8400;
  static const int _protoHeight = 160;
  static const int _protoWidth = 160;
  static const int _protoPlaneSize = _protoHeight * _protoWidth;
  static const int _debugLogCount = 5;
  static const int _detectionChannelCount = 4 + _classCount + _maskChannelCount;
  static const int _inputTensorElementCount =
      AppConstants.modelInputSize * AppConstants.modelInputSize * 3;
  static const double _letterboxFillValue = 114.0 / 255.0;
  static const bool _enableVerboseModelLogs = false;

  static const List<int> _expectedDetectionShape = [
    1,
    _detectionChannelCount,
    _candidateCount,
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
  ImageTensorLayout? _inputLayout;
  ImageTensorLayout? _protoLayout;
  bool _didLogTensorShapes = false;
  int? _detectionOutputIndex;
  int? _protoOutputIndex;
  _ModelTensorWorkspace? _tensorWorkspace;

  bool get isModelReady => _interpreter != null;
  TfliteBackendConfig get backendConfig => _backendConfig;
  bool get _shouldVerboseLog => kDebugMode && _enableVerboseModelLogs;

  Future<void> loadModel() {
    // Concurrent callers must wait for validation, not skip initialization.
    final pending = _modelLoading;
    if (pending != null) return pending;
    if (_interpreter != null) return Future<void>.value();
    final loading = _loadModel().whenComplete(() => _modelLoading = null);
    _modelLoading = loading;
    return loading;
  }

  Future<void> _loadModel() async {
    try {
      final runtime = await _createInterpreter();
      _interpreter = runtime.interpreter;
      _delegate = runtime.delegate;
      _validateModelSignature();
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

  Future<_InterpreterRuntime> _createInterpreter() async {
    final options = InterpreterOptions()..threads = _backendConfig.threads;
    Delegate? delegate;

    try {
      delegate = _createDelegateFor(_backendConfig, options);
      final modelBuffer = _modelBuffer;
      final interpreter = modelBuffer == null
          ? await Interpreter.fromAsset(
              AppConstants.modelAssetPath,
              options: options,
            )
          : Interpreter.fromBuffer(modelBuffer, options: options);
      options.delete();
      return _InterpreterRuntime(interpreter: interpreter, delegate: delegate);
    } catch (_) {
      options.delete();
      delegate?.delete();
      rethrow;
    }
  }

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

  Future<List<Detection>> detectFruits(File imageFile) async {
    final decodedImage = await _decodeImageFile(imageFile);
    return detectFruitsFromImage(decodedImage);
  }

  Future<List<Detection>> detectFruitsFromImage(img.Image image) async {
    final result = await detectFruitsFromImageWithMetrics(image);
    return result.detections;
  }

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

  Future<img.Image> _decodeImageFile(File imageFile) async {
    final imageBytes = await imageFile.readAsBytes();
    final decodedImage = img.decodeImage(imageBytes);
    if (decodedImage == null) {
      throw StateError('Unable to decode image for inference.');
    }
    return img.bakeOrientation(decodedImage);
  }

  ModelDetectionResult _detectFruitsFromDecodedImage(img.Image decodedImage) {
    final timings = _MutableModelPipelineTimings();
    final totalStopwatch = Stopwatch()..start();

    final workspace = _ensureTensorWorkspace();
    final preprocessed = _preprocessImage(
      decodedImage,
      workspace: workspace,
      timings: timings,
    );
    timings.inferenceMicros = _runInference(workspace);

    final postprocessStopwatch = Stopwatch()..start();
    final candidateParsingStopwatch = Stopwatch()..start();
    final candidates = _parseSegmentationCandidates(
      detectionOutput: workspace.detectionOutputBuffer,
      metadata: preprocessed.metadata,
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
      final protoStopwatch = Stopwatch()..start();
      // Current exports are already channel-first. No 3 MB copy per frame.
      final prototypes = _protoLayout == ImageTensorLayout.channelsFirst
          ? workspace.protoOutputBuffer
          : workspace.protoChannelFirstBuffer;
      if (_protoLayout != ImageTensorLayout.channelsFirst) {
        _copyProtoTensor(
          rawProto: workspace.protoOutputBuffer,
          channelFirstProto: workspace.protoChannelFirstBuffer,
        );
      }
      protoStopwatch.stop();
      timings.protoExtractionMicros = protoStopwatch.elapsedMicroseconds;

      final maskStopwatch = Stopwatch()..start();
      finalCandidates = _attachMasksAndFilterCandidates(
        candidates: nmsCandidates,
        protoTensor: prototypes,
        maskLogitsBuffer: workspace.maskLogitsBuffer,
        metadata: preprocessed.metadata,
      );
      maskStopwatch.stop();
      timings.maskReconstructionMicros = maskStopwatch.elapsedMicroseconds;
    }

    final detections = finalCandidates
        .map((candidate) => candidate.toDetection(preprocessed.metadata))
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
    totalStopwatch.stop();
    timings.postprocessMicros = postprocessStopwatch.elapsedMicroseconds;
    timings.totalMicros = totalStopwatch.elapsedMicroseconds;

    return ModelDetectionResult(
      detections: detections,
      timings: timings.toImmutable(),
    );
  }

  _PreprocessedImage _preprocessImage(
    img.Image decodedImage, {
    required _ModelTensorWorkspace workspace,
    required _MutableModelPipelineTimings timings,
  }) {
    final preprocessStopwatch = Stopwatch()..start();
    final originalWidth = decodedImage.width;
    final originalHeight = decodedImage.height;
    final inputSize = AppConstants.modelInputSize;
    final gain = math.min(
      inputSize / originalWidth,
      inputSize / originalHeight,
    );

    final resizedWidth = (originalWidth * gain).round();
    final resizedHeight = (originalHeight * gain).round();
    final padWidth = inputSize - resizedWidth;
    final padHeight = inputSize - resizedHeight;
    final leftPad = ((padWidth / 2) - 0.1).round();
    final topPad = ((padHeight / 2) - 0.1).round();
    final rightPad = inputSize - resizedWidth - leftPad;
    final bottomPad = inputSize - resizedHeight - topPad;

    final resizeStopwatch = Stopwatch()..start();
    final resized = img.copyResize(
      decodedImage,
      width: resizedWidth,
      height: resizedHeight,
      interpolation: img.Interpolation.linear,
    );
    resizeStopwatch.stop();
    timings.resizeLetterboxMicros = resizeStopwatch.elapsedMicroseconds;

    final tensorStopwatch = Stopwatch()..start();
    final range = _inputLayout!.writeRgbImage(
      image: resized,
      buffer: workspace.inputBuffer,
      inputSize: inputSize,
      leftPad: leftPad,
      topPad: topPad,
      collectRange: _shouldVerboseLog,
    );

    tensorStopwatch.stop();
    timings.tensorFillMicros = tensorStopwatch.elapsedMicroseconds;

    if (_shouldVerboseLog) {
      debugPrint(
        'Preprocess: shape=${_interpreter!.getInputTensor(0).shape} '
        'layout=$_inputLayout '
        'range=[${range.minValue.toStringAsFixed(4)}, ${range.maxValue.toStringAsFixed(4)}] '
        'gain=${gain.toStringAsFixed(4)} '
        'pad=($leftPad,$topPad,$rightPad,$bottomPad)',
      );
    }
    preprocessStopwatch.stop();
    timings.preprocessMicros = preprocessStopwatch.elapsedMicroseconds;

    return _PreprocessedImage(
      inputTensor: workspace.inputTensor,
      metadata: _PreprocessMetadata(
        originalWidth: originalWidth.toDouble(),
        originalHeight: originalHeight.toDouble(),
        gain: gain,
        leftPad: leftPad.toDouble(),
        topPad: topPad.toDouble(),
      ),
    );
  }

  int _runInference(_ModelTensorWorkspace workspace) {
    final stopwatch = Stopwatch()..start();
    _interpreter!.runForMultipleInputs([
      workspace.inputTensor,
    ], workspace.rawOutputs);
    stopwatch.stop();
    return stopwatch.elapsedMicroseconds;
  }

  _ModelTensorWorkspace _ensureTensorWorkspace() {
    final existingWorkspace = _tensorWorkspace;
    if (existingWorkspace != null) {
      return existingWorkspace;
    }

    final workspace = _createTensorWorkspace();
    _tensorWorkspace = workspace;
    return workspace;
  }

  _ModelTensorWorkspace _createTensorWorkspace() {
    final inputBuffer = Float32List(_inputTensorElementCount);
    final rawOutputs = <int, Object>{};
    final shapes = <int, List<int>>{};
    Float32List? detectionOutputBuffer;
    Float32List? protoOutputBuffer;

    for (final index in [_detectionOutputIndex!, _protoOutputIndex!]) {
      final shape = List<int>.from(_interpreter!.getOutputTensor(index).shape);
      shapes[index] = shape;
      final flatBuffer = Float32List(_elementCount(shape));
      rawOutputs[index] = flatBuffer.buffer;

      if (index == _detectionOutputIndex) {
        detectionOutputBuffer = flatBuffer;
      } else if (index == _protoOutputIndex) {
        protoOutputBuffer = flatBuffer;
      }
    }

    if (_shouldVerboseLog) {
      debugPrint(
        'Prepared output buffers: '
        '${shapes.entries.map((entry) => '${entry.key}:${entry.value}').join(', ')}',
      );
    }

    if (detectionOutputBuffer == null || protoOutputBuffer == null) {
      throw StateError(
        'Model output buffers could not be prepared for YOLOv8 segmentation.',
      );
    }

    return _ModelTensorWorkspace(
      inputBuffer: inputBuffer,
      inputTensor: inputBuffer.buffer,
      rawOutputs: rawOutputs,
      detectionOutputBuffer: detectionOutputBuffer,
      protoOutputBuffer: protoOutputBuffer,
      // NCHW exports already have contiguous prototype planes.
      protoChannelFirstBuffer: Float32List(
        _protoLayout == ImageTensorLayout.channelsLast
            ? _maskChannelCount * _protoPlaneSize
            : 0,
      ),
      maskLogitsBuffer: Float32List(_protoPlaneSize),
    );
  }

  List<_SegmentationCandidate> _parseSegmentationCandidates({
    required Float32List detectionOutput,
    required _PreprocessMetadata metadata,
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
        if (score > bestScore) {
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

      if (!_isValidClassIndex(bestClass) ||
          !bestScore.isFinite ||
          bestScore > 1 ||
          bestScore <= _confidenceThreshold) {
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
      final clippedModelBox = _clipBoxToModel(box);
      final originalBox = _scaleBoxToOriginal(
        modelSpaceBox: clippedModelBox,
        metadata: metadata,
      );

      if (clippedModelBox.width <= 0 ||
          clippedModelBox.height <= 0 ||
          originalBox.width <= 0 ||
          originalBox.height <= 0) {
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
        originalSpaceBox: originalBox,
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

  Rect _clipBoxToModel(Rect box) {
    final modelSize = AppConstants.modelInputSize.toDouble();
    return Rect.fromLTRB(
      _clamp(box.left, 0.0, modelSize),
      _clamp(box.top, 0.0, modelSize),
      _clamp(box.right, 0.0, modelSize),
      _clamp(box.bottom, 0.0, modelSize),
    );
  }

  Rect _scaleBoxToOriginal({
    required Rect modelSpaceBox,
    required _PreprocessMetadata metadata,
  }) {
    final left = (modelSpaceBox.left - metadata.leftPad) / metadata.gain;
    final top = (modelSpaceBox.top - metadata.topPad) / metadata.gain;
    final right = (modelSpaceBox.right - metadata.leftPad) / metadata.gain;
    final bottom = (modelSpaceBox.bottom - metadata.topPad) / metadata.gain;

    return Rect.fromLTRB(
      _clamp(left, 0.0, metadata.originalWidth),
      _clamp(top, 0.0, metadata.originalHeight),
      _clamp(right, 0.0, metadata.originalWidth),
      _clamp(bottom, 0.0, metadata.originalHeight),
    );
  }

  List<_SegmentationCandidate> _attachMasksAndFilterCandidates({
    required List<_SegmentationCandidate> candidates,
    required Float32List protoTensor,
    required Float32List maskLogitsBuffer,
    required _PreprocessMetadata metadata,
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
        if (mask != null && !mask.isEmpty) {
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

  SegmentationMask? _buildDisplayMask({
    required _SegmentationCandidate candidate,
    required Float32List maskLogits,
    required _PreprocessMetadata metadata,
  }) {
    final originalBox = candidate.originalSpaceBox;
    if (originalBox.width <= 0 || originalBox.height <= 0) {
      return null;
    }

    const maxMaskSide = 72;
    const minMaskSide = 18;
    final aspect = originalBox.width / originalBox.height;
    final maskWidth = aspect >= 1
        ? maxMaskSide
        : _clampInt((maxMaskSide * aspect).round(), minMaskSide, maxMaskSide);
    final maskHeight = aspect >= 1
        ? _clampInt((maxMaskSide / aspect).round(), minMaskSide, maxMaskSide)
        : maxMaskSide;

    final pixels = Uint8List(maskWidth * maskHeight);
    var activeCount = 0;

    for (var y = 0; y < maskHeight; y++) {
      final originalY =
          originalBox.top + ((y + 0.5) / maskHeight) * originalBox.height;
      final modelY = (originalY * metadata.gain) + metadata.topPad;
      final protoY = _clampInt(
        (modelY / AppConstants.modelInputSize * _protoHeight).floor(),
        0,
        _protoHeight - 1,
      );

      for (var x = 0; x < maskWidth; x++) {
        final originalX =
            originalBox.left + ((x + 0.5) / maskWidth) * originalBox.width;
        final modelX = (originalX * metadata.gain) + metadata.leftPad;
        final protoX = _clampInt(
          (modelX / AppConstants.modelInputSize * _protoWidth).floor(),
          0,
          _protoWidth - 1,
        );

        if (maskLogits[(protoY * _protoWidth) + protoX] >
            AppConstants.maskLogitThreshold) {
          pixels[(y * maskWidth) + x] = 1;
          activeCount++;
        }
      }
    }

    if (activeCount == 0) {
      return null;
    }

    return SegmentationMask(
      bounds: Rect.fromLTWH(
        (originalBox.left / metadata.originalWidth).clamp(0.0, 1.0),
        (originalBox.top / metadata.originalHeight).clamp(0.0, 1.0),
        (originalBox.width / metadata.originalWidth).clamp(0.0, 1.0),
        (originalBox.height / metadata.originalHeight).clamp(0.0, 1.0),
      ),
      width: maskWidth,
      height: maskHeight,
      pixels: SegmentationPostprocessor.smoothMask(
        pixels,
        maskWidth,
        maskHeight,
      ),
    );
  }

  void _copyProtoTensor({
    required Float32List rawProto,
    required Float32List channelFirstProto,
  }) {
    _protoLayout!.copyToChannelFirst(
      source: rawProto,
      destination: channelFirstProto,
      channels: _maskChannelCount,
      height: _protoHeight,
      width: _protoWidth,
    );

    if (_shouldVerboseLog) {
      debugPrint(
        'Raw output tensors: detection=$_expectedDetectionShape '
        'proto=${_interpreter!.getOutputTensor(_protoOutputIndex!).shape} '
        'layout=$_protoLayout',
      );
    }
  }

  void _validateModelSignature() {
    if (_interpreter == null) {
      return;
    }

    final inputTensors = _interpreter!.getInputTensors();
    if (inputTensors.length != 1) {
      throw StateError(
        'Expected 1 input tensor, found ${inputTensors.length}.',
      );
    }

    final inputTensor = inputTensors.first;
    _inputLayout = ImageTensorLayout.fromShape(
      inputTensor.shape,
      channels: 3,
      height: AppConstants.modelInputSize,
      width: AppConstants.modelInputSize,
    );
    if (inputTensor.type != TensorType.float32) {
      throw StateError(
        'Unexpected input tensor type ${inputTensor.type}. '
        'Expected ${TensorType.float32}.',
      );
    }

    final outputTensors = _interpreter!.getOutputTensors();
    if (outputTensors.length < 2) {
      throw StateError(
        'Expected 2 output tensors for YOLOv8 segmentation, '
        'found ${outputTensors.length}.',
      );
    }

    for (var index = 0; index < outputTensors.length; index++) {
      final tensor = outputTensors[index];
      if (_sameShape(tensor.shape, _expectedDetectionShape)) {
        _detectionOutputIndex = index;
      } else if (_sameShape(tensor.shape, [
            1,
            _protoHeight,
            _protoWidth,
            _maskChannelCount,
          ]) ||
          _sameShape(tensor.shape, [
            1,
            _maskChannelCount,
            _protoHeight,
            _protoWidth,
          ])) {
        _protoOutputIndex = index;
        _protoLayout = ImageTensorLayout.fromShape(
          tensor.shape,
          channels: _maskChannelCount,
          height: _protoHeight,
          width: _protoWidth,
        );
      }
    }

    if (_detectionOutputIndex == null || _protoOutputIndex == null) {
      throw StateError(
        'Unexpected output tensor shapes: '
        '${outputTensors.map((tensor) => tensor.shape).toList()}. '
        'Expected detection=$_expectedDetectionShape '
        'and proto=[1,160,160,32] or [1,32,160,160].',
      );
    }

    final detectionTensor = outputTensors[_detectionOutputIndex!];
    final protoTensor = outputTensors[_protoOutputIndex!];
    if (detectionTensor.type != TensorType.float32 ||
        protoTensor.type != TensorType.float32) {
      throw StateError(
        'Unexpected output tensor types: '
        'det=${detectionTensor.type}, proto=${protoTensor.type}.',
      );
    }
  }

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

  String _formatDebugCandidate(_DebugCandidate candidate) {
    final className = _isValidClassIndex(candidate.classIndex)
        ? _classFromIndex(candidate.classIndex).label
        : 'Invalid';
    return '#${candidate.anchor} $className ${candidate.confidence.toStringAsFixed(3)}';
  }

  bool _isValidClassIndex(int classIndex) {
    return classIndex >= 0 && classIndex < _classCount;
  }

  MaturityClass _classFromIndex(int classIndex) {
    switch (classIndex) {
      case 0:
        return MaturityClass.immature;
      case 1:
        return MaturityClass.mature;
      case 2:
        return MaturityClass.overmature;
      default:
        return MaturityClass.unknown;
    }
  }

  int _elementCount(List<int> shape) {
    return shape.fold<int>(1, (product, value) => product * value);
  }

  double _detectionValueAt(
    Float32List detectionOutput, {
    required int channel,
    required int anchor,
  }) {
    if (channel < 0 ||
        channel >= _detectionChannelCount ||
        anchor < 0 ||
        anchor >= _candidateCount) {
      return 0.0;
    }
    return detectionOutput[(channel * _candidateCount) + anchor];
  }

  bool _sameShape(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) {
        return false;
      }
    }
    return true;
  }

  double _clamp(double value, double min, double max) {
    return (value.clamp(min, max) as num).toDouble();
  }

  int _clampInt(int value, int min, int max) {
    return value.clamp(min, max);
  }

  void dispose() {
    _interpreter?.close();
    _delegate?.delete();
    _interpreter = null;
    _delegate = null;
    _detectionOutputIndex = null;
    _protoOutputIndex = null;
    _tensorWorkspace = null;
    _inputLayout = null;
    _protoLayout = null;
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

class _ModelTensorWorkspace {
  const _ModelTensorWorkspace({
    required this.inputBuffer,
    required this.inputTensor,
    required this.rawOutputs,
    required this.detectionOutputBuffer,
    required this.protoOutputBuffer,
    required this.protoChannelFirstBuffer,
    required this.maskLogitsBuffer,
  });

  final Float32List inputBuffer;
  final Object inputTensor;
  final Map<int, Object> rawOutputs;
  final Float32List detectionOutputBuffer;
  final Float32List protoOutputBuffer;
  final Float32List protoChannelFirstBuffer;
  final Float32List maskLogitsBuffer;
}

class _PreprocessedImage {
  const _PreprocessedImage({required this.inputTensor, required this.metadata});

  final Object inputTensor;
  final _PreprocessMetadata metadata;
}

class _MutableModelPipelineTimings {
  int preprocessMicros = 0;
  int resizeLetterboxMicros = 0;
  int tensorFillMicros = 0;
  int inferenceMicros = 0;
  int candidateParsingMicros = 0;
  int nmsMicros = 0;
  int protoExtractionMicros = 0;
  int maskReconstructionMicros = 0;
  int postprocessMicros = 0;
  int totalMicros = 0;

  ModelPipelineTimings toImmutable() {
    return ModelPipelineTimings(
      preprocessMicros: preprocessMicros,
      resizeLetterboxMicros: resizeLetterboxMicros,
      tensorFillMicros: tensorFillMicros,
      inferenceMicros: inferenceMicros,
      candidateParsingMicros: candidateParsingMicros,
      nmsMicros: nmsMicros,
      protoExtractionMicros: protoExtractionMicros,
      maskReconstructionMicros: maskReconstructionMicros,
      postprocessMicros: postprocessMicros,
      totalMicros: totalMicros,
    );
  }
}

class _PreprocessMetadata {
  const _PreprocessMetadata({
    required this.originalWidth,
    required this.originalHeight,
    required this.gain,
    required this.leftPad,
    required this.topPad,
  });

  final double originalWidth;
  final double originalHeight;
  final double gain;
  final double leftPad;
  final double topPad;
}

class _SegmentationCandidate {
  const _SegmentationCandidate({
    required this.modelSpaceBox,
    required this.originalSpaceBox,
    required this.classIndex,
    required this.confidence,
    required this.maskCoefficients,
    this.visualMask,
  });

  final Rect modelSpaceBox;
  final Rect originalSpaceBox;
  final int classIndex;
  final double confidence;
  final Float32List maskCoefficients;
  final SegmentationMask? visualMask;

  _SegmentationCandidate copyWith({SegmentationMask? visualMask}) {
    return _SegmentationCandidate(
      modelSpaceBox: modelSpaceBox,
      originalSpaceBox: originalSpaceBox,
      classIndex: classIndex,
      confidence: confidence,
      maskCoefficients: maskCoefficients,
      visualMask: visualMask ?? this.visualMask,
    );
  }

  Detection toDetection(_PreprocessMetadata metadata) {
    final normalizedBox = Rect.fromLTWH(
      (originalSpaceBox.left / metadata.originalWidth).clamp(0.0, 1.0),
      (originalSpaceBox.top / metadata.originalHeight).clamp(0.0, 1.0),
      (originalSpaceBox.width / metadata.originalWidth).clamp(0.0, 1.0),
      (originalSpaceBox.height / metadata.originalHeight).clamp(0.0, 1.0),
    );

    return Detection(
      boundingBox: normalizedBox,
      maturityClass: _classIndexToMaturityClass(classIndex),
      confidence: confidence,
      mask: visualMask,
    );
  }

  static MaturityClass _classIndexToMaturityClass(int classIndex) {
    switch (classIndex) {
      case 0:
        return MaturityClass.immature;
      case 1:
        return MaturityClass.mature;
      case 2:
        return MaturityClass.overmature;
      default:
        return MaturityClass.unknown;
    }
  }
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
