import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

enum PerformanceScanMethod {
  live('Live'),
  gallery('Gallery'),
  capture('Capture');

  const PerformanceScanMethod(this.label);
  final String label;
}

/// Actual elapsed microseconds. Null means unavailable, never an estimated zero.
class PerformanceMeasurement {
  const PerformanceMeasurement({
    required this.method,
    required this.outcome,
    required this.warmUp,
    required this.completeMicros,
    required this.processingMicros,
    this.timestamp,
    this.preprocessMicros,
    this.inferenceMicros,
    this.postprocessMicros,
    this.decodeMicros,
    this.fileReadMicros,
    this.modelInitializationMicros,
    this.conversionMicros,
    this.orientationMicros,
    this.resultPreparationMicros,
    this.queueMicros,
    this.fpsIntervalMicros,
    this.imageWidth,
    this.imageHeight,
    this.frameId,
    this.detectionCount,
    this.modelConfiguration = '',
  });

  final PerformanceScanMethod method;
  final String outcome;
  final bool warmUp;
  final DateTime? timestamp;
  final int completeMicros;
  final int processingMicros;
  final int? preprocessMicros;
  final int? inferenceMicros;
  final int? postprocessMicros;
  final int? decodeMicros;
  final int? fileReadMicros;
  final int? modelInitializationMicros;
  final int? conversionMicros;
  final int? orientationMicros;
  final int? resultPreparationMicros;
  final int? queueMicros;
  final int? fpsIntervalMicros;
  final int? imageWidth;
  final int? imageHeight;
  final int? frameId;
  final int? detectionCount;
  final String modelConfiguration;

  String get exclusionReason {
    if (outcome != 'success') return outcome;
    if (warmUp) return 'warm_up';
    return _timingExclusionReason;
  }

  String get _timingExclusionReason {
    if (preprocessMicros == null ||
        inferenceMicros == null ||
        postprocessMicros == null) {
      return 'missing_metrics';
    }
    final durations = [
      completeMicros,
      processingMicros,
      preprocessMicros!,
      inferenceMicros!,
      postprocessMicros!,
      ?queueMicros,
      ?decodeMicros,
      ?fileReadMicros,
      ?modelInitializationMicros,
      ?conversionMicros,
      ?orientationMicros,
      ?resultPreparationMicros,
    ];
    if (durations.any((value) => value < 0) ||
        inferenceMicros! > completeMicros ||
        processingMicros > completeMicros ||
        (queueMicros != null && queueMicros! > completeMicros)) {
      return 'invalid_timing';
    }
    return '';
  }

  bool get included => exclusionReason.isEmpty;

  /// Freshness/UI rejection must not censor completed, slow neural executions.
  bool get includedInInference =>
      const ['success', 'stale', 'invalidated'].contains(outcome) &&
      !warmUp &&
      _timingExclusionReason.isEmpty;
}

/// Uses all valid raw samples, never averages of rounded reporting windows.
class PerformanceSummary {
  int totalCount = 0;
  int validCount = 0;
  int inferenceValidCount = 0;
  int successfulCount = 0;
  int warmUpCount = 0;
  int errorCount = 0;
  int staleCount = 0;
  int invalidatedCount = 0;
  int invalidTimingCount = 0;
  int _totalProcessingMicros = 0;
  int _totalInferenceMicros = 0;
  int _totalActiveProcessingMicros = 0;
  int _inferenceWithin3000 = 0;
  int? _minimumMicros;
  int? _maximumMicros;
  int _within3000 = 0;
  int _fpsCount = 0;
  int _fpsIntervalMicros = 0;

