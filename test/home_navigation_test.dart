import 'dart:async';
import 'dart:io';

import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/home_screen.dart';
import 'package:calabash_maturity_detection/screens/live_camera_screen.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'detection_provider_test.dart' show TestImageService, TestModelService;

void main() {
  Future<void> showHome(WidgetTester tester, DetectionProvider provider) =>
      tester.pumpWidget(
        ChangeNotifierProvider<DetectionProvider>.value(
          value: provider,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );

  testWidgets(
    'gallery opens directly, disables duplicate taps, and shows results',
    (tester) async {
      final picked = Completer<File?>();
      final picker = TestImageService(() => picked.future);
      final model = TestModelService();
      final provider = DetectionProvider(
        modelService: model,
        imageService: picker,
      );
      addTearDown(provider.dispose);
      await showHome(tester, provider);
      await tester.pumpAndSettle();
      expect(find.text('Photo or Gallery'), findsNothing);
      await tester.ensureVisible(find.text('Choose from Gallery'));
      await tester.tap(find.text('Choose from Gallery'));
      await tester.pump();
      expect(picker.source, ImageSource.gallery);
      expect(picker.calls, 1);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Choose from Gallery'),
            )
            .onPressed,
        isNull,
      );
      picked.complete(File('test-missing-image.jpg'));
      await tester.pump();
      // File I/O must complete outside the widget test's fake clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ResultScreen), findsOneWidget);
      expect(model.calls, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelling the gallery stays on Home without an error', (
    tester,
  ) async {
    final provider = DetectionProvider(
      modelService: TestModelService(),
      imageService: TestImageService(() async => null),
    );
    addTearDown(provider.dispose);
    await showHome(tester, provider);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Choose from Gallery'));
    await tester.tap(find.text('Choose from Gallery'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ResultScreen), findsNothing);
    expect(provider.errorMessage, isNull);
  });

  testWidgets(
    'LIVE CAMERA opens the camera directly when permission is granted',
    (tester) async {
      const permissions = MethodChannel(
        'flutter.baseflow.com/permissions/methods',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissions,
        (call) async =>
            call.method == 'requestPermissions' ? <int, int>{1: 1} : 1,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          permissions,
          null,
        ),
      );
      final picker = TestImageService(() async => null);
      final provider = DetectionProvider(
        modelService: TestModelService(),
        imageService: picker,
      );
      addTearDown(provider.dispose);
      await showHome(tester, provider);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('LIVE CAMERA'));
      await tester.tap(find.text('LIVE CAMERA'));
      await tester.pump();
      // The camera plugin is unavailable in widget tests; let startup's bounded
      // native-camera timeout finish while confirming permission did not pop.
      await tester.pump(const Duration(seconds: 11));
      expect(find.byType(LiveCameraScreen), findsOneWidget);
      expect(picker.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('denying camera permission returns to Home', (tester) async {
    const permissions = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    var requestCount = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      permissions,
      (call) async {
        if (call.method == 'requestPermissions') {
          requestCount++;
          return <int, int>{1: 0};
        }
        return 0;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissions,
        null,
      );
    });

    final provider = DetectionProvider(
      modelService: TestModelService(),
      imageService: TestImageService(() async => null),
    );
    addTearDown(provider.dispose);
    await showHome(tester, provider);
    await tester.pumpAndSettle();

    await tester.tap(find.text('LIVE CAMERA'));
    await tester.pumpAndSettle();

    expect(requestCount, 1);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(LiveCameraScreen), findsNothing);
    expect(
      find.text('Camera permission was denied. Live Camera was closed.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'permanently denied camera permission returns Home with Settings action',
    (tester) async {
      const permissions = MethodChannel(
        'flutter.baseflow.com/permissions/methods',
      );
      var requestCount = 0;
      var settingsOpenCount = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissions,
        (call) async {
          if (call.method == 'requestPermissions') requestCount++;
          if (call.method == 'openAppSettings') settingsOpenCount++;
          return call.method == 'openAppSettings' ? true : 4;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          permissions,
          null,
        ),
      );

      final provider = DetectionProvider(
        modelService: TestModelService(),
        imageService: TestImageService(() async => null),
      );
      addTearDown(provider.dispose);
      await showHome(tester, provider);
      await tester.pumpAndSettle();

      await tester.tap(find.text('LIVE CAMERA'));
      await tester.pumpAndSettle();

      expect(requestCount, 0);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(LiveCameraScreen), findsNothing);
      expect(
        find.textContaining('Camera access is disabled. Enable it in Settings'),
        findsOneWidget,
      );
      await tester.tap(find.text('SETTINGS'));
      await tester.pump();
      expect(settingsOpenCount, 1);
    },
  );
}
