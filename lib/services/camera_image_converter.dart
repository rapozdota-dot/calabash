import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class CameraImageConverter {
  CameraImageConverter._();

  static img.Image toImage(
    CameraImage frame, {
    required int rotationDegrees,
    required CameraLensDirection lensDirection,
  }) {
    final rgbImage = switch (frame.format.group) {
      ImageFormatGroup.yuv420 => _fromYuv420(frame),
      ImageFormatGroup.bgra8888 => _fromBgra8888(frame),
      _ => throw UnsupportedError(
        'Unsupported camera image format: ${frame.format.group}',
      ),
    };

    final normalizedRotation = rotationDegrees % 360;
    var orientedImage = normalizedRotation == 0
        ? rgbImage
        : img.copyRotate(rgbImage, angle: normalizedRotation);

    if (lensDirection == CameraLensDirection.front) {
      orientedImage = img.flipHorizontal(orientedImage);
    }

    return orientedImage;
  }

  static img.Image _fromYuv420(CameraImage frame) {
    if (frame.planes.length < 3) {
      throw StateError('YUV420 frames must include Y, U, and V planes.');
    }

    final image = img.Image(
      width: frame.width,
      height: frame.height,
      numChannels: 3,
    );
    final yPlane = frame.planes[0];
    final uPlane = frame.planes[1];
    final vPlane = frame.planes[2];

    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (var y = 0; y < frame.height; y++) {
      final yRowOffset = yPlane.bytesPerRow * y;
      final uvRowOffset = uvRowStride * (y >> 1);

      for (var x = 0; x < frame.width; x++) {
        final uvOffset = uvRowOffset + ((x >> 1) * uvPixelStride);
        final yValue = yPlane.bytes[yRowOffset + x].toDouble();
        final uValue = uPlane.bytes[uvOffset].toDouble() - 128.0;
        final vValue = vPlane.bytes[uvOffset].toDouble() - 128.0;

        final red = _clampToByte(yValue + (1.402 * vValue));
        final green = _clampToByte(
          yValue - (0.344136 * uValue) - (0.714136 * vValue),
        );
        final blue = _clampToByte(yValue + (1.772 * uValue));

        image.setPixelRgb(x, y, red, green, blue);
      }
    }

    return image;
  }

  static img.Image _fromBgra8888(CameraImage frame) {
    if (frame.planes.isEmpty) {
      throw StateError('BGRA frames must include one image plane.');
    }

    final plane = frame.planes.first;
    final bytesPerPixel = plane.bytesPerPixel ?? 4;
    final image = img.Image(
      width: frame.width,
      height: frame.height,
      numChannels: 3,
    );

    for (var y = 0; y < frame.height; y++) {
      final rowOffset = y * plane.bytesPerRow;
      for (var x = 0; x < frame.width; x++) {
        final pixelOffset = rowOffset + (x * bytesPerPixel);
        final blue = plane.bytes[pixelOffset];
        final green = plane.bytes[pixelOffset + 1];
        final red = plane.bytes[pixelOffset + 2];
        image.setPixelRgb(x, y, red, green, blue);
      }
    }

    return image;
  }

  static int _clampToByte(double value) {
    return math.max(0, math.min(255, value.round()));
  }
}
