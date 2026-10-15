import 'dart:convert';
import 'dart:io';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/live_camera_screen.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _TestDetectionProvider extends DetectionProvider {
  _TestDetectionProvider()
    : super(modelService: ModelService(), imageService: ImageService());

  bool cleared = false;
  File? testImage;
  @override
  File? get selectedImage => testImage ?? super.selectedImage;

  @override
  void clearCurrentResult() {
    cleared = true;
    super.clearCurrentResult();
  }
}

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('result layout fits $size with large text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final folder = Directory.systemTemp.createTempSync('calabash-layout-');
      final file = File('${folder.path}/photo.png');
      file.writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a/e8AAAAASUVORK5CYII=',
        ),
      );
      final provider = _TestDetectionProvider()..testImage = file;
      await tester.pumpWidget(
        ChangeNotifierProvider<DetectionProvider>.value(
          value: provider,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const ResultScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      provider.dispose();
      file.deleteSync();
      folder.deleteSync();
    });
  }
  testWidgets('scan-again handler returns to the existing live route', (
    tester,
  ) async {
    final provider = _TestDetectionProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<DetectionProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const ResultScreen(returnToLiveCamera: true),
                  ),
                ),
                child: const Text('Existing live camera'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Existing live camera'));
    await tester.pumpAndSettle();
    // The missing-image action shares the Capture Again navigation handler.
    await tester.tap(find.text('Start New Scan'));
    await tester.pumpAndSettle();
    expect(find.byType(ResultScreen), findsNothing);
    expect(find.text('Existing live camera'), findsOneWidget);
    expect(provider.cleared, isTrue);
  });

  testWidgets('gallery result opens live camera instead of scan menu', (
    tester,
  ) async {
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      permissions,
      (call) async =>
          call.method == 'requestPermissions' ? <int, int>{1: 0} : 0,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissions,
        null,
      ),
    );
    final provider = _TestDetectionProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<DetectionProvider>.value(
        value: provider,
        child: const MaterialApp(home: ResultScreen()),
      ),
    );
    await tester.tap(find.text('Start New Scan'));
    await tester.pumpAndSettle();
    expect(find.byType(LiveCameraScreen), findsOneWidget);
    expect(find.byType(ResultScreen), findsNothing);
    expect(provider.cleared, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
