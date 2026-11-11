import 'dart:isolate';
import 'dart:typed_data';

import 'package:calabash_maturity_detection/integration_test/smoke_stage_runner.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:tflite_flutter/tflite_flutter.dart';

typedef SmokeTensorMetadata = ({List<int> shape, TensorType type});

Future<void> verifyNativeModel(TransferableTypedData model) =>
    Isolate.run(() => _runNativePreflight(model));

Future<void> _runNativePreflight(TransferableTypedData model) async {
  final stages = SmokeStageRunner();
  final cleanup = SmokeCleanupStack(stages);
  await runWithSmokeCleanup<void>(
    runner: stages,
    cleanup: cleanup,
    operation: () async {
      final interpreter = stages.runSync(
        'TFLite interpreter creation and tensor allocation',
        () {
          final options = InterpreterOptions()..threads = 2;
          try {
            // tflite_flutter allocates tensors in the interpreter constructor.
            final interpreter = Interpreter.fromBuffer(
              model.materialize().asUint8List(),
              options: options,
            );
            cleanup.add('direct interpreter', interpreter.close);
            return interpreter;
          } finally {
            options.delete();
          }
        },
      );

      final input = stages.runSync('Standalone YOLO tensor metadata', () {
        final inputs = interpreter.getInputTensors();
        validateStandaloneTensorMetadata(
          inputs: inputs.map(_tensorMetadata).toList(),
          outputs: interpreter.getOutputTensors().map(_tensorMetadata).toList(),
        );
        return inputs.single;
      });

      stages.runSync('Standalone YOLO inference', () {
        final pixels = Float32List(input.numElements())
          ..fillRange(0, input.numElements(), 114 / 255);
        input.data = pixels.buffer.asUint8List();
        interpreter.invoke();
      });

      stages.runSync('Segmentation output validation', () {
        for (final output in interpreter.getOutputTensors()) {
          validateStandaloneOutput(_tensorMetadata(output), output.data);
        }
      });
    },
  );
}

SmokeTensorMetadata _tensorMetadata(Tensor tensor) =>
    (shape: tensor.shape, type: tensor.type);

// A spawned isolate has no active Flutter test zone. Throw runtime errors so
// Isolate.run can deliver the original contract failure to the test isolate.
void validateStandaloneTensorMetadata({
  required List<SmokeTensorMetadata> inputs,
  required List<SmokeTensorMetadata> outputs,
}) {
  const inputSize = AppConstants.modelInputSize;
  const inputShape = [1, 3, inputSize, inputSize];
  const outputShapes = [
    [1, 39, 8400],
    [1, 32, 160, 160],
  ];

  if (inputs.length != 1) {
    throw StateError('Input tensor count: expected 1, got ${inputs.length}.');
  }
  final input = inputs.single;
  if (!listEquals(input.shape, inputShape)) {
    throw StateError(
      'Input tensor shape: expected $inputShape, got ${input.shape}.',
    );
  }
  if (input.type != TensorType.float32) {
    throw StateError(
      'Input tensor type: expected ${TensorType.float32}, got ${input.type}.',
    );
  }

  if (outputs.length != outputShapes.length ||
      !outputShapes.every(
        (expected) =>
            outputs.any((output) => listEquals(output.shape, expected)),
      )) {
    throw StateError(
      'Output tensor shapes: expected $outputShapes in any order, '
      'got ${outputs.map((output) => output.shape).toList()}.',
    );
  }
  for (final output in outputs) {
    if (output.type != TensorType.float32) {
      throw StateError(
        'Output tensor ${output.shape} type: expected ${TensorType.float32}, '
        'got ${output.type}.',
      );
    }
  }
}

void validateStandaloneOutput(SmokeTensorMetadata output, Uint8List bytes) {
  final elementCount = Tensor.computeNumElements(output.shape);
  final expectedBytes = elementCount * Float32List.bytesPerElement;
  if (bytes.lengthInBytes != expectedBytes) {
    throw StateError(
      'Output tensor ${output.shape} byte length: expected $expectedBytes, '
      'got ${bytes.lengthInBytes}.',
    );
  }
  final values = bytes.buffer.asFloat32List(bytes.offsetInBytes, elementCount);
  for (var index = 0; index < values.length; index++) {
    final value = values[index];
    if (!value.isFinite) {
      throw StateError(
        'Output tensor ${output.shape} element $index: expected a finite '
        'float, got $value.',
      );
    }
  }
  if (output.shape[1] == 39) {
    // The detection tensor stores 4 box channels followed by 3 class scores
    // per anchor and 32 mask coefficients.
    final anchors = output.shape[2];
    for (var index = 4 * anchors; index < 7 * anchors; index++) {
      final score = values[index];
      if (score < 0 || score > 1) {
        throw StateError(
          'Output tensor ${output.shape} class score at channel '
          '${index ~/ anchors}, anchor ${index % anchors}: '
          'expected a value in [0, 1], got $score.',
        );
      }
    }
  }
}
