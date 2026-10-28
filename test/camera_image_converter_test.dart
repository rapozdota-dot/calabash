import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    as platform;
import 'package:calabash_maturity_detection/services/camera_frame_policy.dart';
import 'package:calabash_maturity_detection/services/camera_image_converter.dart';
import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

List<int> rgb(img.Image image) => [
  for (final pixel in image) ...[
    pixel.r.toInt(),
    pixel.g.toInt(),
    pixel.b.toInt(),
  ],
];

void main() {
  test('frame transfer stopwatch remains monotonic across isolates', () async {
    final timer = Stopwatch()..start();
    final frame = LiveInferenceFrame(
      frameId: 1,
      transferTimer: timer,
      width: 1,
      height: 1,
      format: LiveInferenceImageFormat.bgra8888,
      rotationDegrees: 0,
      isFrontCamera: false,
      planes: [],
    );
    final before = timer.elapsedMicroseconds;
    final transferred = await Isolate.run(
      () => frame.transferTimer!.elapsedMicroseconds,
    );
    expect(transferred, greaterThanOrEqualTo(before));
    expect(transferred, lessThanOrEqualTo(timer.elapsedMicroseconds));
  });

  const back = CameraDescription(
    name: 'back',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );

  test('iOS BGRA survives transfer, row padding, and portrait orientation', () {
    // Two actual pixels followed by four padding bytes in each row.
    final image = CameraImage.fromPlatformInterface(
      platform.CameraImageData(
        format: const platform.CameraImageFormat(
          platform.ImageFormatGroup.bgra8888,
          raw: 1111970369,
        ),
        width: 2,
        height: 3,
        planes: [
          platform.CameraImagePlane(
            bytes: Uint8List.fromList([
              0,
              0,
              255,
              255,
              0,
              255,
              0,
              255,
              99,
              99,
              99,
              99,
              255,
              0,
              0,
              255,
              0,
              255,
              255,
              255,
              99,
              99,
              99,
              99,
              255,
              255,
              0,
              255,
              255,
              255,
              255,
              255,
              99,
              99,
              99,
              99,
            ]),
            bytesPerRow: 12,
          ),
        ],
      ),
    );
    final rotation = CameraFramePolicy.rotationDegrees(
      platform: TargetPlatform.iOS,
      camera: back,
      orientation: DeviceOrientation.portraitUp,
    );
    final frame = LiveInferenceFrame.fromCameraImage(
      frameId: 1,
      image: image,
      rotationDegrees: rotation,
      lensDirection: CameraLensDirection.back,
    );
    expect(frame.planes.single.bytesPerPixel, 4);
    final direct = CameraImageConverter.toImage(
      image,
      rotationDegrees: rotation,
      lensDirection: CameraLensDirection.back,
    );
    final worker = frame.toImage();
    expect([worker.width, worker.height], [2, 3]);
    expect(rgb(worker), [
      255,
      0,
      0,
      0,
      255,
      0,
      0,
      0,
      255,
      255,
      255,
      0,
      0,
      255,
      255,
      255,
      255,
      255,
    ]);
    expect(rgb(worker), rgb(direct));
  });

  test('Android YUV respects independent Y/U/V row and pixel strides', () {
    final image = CameraImage.fromPlatformInterface(
      platform.CameraImageData(
        format: const platform.CameraImageFormat(
          platform.ImageFormatGroup.yuv420,
          raw: 35,
        ),
        width: 4,
        height: 4,
        planes: [
          platform.CameraImagePlane(
            bytes: Uint8List.fromList([
              10,
              20,
              30,
              40,
              99,
              99,
              50,
              60,
              70,
              80,
              99,
              99,
              90,
              100,
              110,
              120,
              99,
              99,
              130,
              140,
              150,
              160,
              99,
              99,
            ]),
            bytesPerRow: 6,
            bytesPerPixel: 1,
          ),
          platform.CameraImagePlane(
            bytes: Uint8List.fromList([
              128,
              99,
              128,
              99,
              99,
              99,
              128,
              99,
              128,
              99,
              99,
              99,
            ]),
            bytesPerRow: 6,
            bytesPerPixel: 2,
          ),
          platform.CameraImagePlane(
            bytes: Uint8List.fromList([128, 128, 99, 128, 128, 99]),
            bytesPerRow: 3,
            bytesPerPixel: 1,
          ),
        ],
      ),
    );
    final frame = LiveInferenceFrame.fromCameraImage(
      frameId: 2,
      image: image,
      rotationDegrees: 0,
      lensDirection: CameraLensDirection.back,
    );
    final worker = frame.toImage();
    final direct = CameraImageConverter.toImage(
      image,
      rotationDegrees: 0,
      lensDirection: CameraLensDirection.back,
    );
    final expected = [
      for (var value = 10; value <= 160; value += 10) ...[value, value, value],
    ];
    expect(rgb(worker), expected);
    expect(rgb(direct), expected);
  });

  test('Android transferred frames still rotate and mirror correctly', () {
    final image = CameraImage.fromPlatformInterface(
      platform.CameraImageData(
        format: const platform.CameraImageFormat(
          platform.ImageFormatGroup.yuv420,
          raw: 35,
        ),
        width: 2,
        height: 2,
        planes: [
          platform.CameraImagePlane(
            bytes: Uint8List.fromList([10, 20, 30, 40]),
            bytesPerRow: 2,
            bytesPerPixel: 1,
          ),
          platform.CameraImagePlane(
            bytes: Uint8List.fromList([128]),
            bytesPerRow: 1,
            bytesPerPixel: 1,
          ),
          platform.CameraImagePlane(
            bytes: Uint8List.fromList([128]),
            bytesPerRow: 1,
            bytesPerPixel: 1,
          ),
        ],
      ),
    );
    for (final front in [false, true]) {
      final camera = CameraDescription(
        name: front ? 'front' : 'back',
        lensDirection: front
            ? CameraLensDirection.front
            : CameraLensDirection.back,
        sensorOrientation: 90,
      );
      final frame = LiveInferenceFrame.fromCameraImage(
        frameId: 3,
        image: image,
        rotationDegrees: CameraFramePolicy.rotationDegrees(
          platform: TargetPlatform.android,
          camera: camera,
          orientation: DeviceOrientation.portraitUp,
        ),
        lensDirection: camera.lensDirection,
      );
      final expected = front ? [10, 30, 20, 40] : [30, 10, 40, 20];
      expect(rgb(frame.toImage()), [
        for (final v in expected) ...[v, v, v],
      ]);
    }
  });
}
