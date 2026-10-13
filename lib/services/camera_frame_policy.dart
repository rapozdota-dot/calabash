import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// AVFoundation orients its stream buffers; Android exposes sensor orientation.
class CameraFramePolicy {
  CameraFramePolicy._();

  static ImageFormatGroup imageFormat(TargetPlatform platform) =>
      platform == TargetPlatform.iOS
      ? ImageFormatGroup.bgra8888
      : ImageFormatGroup.yuv420;

  static int rotationDegrees({
    required TargetPlatform platform,
    required CameraDescription camera,
    required DeviceOrientation orientation,
  }) {
    if (platform == TargetPlatform.iOS) return 0;
    final deviceDegrees = switch (orientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    if (camera.lensDirection == CameraLensDirection.front) {
      return (camera.sensorOrientation + deviceDegrees) % 360;
    }
    return (camera.sensorOrientation - deviceDegrees + 360) % 360;
  }

  /// iOS does not report bytesPerPixel. BGRA has four bytes, not one.
  static int pixelStride(ImageFormatGroup format, int? reportedStride) =>
      reportedStride ?? (format == ImageFormatGroup.bgra8888 ? 4 : 1);
}
