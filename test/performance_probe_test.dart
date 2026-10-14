import 'dart:io';

import 'package:calabash_maturity_detection/services/performance_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

PerformanceMeasurement fixture({
  PerformanceScanMethod method = PerformanceScanMethod.gallery,
  int completeMicros = 3200000,
  int inferenceMicros = 2000000,
  bool warmUp = false,
  String outcome = 'success',
  int? fpsIntervalMicros,
}) => PerformanceMeasurement(
  method: method,
  outcome: outcome,
  warmUp: warmUp,
  completeMicros: completeMicros,
  processingMicros: completeMicros,
  preprocessMicros: 10000,
  inferenceMicros: inferenceMicros,
  postprocessMicros: 10000,
  imageWidth: 640,
  imageHeight: 480,
  fpsIntervalMicros: fpsIntervalMicros,
  modelConfiguration: 'synthetic timing fixture',
);

Future<void> waitForAutomaticWrite(PerformanceProbe probe) async {
  final limit = Stopwatch()..start();
  while (limit.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final raw = probe.rawFile;
    if (raw != null &&
        await raw.exists() &&
        (await raw.readAsString()).contains('synthetic timing fixture')) {
      return;
    }
  }
  fail('Automatic CSV write did not complete');
}

void main() {
  late Directory directory;
  late PerformanceProbe probe;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('calabash-perf-test-');
    probe = PerformanceProbe(
      enabled: true,
      documentsDirectory: () async => directory,
      sessionId: 'fixture-one',
      deviceInformation: 'test device',
      flushInterval: const Duration(hours: 1),
    );
  });
  tearDown(() async {
    await probe.close();
    await directory.delete(recursive: true);
  });

  test('build flag is read without depending on debug or release mode', () {
    expect(
      PerformanceProbe.buildEnabled,
      const bool.fromEnvironment('CALABASH_PERF'),
    );
    expect(PerformanceProbe.instance.enabled, PerformanceProbe.buildEnabled);
  });

  test('disabled recording creates no files or measurements', () async {
    final disabled = PerformanceProbe(
      enabled: false,
      documentsDirectory: () async => throw StateError('must not resolve'),
    );
    expect(disabled.record(fixture()), isNull);
    await disabled.flush();
    expect(disabled.summaryFor(PerformanceScanMethod.gallery).totalCount, 0);
    expect(disabled.lastError, isNull);
    expect(await directory.list().toList(), isEmpty);
    await disabled.close();
  });

  test(
    'separate summaries exclude warmups, stale, errors and invalid values',
    () async {
      probe.record(fixture(warmUp: true, completeMicros: 10000000));
      probe.record(fixture(outcome: 'error'));
      probe.record(fixture(outcome: 'stale'));
      probe.record(fixture(inferenceMicros: -1));
      for (var i = 0; i < 30; i++) {
        probe.record(fixture(completeMicros: 3000000 + i * 10000));
        probe.record(
          fixture(
            method: PerformanceScanMethod.live,
            completeMicros: 1000000 + i * 1000,
            inferenceMicros: 500000,
            fpsIntervalMicros: i.isEven ? 500000 : 1000000,
          ),
        );
      }
      final gallery = probe.summaryFor(PerformanceScanMethod.gallery);
      expect(gallery.validCount, 30);
      expect(gallery.totalCount, 34);
      expect(gallery.excludedCount, 4);
      expect(gallery.warmUpCount, 1);
      expect(gallery.errorCount, 1);
      expect(gallery.staleCount, 1);
      expect(gallery.averageProcessingMs, 3145);
      expect(gallery.minimumProcessingMs, 3000);
      expect(gallery.maximumProcessingMs, 3290);
      expect(gallery.averageInferenceMs, 2000);
      expect(gallery.processingWithin3000Percent, closeTo(100 / 30, .0001));
      expect(gallery.inferenceRequirement, 'PASS');
      final live = probe.summaryFor(PerformanceScanMethod.live);
      expect(live.validCount, 30);
      expect(live.averageProcessingMs, 1014.5);
      expect(live.averageInferenceMs, 500);
      // Completion throughput is count / elapsed intervals, not mean(1 / interval).
      expect(live.averageFps, closeTo(30 / 22.5, .0001));
      await probe.flush();
      final summary = await probe.summaryFile!.readAsString();
      expect(summary, contains('average_yolo_inference_ms'));
      expect(summary, contains('inference_requirement'));
      expect(summary, contains('Gallery'));
      expect(summary, contains('Live'));
      final summaryRows = summary.trim().split('\r\n');
      for (final row in summaryRows.skip(1)) {
        expect(row.split(',').length, summaryRows.first.split(',').length);
      }
    },
  );

  test(
    'threshold is inclusive and insufficient samples do not claim a pass',
    () {
      probe.record(fixture(inferenceMicros: 3000000));
      expect(
        probe.summaryFor(PerformanceScanMethod.gallery).inferenceRequirement,
        'NOT_ENOUGH_DATA',
      );
      for (var i = 1; i < 30; i++) {
        probe.record(fixture(inferenceMicros: 3000000));
      }
      expect(
        probe.summaryFor(PerformanceScanMethod.gallery).inferenceRequirement,
        'PASS',
      );
      probe.record(fixture(inferenceMicros: 3000001));
      expect(
        probe.summaryFor(PerformanceScanMethod.gallery).inferenceRequirement,
        'FAIL',
      );
    },
  );

  test('freshness rejection cannot censor slow completed model inference', () {
    for (var i = 0; i < 30; i++) {
      probe.record(fixture());
    }
    probe.record(
      fixture(
        outcome: 'stale',
        completeMicros: 41000000,
        inferenceMicros: 40000000,
      ),
    );
    final summary = probe.summaryFor(PerformanceScanMethod.gallery);
    expect(summary.validCount, 30);
    expect(summary.inferenceValidCount, 31);
    expect(summary.averageInferenceMs, closeTo(100000 / 31, .001));
    expect(summary.inferenceRequirement, 'FAIL');
  });

  test(
    'raw CSV appends unique rows and preserves unavailable values',
    () async {
      final first = probe.record(fixture());
      await probe.flush();
      final before = await probe.rawFile!.readAsString();
      final second = probe.record(
        PerformanceMeasurement(
          method: PerformanceScanMethod.live,
          outcome: 'error',
          warmUp: false,
          completeMicros: 1234,
          processingMicros: 1234,
        ),
      );
      await Future.wait([probe.flush(), probe.flush()]);
      final after = await probe.rawFile!.readAsString();
      expect(first, isNot(second));
      expect(after, startsWith(before));
      final rows = after.trim().split('\r\n');
      expect(rows.length, 3);
      final header = rows.first.split(',');
      expect(
        header,
        containsAll([
          'session_id',
          'measurement_id',
          'timestamp_utc',
          'platform',
          'device_information',
          'scanning_method',
          'model_configuration',
          'outcome',
          'image_width',
          'image_height',
          'decode_ms',
          'preprocess_ms',
          'yolo_inference_ms',
          'postprocess_ms',
          'complete_processing_ms',
          'model_initialization_ms',
          'queue_ms',
          'processed_fps',
          'warm_up',
          'included_in_summary',
        ]),
      );
      for (final row in rows.skip(1)) {
        expect(row.split(',').length, header.length);
      }
      final values = rows[1].split(',');
      expect(
        DateTime.parse(values[header.indexOf('timestamp_utc')]).isUtc,
        isTrue,
      );
      expect(int.parse(values[header.indexOf('image_width')]), 640);
      expect(double.parse(values[header.indexOf('yolo_inference_ms')]), 2000);
      expect(rows[2].split(',')[header.indexOf('yolo_inference_ms')], isEmpty);
      expect(
        rows[2].split(',')[header.indexOf('complete_processing_ms')],
        '1.234',
      );
    },
  );

  test('new app session preserves previous raw data and summary', () async {
    probe.record(fixture());
    await probe.close();
    final originalFile = probe.rawFile!;
    final original = await originalFile.readAsBytes();
    final next = PerformanceProbe(
      enabled: true,
      documentsDirectory: () async => directory,
      sessionId: 'fixture-two',
    );
    next.record(fixture(method: PerformanceScanMethod.live));
    await next.close();
    expect(next.rawFile!.path, isNot(originalFile.path));
    expect(await originalFile.readAsBytes(), original);
    expect(await probe.summaryFile!.exists(), isTrue);
    expect(await next.summaryFile!.exists(), isTrue);
  });

  test(
    'CSV quotes commas, quotation marks and newlines in device metadata',
    () async {
      final quoted = PerformanceProbe(
        enabled: true,
        documentsDirectory: () async => directory,
        deviceInformation: 'iPhone, "fixture"\nsecond line',
      );
      quoted.record(fixture());
      await quoted.close();
      expect(
        await quoted.rawFile!.readAsString(),
        contains('"iPhone, ""fixture""\nsecond line"'),
      );
    },
  );

  test('storage errors are exposed without throwing into detection', () async {
    final unavailable = PerformanceProbe(
      enabled: true,
      documentsDirectory: () async => throw FileSystemException('unavailable'),
    );
    unavailable.record(fixture());
    await unavailable.flush();
    expect(unavailable.lastError, isNotNull);
    await unavailable.close();
  });

  test(
    'automatic batching persists rows without an explicit export or close',
    () async {
      final automatic = PerformanceProbe(
        enabled: true,
        documentsDirectory: () async => directory,
        flushInterval: const Duration(milliseconds: 5),
      );
      automatic.record(fixture());
      await waitForAutomaticWrite(automatic);
      await automatic.close();
    },
  );

  test(
    'background flush also persists a late result without waiting for batch timer',
    () async {
      probe.didChangeAppLifecycleState(AppLifecycleState.paused);
      probe.record(fixture());
      // Await already requested writes; a batch timer of one hour cannot explain this.
      await waitForAutomaticWrite(probe);
      expect(
        await probe.rawFile!.readAsString(),
        contains('synthetic timing fixture'),
      );
    },
  );

  test(
    'storage recovery retries pending rows once without replacing old data',
    () async {
      var available = false;
      final recovering = PerformanceProbe(
        enabled: true,
        documentsDirectory: () async {
          if (!available) {
            throw FileSystemException('fixture temporarily unavailable');
          }
          return directory;
        },
      );
      recovering.record(fixture());
      await recovering.flush();
      expect(recovering.lastError, isNotNull);
      available = true;
      await recovering.flush();
      expect(recovering.lastError, isNull);
      expect(
        (await recovering.rawFile!.readAsString()).trim().split('\r\n').length,
        2,
      );
      expect(
        recovering.summaryFor(PerformanceScanMethod.gallery).totalCount,
        1,
      );
      await recovering.close();
    },
  );
}
