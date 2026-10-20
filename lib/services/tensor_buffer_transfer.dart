import 'dart:typed_data';

/// Copies borrowed native tensor bytes into reusable Dart-owned storage.
/// Never retain a Tensor.data view across another invoke or interpreter disposal.
class TensorBufferTransfer {
  TensorBufferTransfer._();

  static void copyExact(Uint8List source, ByteBuffer destination) {
    final target = destination.asUint8List();
    if (source.lengthInBytes != target.lengthInBytes) {
      throw StateError(
        'Tensor byte count changed: ${source.lengthInBytes} != ${target.lengthInBytes}.',
      );
    }
    target.setRange(0, target.length, source);
  }
}
