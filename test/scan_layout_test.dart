import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/home_screen.dart';
import 'package:calabash_maturity_detection/screens/camera_screen.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(640, 360)]) {
    testWidgets('scan screens fit $size with large text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final page in [const HomeScreen(), const CameraScreen()]) {
        await tester.pumpWidget(
          ChangeNotifierProvider(
            create: (_) => DetectionProvider(
              modelService: ModelService(),
              imageService: ImageService(),
            ),
            child: MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: const TextScaler.linear(1.8),
                  disableAnimations: true,
                ),
                child: page,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text(
            page is HomeScreen ? 'Photo or Gallery' : 'Choose from Gallery',
          ),
          150,
        );
        expect(tester.takeException(), isNull);
      }
    });
  }
}
