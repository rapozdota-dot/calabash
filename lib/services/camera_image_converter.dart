import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/services/camera_frame_policy.dart';
import 'package:image/image.dart' as img;

class CameraImageConverter {
  CameraImageConverter._();

  /// Adapts a camera-plugin frame into the shared plane-to-RGB conversion path.
  static img.Image toImage(
    CameraImage frame, {
    required int rotationDegrees,
    required CameraLensDirection lensDirection,
    CameraImageConversionTiming? timing,
  }) {
    return fromPlanes(
      width: frame.width,
      height: frame.height,
      format: frame.format.group,
      planes: frame.planes
          .map(
            (plane) => CameraPixelPlane(
              bytes: plane.bytes,
              bytesPerRow: plane.bytesPerRow,
              bytesPerPixel: plane.bytesPerPixel,
            ),
          )
          .toList(growable: false),
      rotationDegrees: rotationDegrees,
      lensDirection: lensDirection,
      timing: timing,
    );
  }

  /// Used by both the UI camera path and materialized isolate frames.
  static img.Image fromPlanes({
    required int width,
    required int height,
    required ImageFormatGroup format,
    required List<CameraPixelPlane> planes,
    required int rotationDegrees,
    required CameraLensDirection lensDirection,
    CameraImageConversionTiming? timing,
  }) {
    final rgbStopwatch = Stopwatch()..start();
    final rgbImage = switch (format) {
      ImageFormatGroup.yuv420 => _fromYuv420(width, height, planes),
      ImageFormatGroup.bgra8888 => _fromBgra8888(width, height, planes),
      _ => throw UnsupportedError('Unsupported camera image format: $format'),
    };
    rgbStopwatch.stop();
    timing?.rgbConversionMicros = rgbStopwatch.elapsedMicroseconds;

    final orientationStopwatch = Stopwatch()..start();
    final normalizedRotation = rotationDegrees % 360;
    var orientedImage = normalizedRotation == 0
        ? rgbImage
        : img.copyRotate(rgbImage, angle: normalizedRotation);

    if (lensDirection == CameraLensDirection.front) {
      orientedImage = img.flipHorizontal(orientedImage);
    }
    orientationStopwatch.stop();
    timing?.orientationMicros = orientationStopwatch.elapsedMicroseconds;

    return orientedImage;
  }

  /// Converts Android Y/U/V planes to RGB using each plane's actual row and pixel strides.
  /// U and V have half-resolution coordinates; padded rows must not be read as pixels.
  static img.Image _fromYuv420(
    int width,
    int height,
    List<CameraPixelPlane> planes,
  ) {
    if (planes.length < 3) {
      throw StateError('YUV420 frames must include Y, U, and V planes.');
    }

    final image = img.Image(width: width, height: height, numChannels: 3);
    final yPlane = planes[0];
    final uPlane = planes[1];
    final vPlane = planes[2];

    for (var y = 0; y < height; y++) {
      final yRowOffset = yPlane.bytesPerRow * y;
      final uRowOffset = uPlane.bytesPerRow * (y >> 1);
      final vRowOffset = vPlane.bytesPerRow * (y >> 1);

      for (var x = 0; x < width; x++) {
        final uOffset = uRowOffset + ((x >> 1) * (uPlane.bytesPerPixel ?? 1));
        final vOffset = vRowOffset + ((x >> 1) * (vPlane.bytesPerPixel ?? 1));
        final yValue = yPlane
            .bytes[yRowOffset + x * (yPlane.bytesPerPixel ?? 1)]
            .toDouble();
        final uValue = uPlane.bytes[uOffset].toDouble() - 128.0;
        final vValue = vPlane.bytes[vOffset].toDouble() - 128.0;

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

  /// Reads BGRA bytes with the native row/pixel stride and writes RGB, discarding alpha.
  static img.Image _fromBgra8888(
    int width,
    int height,
    List<CameraPixelPlane> planes,
  ) {
    if (planes.isEmpty) {
      throw StateError('BGRA frames must include one image plane.');
    }

    final plane = planes.first;
    final bytesPerPixel = CameraFramePolicy.pixelStride(
      ImageFormatGroup.bgra8888,
      plane.bytesPerPixel,
    );
    final image = img.Image(width: width, height: height, numChannels: 3);

    for (var y = 0; y < height; y++) {
      final rowOffset = y * plane.bytesPerRow;
      for (var x = 0; x < width; x++) {
        final pixelOffset = rowOffset + (x * bytesPerPixel);
        final blue = plane.bytes[pixelOffset];
        final green = plane.bytes[pixelOffset + 1];
        final red = plane.bytes[pixelOffset + 2];
        image.setPixelRgb(x, y, red, green, blue);
      }
    }

    return image;
  }

  /// Rounds converted colors into the valid 0-255 image-byte range.
  static int _clampToByte(double value) {
    return math.max(0, math.min(255, value.round()));
  }
}

class CameraImageConversionTiming {
  int rgbConversionMicros = 0;
  int orientationMicros = 0;

  /// Combines pixel conversion and orientation costs for frame diagnostics.
  int get totalMicros => rgbConversionMicros + orientationMicros;
}

class CameraPixelPlane {
  const CameraPixelPlane({
    required this.bytes,
    required this.bytesPerRow,
    this.bytesPerPixel,
  });

  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
}
