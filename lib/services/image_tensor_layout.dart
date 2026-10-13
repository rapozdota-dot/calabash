import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Exporters can preserve NCHW or convert to NHWC. Read the actual signature.
enum ImageTensorLayout {
  channelsFirst,
  channelsLast;

  /// Accepts only the expected NCHW or NHWC signature; never guesses layout from model names.
  static ImageTensorLayout fromShape(
    List<int> shape, {
    required int channels,
    required int height,
    required int width,
  }) {
    if (_matches(shape, [1, channels, height, width])) {
      return channelsFirst;
    }
    if (_matches(shape, [1, height, width, channels])) {
      return channelsLast;
    }
    throw StateError(
      'Unsupported image tensor $shape. Expected '
      '[1, $channels, $height, $width] or [1, $height, $width, $channels].',
    );
  }

  /// Packs RGB / 255 into the reusable input buffer, including letterbox fill.
  ///
  /// Produces float32 values in 0-1, not BGR or -1 to 1 normalization.
  /// NCHW uses index = channel * planeSize + pixel; NHWC uses pixel * 3 + channel.
  /// Optional range collection is for diagnostics and is disabled on normal scans.
  ({double minValue, double maxValue}) writeRgbImage({
    required img.Image image,
    required Float32List buffer,
    required int inputSize,
    required int leftPad,
    required int topPad,
    bool collectRange = false,
  }) {
    final planeSize = inputSize * inputSize;
    if (buffer.length != planeSize * 3 ||
        leftPad < 0 ||
        topPad < 0 ||
        leftPad + image.width > inputSize ||
        topPad + image.height > inputSize) {
      throw ArgumentError('Image or input buffer does not fit the letterbox.');
    }
    const fill = 114.0 / 255.0;
    buffer.fillRange(0, buffer.length, fill);
    final pixelStride = this == channelsFirst ? 1 : 3;
    final channelStride = this == channelsFirst ? planeSize : 1;
    var minValue = fill;
    var maxValue = fill;
    for (var y = 0; y < image.height; y++) {
      final rowOffset = ((y + topPad) * inputSize + leftPad) * pixelStride;
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final r = pixel.r.toDouble() / 255.0;
        final g = pixel.g.toDouble() / 255.0;
        final b = pixel.b.toDouble() / 255.0;
        final index = rowOffset + x * pixelStride;
        buffer[index] = r;
        buffer[index + channelStride] = g;
        buffer[index + 2 * channelStride] = b;
        if (collectRange) {
          for (final value in [r, g, b]) {
            if (value < minValue) minValue = value;
            if (value > maxValue) maxValue = value;
          }
        }
      }
    }
    return (minValue: minValue, maxValue: maxValue);
  }

  /// Mask reconstruction uses contiguous channel planes internally.
  /// Converts NHWC pixel-interleaved values into NCHW planes without changing values.
  void copyToChannelFirst({
    required Float32List source,
    required Float32List destination,
    required int channels,
    required int height,
    required int width,
  }) {
    final planeSize = height * width;
    if (source.length != channels * planeSize ||
        destination.length != source.length) {
      throw ArgumentError('Prototype buffer size does not match its tensor.');
    }
    if (this == channelsFirst) {
      destination.setAll(0, source);
      return;
    }
    for (var pixel = 0; pixel < planeSize; pixel++) {
      for (var channel = 0; channel < channels; channel++) {
        destination[channel * planeSize + pixel] =
            source[pixel * channels + channel];
      }
    }
  }

  /// Checks every dimension so unsupported tensor layouts fail explicitly.
  static bool _matches(List<int> actual, List<int> expected) {
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }
}
