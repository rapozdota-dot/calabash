import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
import 'package:calabash_maturity_detection/screens/live_camera_screen.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _PreviewController extends CameraController {
  _PreviewController()
    : super(
        const CameraDescription(
          name: 'rear',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
        ResolutionPreset.medium,
      ) {
    value = value.copyWith(
      isInitialized: true,
      previewSize: const Size(640, 480),
    );
  }

  @override
  Widget buildPreview() => const ColoredBox(color: Colors.grey);
}

class _PreviewProvider extends LiveCameraProvider {
  _PreviewProvider(this.controller);
  final CameraController controller;
  @override
  Future<void> initialize() async {}
  @override
  CameraController get cameraController => controller;
  @override
  LiveCameraStatus get status => LiveCameraStatus.cameraReady;
  @override
  bool get isCameraReady => true;
  @override
  bool get isInferenceReady => true;
  // No inference results or provider notifications: reproduce the sizing race.
  @override
  Size? get latestFrameSize => null;
}

void main() {
  testWidgets(
    'preview round-trips without inference updates or white toolbar',
    (tester) async {
      final controller = _PreviewController();
      final detector = DetectionProvider(
        modelService: ModelService(),
        imageService: ImageService(),
      );
      addTearDown(controller.dispose);
      addTearDown(detector.dispose);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        ChangeNotifierProvider<DetectionProvider>.value(
          value: detector,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: LiveCameraScreen(
              providerFactory: () => _PreviewProvider(controller),
            ),
          ),
        ),
      );
      for (final orientation in [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
      ]) {
        final landscape =
            orientation == DeviceOrientation.landscapeLeft ||
            orientation == DeviceOrientation.landscapeRight;
        tester.view.physicalSize = landscape
            ? const Size(844, 390)
            : const Size(390, 844);
        controller.value = controller.value.copyWith(
          deviceOrientation: orientation,
        );
        await tester.pump();
        final previewSize = tester.getSize(
          find.byKey(const ValueKey('live-camera-preview')),
        );
        expect(
          previewSize.aspectRatio,
          closeTo(landscape ? 640 / 480 : 480 / 640, .0001),
        );
        final toolbar = tester.widget<AppBar>(find.byType(AppBar));
        expect(toolbar.backgroundColor, Colors.black);
        expect(toolbar.foregroundColor, Colors.white);
        expect(toolbar.toolbarHeight, landscape ? 48 : 56);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
