import 'dart:io';
import 'dart:math' as math;

import 'package:calabash_maturity_detection/models/detection.dart';
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

  static const List<int> _expectedInputShape = [
    1,
    AppConstants.modelInputSize,
    AppConstants.modelInputSize,
    3,
  ];
  static const List<int> _expectedDetectionShape = [
    1,
    _detectionChannelCount,
    _candidateCount,
  ];
  static const List<int> _expectedProtoShape = [
    1,
    _protoHeight,
    _protoWidth,
    _maskChannelCount,
  ];

  ModelService({
    Uint8List? modelBuffer,
    TfliteBackendConfig backendConfig = TfliteBackendConfig.cpu2,
  }) : _modelBuffer = modelBuffer,
       _backendConfig = backendConfig;

  final Uint8List? _modelBuffer;
  final TfliteBackendConfig _backendConfig;

  Interpreter? _interpreter;
  Delegate? _delegate;
  bool _isLoadingModel = false;
  bool _didLogTensorShapes = false;
  int? _detectionOutputIndex;
  int? _protoOutputIndex;
  _ModelTensorWorkspace? _tensorWorkspace;

  bool get isModelReady => _interpreter != null;
  TfliteBackendConfig get backendConfig => _backendConfig;
  bool get _shouldVerboseLog => kDebugMode && _enableVerboseModelLogs;

  Future<void> loadModel() async {
    if (_interpreter != null || _isLoadingModel) {
      return;
    }

    _isLoadingModel = true;

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
      _interpreter = null;
      rethrow;
    } finally {
      _isLoadingModel = false;
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
    return decodedImage;
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
    final nmsCandidates = _applyClassAwareNms(candidates);
    nmsStopwatch.stop();
    timings.nmsMicros = nmsStopwatch.elapsedMicroseconds;

    var finalCandidates = nmsCandidates;
    try {
      final protoStopwatch = Stopwatch()..start();
      _copyProtoTensor(
        rawProto: workspace.protoOutputBuffer,
        channelFirstProto: workspace.protoChannelFirstBuffer,
      );
      protoStopwatch.stop();
      timings.protoExtractionMicros = protoStopwatch.elapsedMicroseconds;

      final maskStopwatch = Stopwatch()..start();
      finalCandidates = _attachMasksAndFilterCandidates(
        candidates: nmsCandidates,
        protoTensor: workspace.protoChannelFirstBuffer,
        maskLogitsBuffer: workspace.maskLogitsBuffer,
        metadata: preprocessed.metadata,
      );
      maskStopwatch.stop();
      timings.maskReconstructionMicros = maskStopwatch.elapsedMicroseconds;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Mask filtering skipped. Error: $error');
      }
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
    final flatInput = workspace.inputBuffer;
    flatInput.fillRange(0, flatInput.length, _letterboxFillValue);
    final shouldCollectRange = _shouldVerboseLog;
    var minValue = shouldCollectRange ? _letterboxFillValue : 0.0;
    var maxValue = shouldCollectRange ? _letterboxFillValue : 0.0;

    for (var y = 0; y < resizedHeight; y++) {
      final tensorRowOffset = ((y + topPad) * inputSize + leftPad) * 3;
      for (var x = 0; x < resizedWidth; x++) {
        final pixel = resized.getPixel(x, y);
        final red = pixel.r.toDouble() / 255.0;
        final green = pixel.g.toDouble() / 255.0;
        final blue = pixel.b.toDouble() / 255.0;
        final tensorIndex = tensorRowOffset + (x * 3);

        flatInput[tensorIndex] = red;
        flatInput[tensorIndex + 1] = green;
        flatInput[tensorIndex + 2] = blue;

        if (shouldCollectRange) {
          minValue = math.min(minValue, math.min(red, math.min(green, blue)));
          maxValue = math.max(maxValue, math.max(red, math.max(green, blue)));
        }
      }
    }

    tensorStopwatch.stop();
    timings.tensorFillMicros = tensorStopwatch.elapsedMicroseconds;

    if (_shouldVerboseLog) {
      debugPrint(
        'Preprocess: shape=$_expectedInputShape '
        'range=[${minValue.toStringAsFixed(4)}, ${maxValue.toStringAsFixed(4)}] '
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
      protoChannelFirstBuffer: Float32List(_maskChannelCount * _protoPlaneSize),
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
          bestScore <= AppConstants.confidenceThreshold) {
        continue;
      }

      final box = _decodeModelSpaceBox(
        cx: _detectionValueAt(detectionOutput, channel: 0, anchor: anchor),
        cy: _detectionValueAt(detectionOutput, channel: 1, anchor: anchor),
        width: _detectionValueAt(detectionOutput, channel: 2, anchor: anchor),
        height: _detectionValueAt(detectionOutput, channel: 3, anchor: anchor),
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

  List<_SegmentationCandidate> _applyClassAwareNms(
    List<_SegmentationCandidate> candidates,
  ) {
    if (candidates.length <= 1) {
      return candidates;
    }

    final sorted = [...candidates]
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = <_SegmentationCandidate>[];

    for (final candidate in sorted) {
      var shouldKeep = true;

      for (final picked in kept) {
        if (candidate.classIndex != picked.classIndex) {
          continue;
        }
        if (_iou(candidate.modelSpaceBox, picked.modelSpaceBox) >
            AppConstants.iouThreshold) {
          shouldKeep = false;
          break;
        }
      }

      if (shouldKeep) {
        kept.add(candidate);
      }
      if (kept.length >= AppConstants.maxDetections) {
        break;
      }
    }

    return kept;
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
      _writeMaskLogits(
        maskCoefficients: candidate.maskCoefficients,
        protoTensor: protoTensor,
        maskLogits: maskLogitsBuffer,
      );
      if (_hasPositiveMaskPixels(
        maskLogits: maskLogitsBuffer,
        modelSpaceBox: candidate.modelSpaceBox,
      )) {
        kept.add(
          candidate.copyWith(
            visualMask: _buildDisplayMask(
              candidate: candidate,
              maskLogits: maskLogitsBuffer,
              metadata: metadata,
            ),
          ),
        );
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
      pixels: _smoothMask(pixels, maskWidth, maskHeight),
    );
  }

  Uint8List _smoothMask(Uint8List source, int width, int height) {
    final smoothed = Uint8List(source.length);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var activeNeighbors = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            final ny = y + dy;
            if (nx < 0 || nx >= width || ny < 0 || ny >= height) {
              continue;
            }
            activeNeighbors += source[(ny * width) + nx];
          }
        }
        if (activeNeighbors >= 4) {
          smoothed[(y * width) + x] = 1;
        }
      }
    }

    return smoothed;
  }

  void _copyProtoTensor({
    required Float32List rawProto,
    required Float32List channelFirstProto,
  }) {
    var rawIndex = 0;
    for (var y = 0; y < _protoHeight; y++) {
      for (var x = 0; x < _protoWidth; x++) {
        for (var channel = 0; channel < _maskChannelCount; channel++) {
          final index = (channel * _protoPlaneSize) + (y * _protoWidth) + x;
          channelFirstProto[index] = rawProto[rawIndex++];
        }
      }
    }

    if (_shouldVerboseLog) {
      debugPrint(
        'Raw output tensors: detection=$_expectedDetectionShape '
        'proto=$_expectedProtoShape',
      );
    }
  }

  void _writeMaskLogits({
    required Float32List maskCoefficients,
    required Float32List protoTensor,
    required Float32List maskLogits,
  }) {
    maskLogits.fillRange(0, maskLogits.length, 0.0);

    for (var channel = 0; channel < _maskChannelCount; channel++) {
      final coefficient = maskCoefficients[channel];
      if (coefficient == 0.0) {
        continue;
      }

      final channelOffset = channel * _protoPlaneSize;
      for (var index = 0; index < maskLogits.length; index++) {
        maskLogits[index] += coefficient * protoTensor[channelOffset + index];
      }
    }
  }

  bool _hasPositiveMaskPixels({
    required Float32List maskLogits,
    required Rect modelSpaceBox,
  }) {
    final widthRatio = _protoWidth / AppConstants.modelInputSize;
    final heightRatio = _protoHeight / AppConstants.modelInputSize;

    final left = _clampInt(
      (modelSpaceBox.left * widthRatio).floor(),
      0,
      _protoWidth - 1,
    );
    final top = _clampInt(
      (modelSpaceBox.top * heightRatio).floor(),
      0,
      _protoHeight - 1,
    );
    final right = _clampInt(
      (modelSpaceBox.right * widthRatio).ceil(),
      1,
      _protoWidth,
    );
    final bottom = _clampInt(
      (modelSpaceBox.bottom * heightRatio).ceil(),
      1,
      _protoHeight,
    );

    if (right <= left || bottom <= top) {
      return false;
    }

    for (var y = top; y < bottom; y++) {
      final rowOffset = y * _protoWidth;
      for (var x = left; x < right; x++) {
        if (maskLogits[rowOffset + x] > AppConstants.maskLogitThreshold) {
          return true;
        }
      }
    }

    return false;
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
    if (!_sameShape(inputTensor.shape, _expectedInputShape)) {
      throw StateError(
        'Unexpected input tensor shape ${inputTensor.shape}. '
        'Expected $_expectedInputShape.',
      );
    }
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
      } else if (_sameShape(tensor.shape, _expectedProtoShape)) {
        _protoOutputIndex = index;
      }
    }

    if (_detectionOutputIndex == null || _protoOutputIndex == null) {
      throw StateError(
        'Unexpected output tensor shapes: '
        '${outputTensors.map((tensor) => tensor.shape).toList()}. '
        'Expected detection=$_expectedDetectionShape '
        'and proto=$_expectedProtoShape.',
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
