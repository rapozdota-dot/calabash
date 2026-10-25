import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
import 'package:calabash_maturity_detection/providers/live_detection_tracker.dart';
import 'package:calabash_maturity_detection/screens/live_camera_screen.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:calabash_maturity_detection/widgets/detection_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'detection_provider_test.dart' show TestImageService, TestModelService;

const _helpTooltip = 'About live predictions';
const _confidenceExplanation =
    "The displayed confidence score indicates how strongly the model favors a predicted maturity class. It does not represent the model's measured accuracy or statistical margin of error.";
const _externalReminder =
    'Maturity predictions are based on external appearance only.';

class _PreviewController extends CameraController {
  _PreviewController()
    : super(
        const CameraDescription(
          name: 'test-rear',
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
  List<LiveDetection> displayed = [];
  LiveStabilityStatus readiness = LiveStabilityStatus.noCalabashDetected;
  int initializations = 0;
  int resumes = 0;
  int captures = 0;
  int torchToggles = 0;
  bool torchOn = false;
  bool captureActive = false;
  File? capturedFile;
  Completer<File?>? pendingCapture;

  @override
  Future<void> initialize() async => initializations++;
  @override
  CameraController get cameraController => controller;
  @override
  LiveCameraStatus get status => LiveCameraStatus.cameraReady;
  @override
  bool get isCameraReady => true;
  @override
  bool get isInferenceReady => true;
  @override
  bool get hasProcessedFrame => true;
  @override
  List<LiveDetection> get liveDetections => displayed;
  @override
  LiveStabilityStatus get stabilityStatus => readiness;
  @override
  bool get isTorchOn => torchOn;
  @override
  bool get isCaptureWorkflowActive => captureActive;

  @override
  Future<bool> toggleTorch() async {
    torchToggles++;
    torchOn = !torchOn;
    notifyListeners();
    return true;
  }

  @override
  Future<File?> captureStillImage() async {
    captures++;
    captureActive = true;
    notifyListeners();
    return pendingCapture == null ? capturedFile : await pendingCapture!.future;
  }

  @override
  Future<void> resumeLiveDetection() async {
    resumes++;
    captureActive = false;
    notifyListeners();
  }

  void publish(List<LiveDetection> detections, LiveStabilityStatus stability) {
    displayed = detections;
    readiness = stability;
    notifyListeners();
  }
}

// Synthetic presentation fixtures; they are not measured model predictions.
LiveDetection _prediction({
  int trackId = 1,
  double confidence = .864,
  LiveConfidenceTier tier = LiveConfidenceTier.normal,
  bool uncertain = false,
}) => LiveDetection(
  trackId: trackId,
  detection: Detection(
    boundingBox: const Rect.fromLTWH(.2, .35, .3, .3),
    maturityClass: MaturityClass.mature,
    confidence: confidence,
    mask: SegmentationMask(
      bounds: const Rect.fromLTWH(.2, .35, .3, .3),
      width: 2,
      height: 2,
      pixels: Uint8List.fromList([1, 1, 1, 1]),
    ),
  ),
  confidenceTier: tier,
  animateBounds: false,
  maturityUncertain: uncertain,
);

Future<_PreviewProvider> _showCamera(
  WidgetTester tester, {
  double textScale = 1,
}) async {
  final controller = _PreviewController();
  addTearDown(controller.dispose);
  final live = _PreviewProvider(controller);
  final detector = DetectionProvider(
    modelService: TestModelService(
      infer: () async => [_prediction().detection],
    ),
    imageService: TestImageService(() async => null),
  );
  addTearDown(detector.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<DetectionProvider>.value(
      value: detector,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: const EdgeInsets.only(top: 24, bottom: 16),
            viewPadding: const EdgeInsets.only(top: 24, bottom: 16),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LiveCameraScreen(providerFactory: () => live),
                ),
              ),
              child: const Text('Open camera'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open camera'));
  await tester.pumpAndSettle();
  return live;
}

void main() {
  testWidgets(
    'one accessible help control explains confidence and external appearance',
    (tester) async {
      final live = await _showCamera(tester);
      live.publish([
        _prediction(),
        _prediction(trackId: 2, confidence: .914),
      ], LiveStabilityStatus.ready);
      await tester.pumpAndSettle();
      final help = find.byTooltip(_helpTooltip);
      expect(help, findsOneWidget);
      final semantics = tester.getSemantics(help).getSemanticsData();
      expect(semantics.tooltip, _helpTooltip);
      expect(semantics.flagsCollection.isButton, isTrue);
      expect(semantics.hasAction(SemanticsAction.tap), isTrue);
      expect(find.text('86%'), findsOneWidget);
      expect(find.text('91%'), findsOneWidget);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.text(_confidenceExplanation), findsOneWidget);
      expect(find.text(_externalReminder), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('86%'), findsOneWidget);
      expect(find.text('91%'), findsOneWidget);
      expect(live.initializations, 1);
      expect(live.resumes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'help preserves live updates, masks, confidence tiers, and empty state',
    (tester) async {
      final live = await _showCamera(tester);
      expect(find.text('No calabash fruits detected'), findsOneWidget);
      expect(
        find.text('Tap to focus. Move closer in good light.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip(_helpTooltip));
      await tester.pumpAndSettle();
      final normal = _prediction();
      live.publish([normal], LiveStabilityStatus.ready);
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('#1 Mature'), findsOneWidget);
      expect(find.text('86%'), findsOneWidget);
      expect(find.text('Ready to capture'), findsOneWidget);
      expect(find.text('Tap capture to review maturity'), findsOneWidget);
      final overlay = tester.widget<AnimatedDetectionBox>(
        find.byType(AnimatedDetectionBox),
      );
      expect(overlay.key, const ValueKey<int>(1));
      expect(overlay.detection, same(normal.detection));
      expect(overlay.detection.mask, same(normal.detection.mask));
      expect(overlay.detection.confidence, .864);

      for (final state in [
        (
          prediction: _prediction(
            confidence: .52,
            tier: LiveConfidenceTier.weak,
          ),
          label: 'Possible Mature',
          subtitle: 'Hold steady to confirm',
        ),
        (
          prediction: _prediction(confidence: .4, tier: LiveConfidenceTier.low),
          label: 'Low confidence',
          subtitle: 'Reposition camera',
        ),
        (
          prediction: _prediction(uncertain: true),
          label: '#1 Calabash',
          subtitle: 'Maturity uncertain',
        ),
      ]) {
        live.publish([state.prediction], LiveStabilityStatus.holdSteady);
        await tester.pumpAndSettle();
        expect(find.text(state.label), findsOneWidget);
        expect(find.text(state.subtitle), findsOneWidget);
        expect(find.text('Hold steady'), findsOneWidget);
        expect(find.text('86%'), findsNothing);
        expect(find.byType(AnimatedDetectionBox), findsOneWidget);
      }
      live.publish([], LiveStabilityStatus.noCalabashDetected);
      await tester.pumpAndSettle();
      expect(find.byType(AnimatedDetectionBox), findsNothing);
      expect(find.text('No calabash fruits detected'), findsOneWidget);
      expect(find.byTooltip(_helpTooltip), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing help preserves flashlight, capture result, and Back navigation',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'calabash-live-help-',
      );
      final image = File('${directory.path}/capture.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 32, height: 32)));
      addTearDown(() {
        image.deleteSync();
        directory.deleteSync();
      });
      final live = await _showCamera(tester)
        ..capturedFile = image;
      final originalPreview = tester.element(
        find.byKey(const ValueKey('live-camera-preview')),
      );
      await tester.tap(find.byTooltip(_helpTooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(
        tester.element(find.byKey(const ValueKey('live-camera-preview'))),
        same(originalPreview),
      );
      await tester.tap(find.byTooltip('Turn flashlight on'));
      await tester.pumpAndSettle();
      expect(live.torchToggles, 1);
      expect(find.byTooltip('Turn flashlight off'), findsOneWidget);
      expect(find.byType(FilledButton).hitTestable(), findsOneWidget);
      await tester.runAsync(
        () => precacheImage(
          FileImage(image),
          tester.element(find.byType(LiveCameraScreen)),
        ),
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(live.captures, 1);
      expect(find.byType(ResultScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LiveCameraScreen), findsOneWidget);
      expect(live.resumes, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Open camera'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'help cannot interrupt navigation while a still capture is pending',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'calabash-busy-help-',
      );
      final image = File('${directory.path}/capture.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 32, height: 32)));
      addTearDown(() {
        image.deleteSync();
        directory.deleteSync();
      });
      final pending = Completer<File?>();
      final live = await _showCamera(tester)
        ..pendingCapture = pending;
      await tester.runAsync(
        () => precacheImage(
          FileImage(image),
          tester.element(find.byType(LiveCameraScreen)),
        ),
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      try {
        final helpButton = find.widgetWithIcon(
          IconButton,
          Icons.info_outline_rounded,
        );
        expect(tester.widget<IconButton>(helpButton).onPressed, isNull);
        await tester.tap(find.byTooltip(_helpTooltip));
        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing);
      } finally {
        pending.complete(image);
      }
      await tester.pumpAndSettle();
      expect(find.byType(ResultScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LiveCameraScreen), findsOneWidget);
      expect(live.resumes, 1);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.info_outline_rounded),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(568, 320),
    const Size(844, 390),
  ]) {
    testWidgets(
      'help and camera controls fit $size at 2x text with safe insets',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final live = await _showCamera(tester, textScale: 2);
        live.publish([_prediction()], LiveStabilityStatus.ready);
        await tester.pumpAndSettle();
        final help = find.byTooltip(_helpTooltip);
        final shutter = find.byType(FilledButton);
        expect(help.hitTestable(), findsOneWidget);
        expect(shutter.hitTestable(), findsOneWidget);
        expect(find.byTooltip('Back').hitTestable(), findsOneWidget);
        expect(
          find.byTooltip('Turn flashlight on').hitTestable(),
          findsOneWidget,
        );
        expect(tester.getRect(help).overlaps(tester.getRect(shutter)), isFalse);
        expect(
          tester.getRect(help).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
        );
        expect(
          tester.getRect(shutter).bottom,
          lessThanOrEqualTo(size.height - 16),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(help);
        await tester.pumpAndSettle();
        expect(find.text(_confidenceExplanation), findsOneWidget);
        await tester.ensureVisible(find.text(_externalReminder));
        await tester.pumpAndSettle();
        expect(find.text(_externalReminder).hitTestable(), findsOneWidget);
        expect(find.text('Close').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(shutter.hitTestable(), findsOneWidget);
        expect(find.text('86%'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
