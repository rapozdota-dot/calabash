import 'dart:typed_data';

import 'package:calabash_maturity_detection/services/image_tensor_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('accepts current NCHW and earlier NHWC model signatures', () {
    for (final channels in [3, 32]) {
      final size = channels == 3 ? 640 : 160;
      expect(
        ImageTensorLayout.fromShape(
          [1, channels, size, size],
          channels: channels,
          height: size,
          width: size,
        ),
        ImageTensorLayout.channelsFirst,
      );
      expect(
        ImageTensorLayout.fromShape(
          [1, size, size, channels],
          channels: channels,
          height: size,
          width: size,
        ),
        ImageTensorLayout.channelsLast,
      );
    }
  });

  test('rejects wrong resolution, channel count, and batch size', () {
    for (final shape in [
      [1, 3, 320, 320],
      [1, 4, 640, 640],
      [2, 3, 640, 640],
      [640, 640, 3],
    ]) {
      expect(
        () => ImageTensorLayout.fromShape(
          shape,
          channels: 3,
          height: 640,
          width: 640,
        ),
        throwsStateError,
      );
    }
  });

  test('packs RGB into separate planes or interleaved pixels with padding', () {
    final image = img.Image(width: 2, height: 1)
      ..setPixelRgb(0, 0, 255, 0, 0)
      ..setPixelRgb(1, 0, 0, 128, 255);
    const fill = 114.0 / 255.0;
    final planar = Float32List(12);
    final interleaved = Float32List(12);
    for (final layout in ImageTensorLayout.values) {
      final range = layout.writeRgbImage(
        image: image,
        buffer: layout == ImageTensorLayout.channelsFirst
            ? planar
            : interleaved,
        inputSize: 2,
        leftPad: 0,
        topPad: 1,
        collectRange: true,
      );
      expect(range.minValue, 0);
      expect(range.maxValue, 1);
    }
    final expectedPlanar = [
      fill,
      fill,
      1.0,
      0.0,
      fill,
      fill,
      0.0,
      128 / 255,
      fill,
      fill,
      0.0,
      1.0,
    ];
    final expectedInterleaved = [
      fill,
      fill,
      fill,
      fill,
      fill,
      fill,
      1.0,
      0.0,
      0.0,
      0.0,
      128 / 255,
      1.0,
    ];
    for (var i = 0; i < 12; i++) {
      expect(planar[i], closeTo(expectedPlanar[i], 1e-7));
      expect(interleaved[i], closeTo(expectedInterleaved[i], 1e-7));
    }
  });

  test('preserves prototype planes for either exporter layout', () {
    final expected = Float32List.fromList([1, 2, 3, 4, 10, 20, 30, 40]);
    for (final layout in ImageTensorLayout.values) {
      final result = Float32List(8);
      layout.copyToChannelFirst(
        source: layout == ImageTensorLayout.channelsFirst
            ? expected
            : Float32List.fromList([1, 10, 2, 20, 3, 30, 4, 40]),
        destination: result,
        channels: 2,
        height: 2,
        width: 2,
      );
      expect(result, orderedEquals(expected));
      // One coefficient per prototype channel, as used by mask reconstruction.
      expect(List.generate(4, (i) => 2 * result[i] - result[4 + i]), [
        -8,
        -16,
        -24,
        -32,
      ]);
    }
  });

  test('rejects undersized buffers rather than silently corrupting input', () {
    expect(
      () => ImageTensorLayout.channelsFirst.writeRgbImage(
        image: img.Image(width: 1, height: 1),
        buffer: Float32List(3),
        inputSize: 2,
        leftPad: 0,
        topPad: 0,
      ),
      throwsArgumentError,
    );
  });
}
