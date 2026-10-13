import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/services/camera_frame_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const back = CameraDescription(
    name: 'back',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );
  const front = CameraDescription(
    name: 'front',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 90,
  );

  test('selects iOS BGRA and preserves Android YUV', () {
    expect(
      CameraFramePolicy.imageFormat(TargetPlatform.iOS),
      ImageFormatGroup.bgra8888,
    );
    expect(
      CameraFramePolicy.imageFormat(TargetPlatform.android),
      ImageFormatGroup.yuv420,
    );
  });

  test(
    'does not rotate already-oriented iOS frames in any device orientation',
    () {
      for (final camera in [back, front]) {
        for (final orientation in DeviceOrientation.values) {
          expect(
            CameraFramePolicy.rotationDegrees(
              platform: TargetPlatform.iOS,
              camera: camera,
              orientation: orientation,
            ),
            0,
          );
        }
      }
    },
  );

  test('preserves Android back and front sensor rotation', () {
    final orientations = [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeRight,
    ];
    final expectedBack = [90, 0, 270, 180];
    final expectedFront = [90, 180, 270, 0];
    for (var i = 0; i < orientations.length; i++) {
      expect(
        CameraFramePolicy.rotationDegrees(
          platform: TargetPlatform.android,
          camera: back,
          orientation: orientations[i],
        ),
        expectedBack[i],
      );
      expect(
        CameraFramePolicy.rotationDegrees(
          platform: TargetPlatform.android,
          camera: front,
          orientation: orientations[i],
        ),
        expectedFront[i],
      );
    }
  });

  test(
    'uses four bytes for iOS BGRA and preserves reported Android strides',
    () {
      expect(CameraFramePolicy.pixelStride(ImageFormatGroup.bgra8888, null), 4);
      expect(CameraFramePolicy.pixelStride(ImageFormatGroup.yuv420, null), 1);
      expect(CameraFramePolicy.pixelStride(ImageFormatGroup.yuv420, 2), 2);
      expect(CameraFramePolicy.pixelStride(ImageFormatGroup.bgra8888, 8), 8);
    },
  );
}