  int get excludedCount => totalCount - validCount;
  double? get averageProcessingMs =>
      validCount == 0 ? null : _totalProcessingMicros / validCount / 1000;
  double? get minimumProcessingMs =>
      _minimumMicros == null ? null : _minimumMicros! / 1000;
  double? get maximumProcessingMs =>
      _maximumMicros == null ? null : _maximumMicros! / 1000;
  double? get averageInferenceMs => inferenceValidCount == 0
      ? null
      : _totalInferenceMicros / inferenceValidCount / 1000;
  double? get averageActiveProcessingMs =>
      validCount == 0 ? null : _totalActiveProcessingMicros / validCount / 1000;
  double? get inferenceWithin3000Percent => inferenceValidCount == 0
      ? null
      : _inferenceWithin3000 * 100 / inferenceValidCount;
  double? get processingWithin3000Percent =>
      validCount == 0 ? null : _within3000 * 100 / validCount;
  double? get averageFps =>
      _fpsCount == 0 ? null : _fpsCount * 1000000 / _fpsIntervalMicros;
  String get inferenceRequirement => inferenceValidCount < 30
      ? 'NOT_ENOUGH_DATA'
      : (_totalInferenceMicros <= inferenceValidCount * 3000000
            ? 'PASS'
            : 'FAIL');

  void add(PerformanceMeasurement sample) {
    totalCount++;
    if (sample.outcome == 'success') successfulCount++;
    if (sample.warmUp) warmUpCount++;
    if (sample.outcome == 'error') errorCount++;
    if (sample.outcome == 'stale') staleCount++;
    if (sample.outcome == 'invalidated') invalidatedCount++;
    if (sample.exclusionReason == 'invalid_timing' ||
        sample.exclusionReason == 'missing_metrics') {
      invalidTimingCount++;
    }
    if (sample.includedInInference) {
      inferenceValidCount++;
      _totalInferenceMicros += sample.inferenceMicros!;
      if (sample.inferenceMicros! <= 3000000) _inferenceWithin3000++;
      final interval = sample.fpsIntervalMicros;
      if (interval != null && interval > 0) {
        _fpsCount++;
        _fpsIntervalMicros += interval;
      }
    }
    if (!sample.included) return;
    validCount++;
    _totalProcessingMicros += sample.completeMicros;
    _totalActiveProcessingMicros += sample.processingMicros;
    _minimumMicros = _minimumMicros == null
        ? sample.completeMicros
        : min(_minimumMicros!, sample.completeMicros);
    _maximumMicros = _maximumMicros == null
        ? sample.completeMicros
        : max(_maximumMicros!, sample.completeMicros);
    if (sample.completeMicros <= 3000000) _within3000++;
  }
}

/// Adapts the existing measurement branch's CALABASH_PERF opt-in to persistent CSV.
/// Call record only AFTER stopping processing timers. File I/O is serialized,
/// asynchronous and batched; failures never propagate into camera/photo handling.
class PerformanceProbe with WidgetsBindingObserver {
  PerformanceProbe({
    required this.enabled,
    Future<Directory> Function()? documentsDirectory,
    String? sessionId,
    String? deviceInformation,
    this.flushInterval = const Duration(seconds: 1),
  }) : _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       startedAt = DateTime.now().toUtc(),
       sessionId =
           sessionId ??
           (enabled
               ? '${DateTime.now().toUtc().microsecondsSinceEpoch}-${Random.secure().nextInt(0x100000000).toRadixString(16)}'
               : 'disabled'),
       deviceInformation =
           deviceInformation ??
           '${const String.fromEnvironment('CALABASH_PERF_DEVICE')} ${Platform.operatingSystemVersion}; processors=${Platform.numberOfProcessors}'
               .trim();

