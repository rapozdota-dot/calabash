import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

/// Describes the actual resized rectangle on a square model canvas.
class LetterboxTransform {
  factory LetterboxTransform({
    required int sourceWidth,
    required int sourceHeight,
    required int inputSize,
  }) {
    if (sourceWidth <= 0 || sourceHeight <= 0 || inputSize <= 0) {
      throw ArgumentError('Image and model dimensions must be positive.');
    }
    final scale = math.min(inputSize / sourceWidth, inputSize / sourceHeight);
    final width = _roundSize(sourceWidth * scale);
    final height = _roundSize(sourceHeight * scale);
    return LetterboxTransform._(
      sourceWidth,
      sourceHeight,
      inputSize,
      width,
      height,
    );
  }

  const LetterboxTransform._(
    this.sourceWidth,
    this.sourceHeight,
    this.inputSize,
    this.resizedWidth,
    this.resizedHeight,
  );

  final int sourceWidth;
  final int sourceHeight;
  final int inputSize;
  final int resizedWidth;
  final int resizedHeight;

  int get leftPad => (inputSize - resizedWidth) ~/ 2;
  int get topPad => (inputSize - resizedHeight) ~/ 2;

  Rect get contentBounds => Rect.fromLTWH(
    leftPad.toDouble(),
    topPad.toDouble(),
    resizedWidth.toDouble(),
    resizedHeight.toDouble(),
  );

  /// Matches Python's ties-to-even rounding, with a minimum of one pixel.
  static int _roundSize(double size) {
    final floor = size.floor();
    final rounded = size - floor == 0.5 && floor.isEven ? floor : size.round();
    return math.max(1, rounded);
  }

  /// Removes padding and uses the actual rounded extent of each axis.
  Rect toNormalizedSource(Rect box) => Rect.fromLTRB(
    (box.left - leftPad) / resizedWidth,
    (box.top - topPad) / resizedHeight,
    (box.right - leftPad) / resizedWidth,
    (box.bottom - topPad) / resizedHeight,
  );

  /// Bilinear RGB resizing with pixel centers aligned to the source image.
  img.Image resizeRgb(img.Image source) {
    if (source.width != sourceWidth || source.height != sourceHeight) {
      throw ArgumentError('Source dimensions do not match the letterbox.');
    }
    final rgb =
        source.format == img.Format.uint8 &&
            source.numChannels == 3 &&
            !source.hasPalette
        ? source
        : source.convert(format: img.Format.uint8, numChannels: 3);
    if (rgb.width == resizedWidth && rgb.height == resizedHeight) return rgb;

    final result = img.Image(width: resizedWidth, height: resizedHeight);
    final stepX = sourceWidth / resizedWidth;
    final stepY = sourceHeight / resizedHeight;
    final p00 = rgb.getPixel(0, 0);
    final p10 = rgb.getPixel(0, 0);
    final p01 = rgb.getPixel(0, 0);
    final p11 = rgb.getPixel(0, 0);
    for (var y = 0; y < resizedHeight; y++) {
      final sy = ((y + 0.5) * stepY - 0.5).clamp(0.0, sourceHeight - 1.0);
      final y0 = sy.floor();
      final y1 = math.min(y0 + 1, sourceHeight - 1);
      final fy = sy - y0;
      for (var x = 0; x < resizedWidth; x++) {
        final sx = ((x + 0.5) * stepX - 0.5).clamp(0.0, sourceWidth - 1.0);
        final x0 = sx.floor();
        final x1 = math.min(x0 + 1, sourceWidth - 1);
        final fx = sx - x0;
        rgb.getPixel(x0, y0, p00);
        rgb.getPixel(x1, y0, p10);
        rgb.getPixel(x0, y1, p01);
        rgb.getPixel(x1, y1, p11);
        result.setPixelRgb(
          x,
          y,
          _bilinear(p00.r, p10.r, p01.r, p11.r, fx, fy),
          _bilinear(p00.g, p10.g, p01.g, p11.g, fx, fy),
          _bilinear(p00.b, p10.b, p01.b, p11.b, fx, fy),
        );
      }
    }
    return result;
  }

  static int _bilinear(num p00, num p10, num p01, num p11, double x, double y) {
    final top = p00 * (1 - x) + p10 * x;
    final bottom = p01 * (1 - x) + p11 * x;
    return (top * (1 - y) + bottom * y).round();
  }

  /// Packs uint8 RGB / 255 into FP32 channel planes with RGB-114 padding.
  ({double minValue, double maxValue}) writeRgbImage({
    required img.Image image,
    required Float32List buffer,
    bool collectRange = false,
  }) {
    final planeSize = inputSize * inputSize;
    if (buffer.length != planeSize * 3 ||
        image.width != resizedWidth ||
        image.height != resizedHeight) {
      throw ArgumentError('Image or input buffer does not fit the letterbox.');
    }
    const fill = 114.0 / 255.0;
    buffer.fillRange(0, buffer.length, fill);
    final left = leftPad;
    final top = topPad;
    final pixel = image.getPixel(0, 0);
    for (var y = 0; y < image.height; y++) {
      final row = (y + top) * inputSize + left;
      for (var x = 0; x < image.width; x++) {
        image.getPixel(x, y, pixel);
        final index = row + x;
        buffer[index] = pixel.r / 255.0;
        buffer[index + planeSize] = pixel.g / 255.0;
        buffer[index + 2 * planeSize] = pixel.b / 255.0;
      }
    }
    var minValue = fill;
    var maxValue = fill;
    if (collectRange) {
      minValue = buffer.reduce(math.min);
      maxValue = buffer.reduce(math.max);
    }
    return (minValue: minValue, maxValue: maxValue);
  }
}
