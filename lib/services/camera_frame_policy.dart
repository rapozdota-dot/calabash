import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// AVFoundation orients its stream buffers; Android exposes sensor orientation.
class CameraFramePolicy {
  CameraFramePolicy._();

<<<<<<< HEAD
  static ResolutionPreset liveResolution(TargetPlatform platform) =>
      ResolutionPreset.medium;

  static int liveFrameRate(
    TargetPlatform platform, {
    required int fallbackFps,
  }) => platform == TargetPlatform.android ? 15 : fallbackFps;

=======
  /// Requests BGRA buffers on iOS and YUV buffers on Android to match native formats.
>>>>>>> b4193c4035c14b52cfc422fdb83b80dab0b6627e
  static ImageFormatGroup imageFormat(TargetPlatform platform) =>
      platform == TargetPlatform.iOS
      ? ImageFormatGroup.bgra8888
      : ImageFormatGroup.yuv420;

  /// Computes Android sensor/device rotation; iOS stream buffers are already oriented.
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