  static const buildEnabled = bool.fromEnvironment('CALABASH_PERF');
  static final instance = PerformanceProbe(enabled: buildEnabled);
  static const sourceRevision = String.fromEnvironment(
    'CALABASH_SOURCE_REVISION',
  );
  static const buildNumber = String.fromEnvironment('CALABASH_BUILD_NUMBER');
  static const modelSha256 = String.fromEnvironment('CALABASH_MODEL_SHA256');
  static const rawHeader = [
    'session_id',
    'measurement_id',
    'timestamp_utc',
    'platform',
    'device_information',
    'source_revision',
    'build_number',
    'model_sha256',
    'scanning_method',
    'model_configuration',
    'outcome',
    'image_width',
    'image_height',
    'frame_id',
    'detections',
    'file_read_ms',
    'decode_ms',
    'model_initialization_ms',
    'conversion_ms',
    'orientation_ms',
    'preprocess_ms',
    'yolo_inference_ms',
    'postprocess_ms',
    'result_preparation_ms',
    'processing_ms',
    'complete_processing_ms',
    'queue_ms',
    'processed_fps',
    'fps_interval_ms',
    'warm_up',
    'included_in_summary',
    'included_in_inference_summary',
    'exclusion_reason',
    'successful_runs',
  ];
  static const summaryHeader = [
    'session_id',
    'scanning_method',
    'total_measurements',
    'successful_runs',
    'valid_measurements',
    'valid_inference_measurements',
    'excluded_measurements',
    'warm_up_measurements',
    'error_measurements',
    'stale_measurements',
    'invalidated_measurements',
    'invalid_timing_measurements',
    'average_complete_processing_ms',
    'average_processing_excluding_queue_ms',
    'minimum_complete_processing_ms',
    'maximum_complete_processing_ms',
    'average_yolo_inference_ms',
    'average_processed_fps',
    'complete_processing_within_3000_ms_percent',
    'inference_within_3000_ms_percent',
    'inference_requirement',
    'required_valid_measurements',
    'dropped_recordings',
  ];

  final bool enabled;
  final DateTime startedAt;
  final String sessionId;
  final String deviceInformation;
  final Duration flushInterval;
  final Future<Directory> Function() _documentsDirectory;
  final _summaries = {
    for (final method in PerformanceScanMethod.values)
      method: PerformanceSummary(),
  };
  final _persistedSummaries = {
    for (final method in PerformanceScanMethod.values)
      method: PerformanceSummary(),
  };
  final List<({PerformanceMeasurement sample, String row})> _pending = [];
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _initializing;
  Future<void>? _closing;
  Timer? _flushTimer;
  File? rawFile;
  File? summaryFile;
  String? lastError;
  int _sequence = 0;
  int _droppedRecordings = 0;
  bool _closed = false;
  bool _observing = false;
  bool _backgrounded = false;

  PerformanceSummary summaryFor(PerformanceScanMethod method) =>
      _summaries[method]!;

