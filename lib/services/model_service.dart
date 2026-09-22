import 'dart:io';
import 'dart:math' as math;

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class ModelService {
  static const int _classCount = 3;
  static const int _maskChannelCount = 32;
  static const int _candidateCount = 8400;
  static const int _protoHeight = 160;
  static const int _protoWidth = 160;
  static const int _debugLogCount = 5;
  static const int _detectionChannelCount = 4 + _classCount + _maskChannelCount;

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

  Interpreter? _interpreter;
  bool _isLoadingModel = false;
  bool _didLogTensorShapes = false;
  int? _detectionOutputIndex;
  int? _protoOutputIndex;

  bool get isModelReady => _interpreter != null;

  Future<void> loadModel() async {
    if (_interpreter != null || _isLoadingModel) {
      return;
    }

    _isLoadingModel = true;

    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        AppConstants.modelAssetPath,
        options: options,
      );
      _validateModelSignature();
      _logTensorShapes();
      debugPrint('TFLite segmentation model loaded successfully.');
    } catch (error) {
      debugPrint('Model loading failed. Error: $error');
      _interpreter = null;
      rethrow;
    } finally {
      _isLoadingModel = false;
    }
  }

  Future<List<Detection>> detectFruits(File imageFile) async {
    final decodedImage = await _decodeImageFile(imageFile);
    return detectFruitsFromImage(decodedImage);
  }

  Future<List<Detection>> detectFruitsFromImage(img.Image image) async {
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

  List<Detection> _detectFruitsFromDecodedImage(img.Image decodedImage) {
    final preprocessed = _preprocessImage(decodedImage);
    final outputs = _prepareOutputBuffers();
    _interpreter!.runForMultipleInputs([
      preprocessed.inputTensor,
    ], outputs.rawOutputs);

    final detectionChannels = _extractDetectionChannels(
      outputs.rawOutputs[_detectionOutputIndex]!,
    );
    final candidates = _parseSegmentationCandidates(
      detectionChannels: detectionChannels,
      metadata: preprocessed.metadata,
    );
    final nmsCandidates = _applyClassAwareNms(candidates);

    var finalCandidates = nmsCandidates;
    try {
      final protoTensor = _extractProtoTensor(
        outputs.rawOutputs[_protoOutputIndex]!,
      );
      finalCandidates = _attachMasksAndFilterCandidates(
        candidates: nmsCandidates,
        protoTensor: protoTensor,
        metadata: preprocessed.metadata,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Mask filtering skipped. Error: $error');
      }
    }

    final detections = finalCandidates
        .map((candidate) => candidate.toDetection(preprocessed.metadata))
        .toList(growable: false);

    if (kDebugMode) {
      debugPrint(
        'Postprocess summary: parsed=${candidates.length} '
        'afterNms=${nmsCandidates.length} final=${detections.length}',
      );
      _logDetectionPreview(
        detections: detections,
        label: 'Top detections after NMS/mask filter',
      );
    }

    return detections;
  }

  _PreprocessedImage _preprocessImage(img.Image decodedImage) {
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

    final resized = img.copyResize(
      decodedImage,
      width: resizedWidth,
      height: resizedHeight,
      interpolation: img.Interpolation.linear,
    );

    final canvas = img.Image(
      width: inputSize,
      height: inputSize,
      numChannels: 3,
    );
    img.fill(canvas, color: img.ColorRgb8(114, 114, 114));
    img.compositeImage(canvas, resized, dstX: leftPad, dstY: topPad);

    final flatInput = Float32List(inputSize * inputSize * 3);
    var tensorIndex = 0;
    var minValue = double.infinity;
    var maxValue = double.negativeInfinity;

    for (var y = 0; y < inputSize; y++) {
      for (var x = 0; x < inputSize; x++) {
        final pixel = canvas.getPixel(x, y);
        final red = pixel.r.toDouble() / 255.0;
        final green = pixel.g.toDouble() / 255.0;
        final blue = pixel.b.toDouble() / 255.0;

        flatInput[tensorIndex++] = red;
        flatInput[tensorIndex++] = green;
        flatInput[tensorIndex++] = blue;

        minValue = math.min(minValue, math.min(red, math.min(green, blue)));
        maxValue = math.max(maxValue, math.max(red, math.max(green, blue)));
      }
    }

    final inputTensor = flatInput.reshape<double>(_expectedInputShape);

    if (kDebugMode) {
      debugPrint(
        'Preprocess: shape=$_expectedInputShape '
        'range=[${minValue.toStringAsFixed(4)}, ${maxValue.toStringAsFixed(4)}] '
        'gain=${gain.toStringAsFixed(4)} '
        'pad=($leftPad,$topPad,$rightPad,$bottomPad)',
      );
    }

    return _PreprocessedImage(
      inputTensor: inputTensor,
      metadata: _PreprocessMetadata(
        originalWidth: originalWidth.toDouble(),
        originalHeight: originalHeight.toDouble(),
        gain: gain,
        leftPad: leftPad.toDouble(),
        topPad: topPad.toDouble(),
      ),
    );
  }

  _PreparedOutputs _prepareOutputBuffers() {
    final rawOutputs = <int, Object>{};
    final shapes = <int, List<int>>{};

    for (final index in [_detectionOutputIndex!, _protoOutputIndex!]) {
      final shape = List<int>.from(_interpreter!.getOutputTensor(index).shape);
      shapes[index] = shape;
      rawOutputs[index] = _createTensorBuffer(shape);
    }

    if (kDebugMode) {
      debugPrint(
        'Prepared output buffers: '
        '${shapes.entries.map((entry) => '${entry.key}:${entry.value}').join(', ')}',
      );
    }

    return _PreparedOutputs(rawOutputs: rawOutputs, shapes: shapes);
  }

  Object _createTensorBuffer(List<int> shape) {
    final flatBuffer = Float32List(_elementCount(shape));
    return flatBuffer.reshape<double>(shape);
  }

  List<List<dynamic>> _extractDetectionChannels(Object rawDetection) {
    final detectionBatch = _asList(rawDetection, 'Detection tensor');
    if (detectionBatch.length != 1) {
      throw StateError(
        'Detection tensor batch mismatch: ${detectionBatch.length}',
      );
    }

    final channels = _asList(detectionBatch.first, 'Detection tensor channels');
    if (channels.length != _detectionChannelCount) {
      throw StateError(
        'Detection tensor channels mismatch: ${channels.length} '
        'expected $_detectionChannelCount',
      );
    }

    return List<List<dynamic>>.generate(_detectionChannelCount, (index) {
      final values = _asList(channels[index], 'Detection channel $index');
      if (values.length != _candidateCount) {
        throw StateError(
          'Detection channel $index length mismatch: ${values.length} '
          'expected $_candidateCount',
        );
      }
      return values;
    }, growable: false);
  }

  List<_SegmentationCandidate> _parseSegmentationCandidates({
    required List<List<dynamic>> detectionChannels,
    required _PreprocessMetadata metadata,
  }) {
    final candidates = <_SegmentationCandidate>[];
    final topRawCandidates = <_DebugCandidate>[];
    final topThresholdedCandidates = <_DebugCandidate>[];
    var invalidBoxes = 0;

    for (var anchor = 0; anchor < _candidateCount; anchor++) {
      var bestClass = -1;
      var bestScore = double.negativeInfinity;

      for (var classIndex = 0; classIndex < _classCount; classIndex++) {
        final score = _valueAt(detectionChannels[4 + classIndex], anchor);
        if (score > bestScore) {
          bestScore = score;
          bestClass = classIndex;
        }
      }

      _pushDebugCandidate(
        topRawCandidates,
        _DebugCandidate(
          anchor: anchor,
          classIndex: bestClass,
          confidence: bestScore,
        ),
      );

      if (!_isValidClassIndex(bestClass) ||
          bestScore <= AppConstants.confidenceThreshold) {
        continue;
      }

      final box = _decodeModelSpaceBox(
        cx: _valueAt(detectionChannels[0], anchor),
        cy: _valueAt(detectionChannels[1], anchor),
        width: _valueAt(detectionChannels[2], anchor),
        height: _valueAt(detectionChannels[3], anchor),
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
        maskCoefficients[maskIndex] = _valueAt(
          detectionChannels[4 + _classCount + maskIndex],
          anchor,
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
      _pushDebugCandidate(
        topThresholdedCandidates,
        _DebugCandidate(
          anchor: anchor,
          classIndex: bestClass,
          confidence: bestScore,
        ),
      );
    }

    if (kDebugMode) {
      debugPrint(
        'Raw candidates=$_candidateCount '
        'afterThreshold=${candidates.length} '
        'invalidBoxes=$invalidBoxes',
      );
      _logDebugCandidates(
        label: 'Top raw candidates',
        candidates: topRawCandidates,
      );
      _logDebugCandidates(
        label: 'Top thresholded candidates',
        candidates: topThresholdedCandidates,
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
    required _PreprocessMetadata metadata,
  }) {
    if (candidates.isEmpty) {
      return candidates;
    }

    final kept = <_SegmentationCandidate>[];
    var droppedByMask = 0;

    for (final candidate in candidates) {
      final maskLogits = _decodeMaskLogits(
        maskCoefficients: candidate.maskCoefficients,
        protoTensor: protoTensor,
      );
      if (_hasPositiveMaskPixels(
        maskLogits: maskLogits,
        modelSpaceBox: candidate.modelSpaceBox,
      )) {
        kept.add(
          candidate.copyWith(
            visualMask: _buildDisplayMask(
              candidate: candidate,
              maskLogits: maskLogits,
              metadata: metadata,
            ),
          ),
        );
      } else {
        droppedByMask++;
      }
    }

    if (kDebugMode) {
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

  Float32List _extractProtoTensor(Object rawProto) {
    final protoBatch = _asList(rawProto, 'Prototype tensor');
    if (protoBatch.length != 1) {
      throw StateError('Prototype tensor batch mismatch: ${protoBatch.length}');
    }

    final rows = _asList(protoBatch.first, 'Prototype rows');
    if (rows.length != _protoHeight) {
      throw StateError(
        'Prototype tensor height mismatch: ${rows.length} expected $_protoHeight',
      );
    }

    final protoTensor = Float32List(
      _maskChannelCount * _protoHeight * _protoWidth,
    );
    for (var y = 0; y < _protoHeight; y++) {
      final row = _asList(rows[y], 'Prototype row $y');
      if (row.length != _protoWidth) {
        throw StateError(
          'Prototype tensor width mismatch at row $y: ${row.length} '
          'expected $_protoWidth',
        );
      }

      for (var x = 0; x < _protoWidth; x++) {
        final channels = _asList(row[x], 'Prototype pixel ($x,$y)');
        if (channels.length != _maskChannelCount) {
          throw StateError(
            'Prototype channel mismatch at ($x,$y): ${channels.length} '
            'expected $_maskChannelCount',
          );
        }

        for (var channel = 0; channel < _maskChannelCount; channel++) {
          final index =
              (channel * _protoHeight * _protoWidth) + (y * _protoWidth) + x;
          protoTensor[index] = _toDouble(channels[channel]);
        }
      }
    }

    if (kDebugMode) {
      debugPrint(
        'Raw output tensors: detection=$_expectedDetectionShape '
        'proto=$_expectedProtoShape',
      );
    }

    return protoTensor;
  }

  Float32List _decodeMaskLogits({
    required Float32List maskCoefficients,
    required Float32List protoTensor,
  }) {
    final maskLogits = Float32List(_protoHeight * _protoWidth);

    for (var channel = 0; channel < _maskChannelCount; channel++) {
      final coefficient = maskCoefficients[channel];
      if (coefficient == 0.0) {
        continue;
      }

      final channelOffset = channel * _protoHeight * _protoWidth;
      for (var index = 0; index < maskLogits.length; index++) {
        maskLogits[index] += coefficient * protoTensor[channelOffset + index];
      }
    }

    return maskLogits;
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

  List<dynamic> _asList(Object? value, String label) {
    if (value is List<dynamic>) {
      return value;
    }
    throw StateError('$label is not a List. Actual type: ${value.runtimeType}');
  }

  int _elementCount(List<int> shape) {
    return shape.fold<int>(1, (product, value) => product * value);
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

  double _valueAt(List<dynamic> values, int index) {
    if (index < 0 || index >= values.length) {
      return 0.0;
    }
    return _toDouble(values[index]);
  }

  double _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString()) ?? 0.0;
  }

  double _clamp(double value, double min, double max) {
    return (value.clamp(min, max) as num).toDouble();
  }

  int _clampInt(int value, int min, int max) {
    return value.clamp(min, max);
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _detectionOutputIndex = null;
    _protoOutputIndex = null;
  }
}

class _PreprocessedImage {
  const _PreprocessedImage({required this.inputTensor, required this.metadata});

  final Object inputTensor;
  final _PreprocessMetadata metadata;
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

class _PreparedOutputs {
  const _PreparedOutputs({required this.rawOutputs, required this.shapes});

  final Map<int, Object> rawOutputs;
  final Map<int, List<int>> shapes;
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
