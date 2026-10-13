import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
import 'package:calabash_maturity_detection/screens/live_camera_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  group('LiveCameraPermissionPolicy', () {
    test('routes denied iOS camera access to Settings', () {
      expect(
        LiveCameraPermissionPolicy.shouldOfferSettings(
          status: PermissionStatus.denied,
          platform: TargetPlatform.iOS,
        ),
        isTrue,
      );
    });

    test('keeps Android denied camera access retryable', () {
      expect(
        LiveCameraPermissionPolicy.shouldOfferSettings(
          status: PermissionStatus.denied,
          platform: TargetPlatform.android,
        ),
        isFalse,
      );
    });

    test('requests the system prompt only for retryable denied states', () {
      expect(
        LiveCameraPermissionPolicy.shouldRequestSystemPrompt(
          status: PermissionStatus.denied,
          requestPermission: true,
        ),
        isTrue,
      );
      expect(
        LiveCameraPermissionPolicy.shouldRequestSystemPrompt(
          status: PermissionStatus.permanentlyDenied,
          requestPermission: true,
        ),
        isFalse,
      );
    });
  });

  testWidgets('denied iOS camera access offers Settings', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    const permissionChannel = MethodChannel(
      'flutter.baseflow.com/permissions/methods',
    );
    var requestCount = 0;
    var settingsOpenCount = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      permissionChannel,
      (call) async {
        switch (call.method) {
          case 'checkPermissionStatus':
            return PermissionStatus.denied.index;
          case 'requestPermissions':
            requestCount++;
            return <int, int>{1: PermissionStatus.denied.index};
          case 'openAppSettings':
            settingsOpenCount++;
            return true;
        }
        return PermissionStatus.denied.index;
      },
    );

    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissionChannel,
        null,
      );
    });

    await tester.pumpWidget(const MaterialApp(home: LiveCameraScreen()));
    await tester.pumpAndSettle();

    expect(requestCount, 1);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.textContaining('Camera access is disabled'), findsOneWidget);

    await tester.tap(find.text('Open Settings'));
    await tester.pump();

    expect(settingsOpenCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