  void attachLifecycle() {
    if (!enabled || _observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
    unawaited(flush());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _backgrounded = state != AppLifecycleState.resumed;
    if (_backgrounded) unawaited(flush());
  }

  String? record(PerformanceMeasurement sample) {
    if (!enabled || _closed) return null;
    // Bound memory if storage is unavailable for an extended period.
    if (_pending.length >= 4096) {
      _droppedRecordings++;
      _reportError(
        StateError('Performance buffer full; export is incomplete.'),
      );
      return null;
    }
    final id = '$sessionId-${++_sequence}';
    final summary = _summaries[sample.method]!..add(sample);
    _pending.add((
      sample: sample,
      row: _csv([
        sessionId,
        id,
        (sample.timestamp ?? DateTime.now()).toUtc().toIso8601String(),
        Platform.operatingSystem,
        deviceInformation,
        sourceRevision,
        buildNumber,
        modelSha256,
        sample.method.label,
        sample.modelConfiguration,
        sample.outcome,
        sample.imageWidth,
        sample.imageHeight,
        sample.frameId,
        sample.detectionCount,
        _ms(sample.fileReadMicros),
        _ms(sample.decodeMicros),
        _ms(sample.modelInitializationMicros),
        _ms(sample.conversionMicros),
        _ms(sample.orientationMicros),
        _ms(sample.preprocessMicros),
        _ms(sample.inferenceMicros),
        _ms(sample.postprocessMicros),
        _ms(sample.resultPreparationMicros),
        _ms(sample.processingMicros),
        _ms(sample.completeMicros),
        _ms(sample.queueMicros),
        sample.fpsIntervalMicros == null || sample.fpsIntervalMicros! <= 0
            ? null
            : 1000000 / sample.fpsIntervalMicros!,
        _ms(sample.fpsIntervalMicros),
        sample.warmUp,
        sample.included,
        sample.includedInInference,
        sample.exclusionReason,
        summary.successfulCount,
      ]),
    ));
    if (_backgrounded) {
      unawaited(flush());
    } else {
      _flushTimer ??= Timer(flushInterval, () => unawaited(flush()));
    }
    return id;
  }

  Future<void> _ensureFiles() async {
    if (rawFile != null) return;
    await (_initializing ??= _createFiles().whenComplete(
      () => _initializing = null,
    ));
  }

  Future<void> _createFiles() async {
    final documents = await _documentsDirectory();
    final folder = await Directory(
      '${documents.path}/calabash_performance',
    ).create(recursive: true);
    final date = startedAt.toIso8601String().substring(0, 10);
    final stem = '${folder.path}/calabash_performance_${date}_$sessionId';
    final raw = File('${stem}_raw.csv');
    if (await raw.exists()) {
      throw StateError(
        'Session file already exists; refusing to overwrite raw data.',
      );
    }
    await raw.writeAsString(_csv(rawHeader), flush: true);
    rawFile = raw;
    summaryFile = File('${stem}_summary.csv');
  }

  Future<void> flush() {
    if (!enabled) return Future<void>.value();
    _flushTimer?.cancel();
    _flushTimer = null;
    _writeTail = _writeTail.then((_) async {
      var rawWritten = false;
      final batch = List.of(_pending);
      _pending.clear();
      try {
        await _ensureFiles();
        if (batch.isNotEmpty) {
          await rawFile!.writeAsString(
            batch.map((item) => item.row).join(),
            mode: FileMode.append,
            flush: true,
          );
          rawWritten = true;
          for (final item in batch) {
            _persistedSummaries[item.sample.method]!.add(item.sample);
          }
        }
        await summaryFile!.writeAsString(
          _csv(summaryHeader) +
              PerformanceScanMethod.values.map((method) {
                final s = _persistedSummaries[method]!;
                return _csv([
                  sessionId,
                  method.label,
                  s.totalCount,
                  s.successfulCount,
                  s.validCount,
                  s.inferenceValidCount,
                  s.excludedCount,
                  s.warmUpCount,
                  s.errorCount,
                  s.staleCount,
                  s.invalidatedCount,
                  s.invalidTimingCount,
                  s.averageProcessingMs,
                  s.averageActiveProcessingMs,
                  s.minimumProcessingMs,
                  s.maximumProcessingMs,
                  s.averageInferenceMs,
                  s.averageFps,
                  s.processingWithin3000Percent,
                  s.inferenceWithin3000Percent,
                  _droppedRecordings == 0
                      ? s.inferenceRequirement
                      : 'RECORDING_INCOMPLETE',
                  30,
                  _droppedRecordings,
                ]);
              }).join(),
          flush: true,
        );
        lastError = null;
      } catch (error) {
        if (!rawWritten) _pending.insertAll(0, batch);
        _reportError(error);
      }
    });
    return _writeTail;
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    _flushTimer?.cancel();
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    await flush();
  }();

  void _reportError(Object error) {
    final message = '$error';
    if (lastError != message) {
      debugPrint('CALABASH_PERF storage error: $message');
    }
    lastError = message;
  }

  static String? _ms(int? micros) =>
      micros == null ? null : (micros / 1000).toStringAsFixed(3);
  static String _csv(List<Object?> fields) =>
      '${fields.map((value) {
        final text = value is double ? value.toStringAsFixed(6) : value?.toString() ?? '';
        return text.contains(RegExp('[,"\r\n]')) ? '"${text.replaceAll('"', '""')}"' : text;
      }).join(',')}\r\n';
}
