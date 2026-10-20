import 'dart:typed_data';
import 'package:calabash_maturity_detection/services/tensor_buffer_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bulk tensor transfer preserves all float32 bytes and owns its copy',
    () {
      final source = Float32List.fromList([.1, -.5, 1, 0, 114 / 255]);
      final destination = Float32List(source.length);
      TensorBufferTransfer.copyExact(
        source.buffer.asUint8List().asUnmodifiableView(),
        destination.buffer,
      );
      expect(destination, source);
      source[0] = 99;
      expect(destination[0], isNot(99));
    },
  );
  test('refuses changed tensor byte lengths', () {
    expect(
      () => TensorBufferTransfer.copyExact(Uint8List(4), Uint8List(8).buffer),
      throwsStateError,
    );
  });
  test(
    'copies a complete segmentation prototype buffer without stale bytes',
    () {
      final source = Uint8List(32 * 160 * 160 * 4)
        ..fillRange(0, 32 * 160 * 160 * 4, 123);
      final target = Uint8List(source.length)..fillRange(0, source.length, 255);
      TensorBufferTransfer.copyExact(source, target.buffer);
      expect(target, source);
      source.fillRange(0, source.length, 0);
      TensorBufferTransfer.copyExact(source, target.buffer);
      expect(target.any((b) => b != 0), isFalse);
    },
  );
}
