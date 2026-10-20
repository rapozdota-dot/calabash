import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// Defines platform-specific frame settings, orientation, and pixel stride.
class CameraFramePolicy {
  CameraFramePolicy._();

  /// Keep a moderate stream resolution so live inference stays responsive.
  static ResolutionPreset liveResolution(TargetPlatform platform) =>
      ResolutionPreset.medium;

  /// Keep preview smooth; the inference queue independently retains only one frame.
  static int liveFrameRate(
    TargetPlatform platform, {
    required int fallbackFps,
  }) => fallbackFps;

  /// Requests BGRA buffers on iOS and YUV buffers on Android.
  static ImageFormatGroup imageFormat(TargetPlatform platform) =>
      platform == TargetPlatform.iOS
      ? ImageFormatGroup.bgra8888
      : ImageFormatGroup.yuv420;

  /// Android uses sensor/device rotation; iOS buffers are already oriented.
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

  /// iOS may omit bytesPerPixel; BGRA requires four bytes per pixel.
  static int pixelStride(ImageFormatGroup format, int? reportedStride) =>
      reportedStride ?? (format == ImageFormatGroup.bgra8888 ? 4 : 1);
}
