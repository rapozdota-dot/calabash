import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../integration_test/native_model_preflight.dart';

const _input = (shape: [1, 3, 640, 640], type: TensorType.float32);
const _detections = (shape: [1, 39, 8400], type: TensorType.float32);
const _prototypes = (shape: [1, 32, 160, 160], type: TensorType.float32);

Future<void> _validateInWorker(
  List<SmokeTensorMetadata> inputs,
  List<SmokeTensorMetadata> outputs,
) => Isolate.run(
  () => validateStandaloneTensorMetadata(inputs: inputs, outputs: outputs),
);

Matcher _contractFailure(String details) => isA<StateError>().having(
  (error) => error.message,
  'message',
  contains(details),
);

void main() {
  test('valid preflight results can be asserted on the test isolate', () async {
    final (input, outputs) = await Isolate.run(() {
      // The model contract permits either order for the two outputs.
      const outputs = [_prototypes, _detections];
      validateStandaloneTensorMetadata(
        inputs: const [_input],
        outputs: outputs,
      );
      for (final output in outputs) {
        final values = Float32List(Tensor.computeNumElements(output.shape));
        validateStandaloneOutput(output, values.buffer.asUint8List());
      }
      return (_input, outputs);
    });

    expect(input.shape, [1, 3, 640, 640]);
    expect(input.type, TensorType.float32);
    expect(outputs.map((output) => output.shape), [
      [1, 32, 160, 160],
      [1, 39, 8400],
    ]);
    expect(
      outputs.map((output) => output.type),
      everyElement(TensorType.float32),
    );
  });

  test('input metadata failures propagate expected and actual values', () async {
    const outputs = [_detections, _prototypes];
    await expectLater(
      _validateInWorker(const [], outputs),
      throwsA(_contractFailure('Input tensor count: expected 1, got 0.')),
    );
    await expectLater(
      _validateInWorker(const [
        (shape: [1, 640, 640, 3], type: TensorType.float32),
      ], outputs),
      throwsA(
        _contractFailure(
          'Input tensor shape: expected [1, 3, 640, 640], got [1, 640, 640, 3].',
        ),
      ),
    );
    await expectLater(
      _validateInWorker(const [
        (shape: [1, 3, 640, 640], type: TensorType.uint8),
      ], outputs),
      throwsA(
        _contractFailure('Input tensor type: expected float32, got uint8.'),
      ),
    );
  });

  test(
    'output metadata failures propagate expected and actual values',
    () async {
      await expectLater(
        _validateInWorker(const [_input], const [_detections, _detections]),
        throwsA(
          _contractFailure(
            'expected [[1, 39, 8400], [1, 32, 160, 160]] in any order, '
            'got [[1, 39, 8400], [1, 39, 8400]]',
          ),
        ),
      );
      await expectLater(
        _validateInWorker(
          const [_input],
          const [
            _detections,
            (shape: [1, 32, 160, 160], type: TensorType.int8),
          ],
        ),
        throwsA(
          _contractFailure(
            'Output tensor [1, 32, 160, 160] type: expected float32, got int8.',
          ),
        ),
      );
    },
  );

  test('output validation rejects truncated, nonfinite and invalid scores', () {
    expect(
      () => validateStandaloneOutput(_detections, Uint8List(4)),
      throwsA(_contractFailure('byte length: expected 1310400, got 4.')),
    );
    final prototypes = Float32List(32 * 160 * 160)..[7] = double.nan;
    expect(
      () => validateStandaloneOutput(
        _prototypes,
        prototypes.buffer.asUint8List(),
      ),
      throwsA(_contractFailure('element 7: expected a finite float, got NaN.')),
    );
    final detections = Float32List(39 * 8400)..[4 * 8400 + 5] = 1.25;
    expect(
      () => validateStandaloneOutput(
        _detections,
        detections.buffer.asUint8List(),
      ),
      throwsA(
        _contractFailure(
          'class score at channel 4, anchor 5: expected a value in [0, 1], got 1.25.',
        ),
      ),
    );
  });
}
