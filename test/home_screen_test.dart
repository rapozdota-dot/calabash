import 'dart:io';

import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/home_screen.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/services/performance_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

PerformanceMeasurement _measurement(PerformanceScanMethod method) =>
    PerformanceMeasurement(
      method: method,
      outcome: 'success',
      warmUp: false,
      completeMicros: 1000,
      processingMicros: 1000,
      inferenceMicros: 500,
    );

class _EmptyExportProbe extends PerformanceProbe {
  _EmptyExportProbe() : super(enabled: true);

  @override
  Future<File> exportZip() async => throw const NoPerformanceDataException();
}

Widget _homeWithProbe(PerformanceProbe probe) =>
    ChangeNotifierProvider<DetectionProvider>(
      create: (_) => DetectionProvider(
        modelService: ModelService(),
        imageService: ImageService(),
        performanceProbe: probe,
      ),
      child: MaterialApp(home: HomeScreen(performanceProbe: probe)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Home exposes the performance ZIP export action', (tester) async {
    final provider = DetectionProvider(
      modelService: ModelService(),
      imageService: ImageService(),
    );
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<DetectionProvider>.value(
        value: provider,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Export Performance Data'), findsOneWidget);
  });

  testWidgets('Home recording counts refresh after measurements', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('calabash-home-status-test-'),
    ))!;
    final probe = PerformanceProbe(
      enabled: true,
      documentsDirectory: () async => directory,
      sessionId: 'home-status',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(probe.close);
      await tester.runAsync(() => directory.delete(recursive: true));
    });

    await tester.pumpWidget(_homeWithProbe(probe));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Performance recording is enabled'), findsOneWidget);
    expect(find.text('Measurements this session: 0'), findsOneWidget);
    expect(find.text('Live Detection: 0'), findsOneWidget);
    expect(find.text('Capture: 0'), findsOneWidget);
    expect(find.text('Gallery: 0'), findsOneWidget);

    probe.record(_measurement(PerformanceScanMethod.gallery));
    await tester.pump();

    expect(find.text('Measurements this session: 1'), findsOneWidget);
    expect(find.text('Gallery: 1'), findsOneWidget);
    expect(find.text('Live Detection: 0'), findsOneWidget);
    expect(find.text('Capture: 0'), findsOneWidget);
    await tester.runAsync(probe.close);
  });

  testWidgets('Home explains when this build has recording disabled', (
    tester,
  ) async {
    final probe = PerformanceProbe(enabled: false);
    await tester.pumpWidget(_homeWithProbe(probe));

    expect(find.text('Performance recording is disabled'), findsOneWidget);
    expect(
      find.text('This build does not have performance recording enabled.'),
      findsOneWidget,
    );
  });

  testWidgets('empty performance export shows the empty-session message', (
    tester,
  ) async {
    final probe = _EmptyExportProbe();

    await tester.pumpWidget(_homeWithProbe(probe));
    await tester.pump(const Duration(milliseconds: 400));
    final exportButton = find.text('Export Performance Data');
    await tester.ensureVisible(exportButton);
    await tester.tap(exportButton);
    await tester.pump();

    expect(
      find.text(
        'No performance data recorded yet. Run Live Detection, Capture, or Gallery detection, then export again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Home makes storage failures visible without exposing paths', (
    tester,
  ) async {
    final probe = PerformanceProbe(
      enabled: true,
      documentsDirectory: () async => throw const FileSystemException(
        'storage unavailable',
        '/private/app/path',
      ),
    );
    probe.record(_measurement(PerformanceScanMethod.capture));
    await probe.flush();
    await tester.pumpWidget(_homeWithProbe(probe));

    expect(
      find.text(
        'Performance data could not be saved. Check device storage and try exporting again.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('/private/app/path'), findsNothing);
  });
}
