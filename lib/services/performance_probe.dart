import 'dart:convert';

/// Release-mode measurements enabled only for the research measurement APK.
/// Read monotonic elapsed time before logging so log I/O is outside the timer.
class PerformanceProbe {
  static const enabled = bool.fromEnvironment('CALABASH_PERF');
  static const galleryRepeats = int.fromEnvironment(
    'CALABASH_GALLERY_REPEATS',
    defaultValue: 1,
  );
  static int _sequence = 0;

  static void record({
    required String method,
    required Stopwatch timer,
    required DateTime startedAt,
    required int detections,
    String? backend,
    int? frameId,
    double? frameAgeMs,
    String? imagePath,
  }) {
    if (!enabled) return;
    timer.stop();
    final elapsed = timer.elapsedMicroseconds / 1000;
    final endedAt = DateTime.now();
    // A single structured line lets ADB preserve each sample without UI widgets.
    // ignore: avoid_print
    print(
      'CALABASH_PERF ${jsonEncode({'sequence': ++_sequence, 'method': method, 'start_utc': startedAt.toUtc().toIso8601String(), 'end_utc': endedAt.toUtc().toIso8601String(), 'processing_ms': elapsed, 'detections': detections, 'backend': backend, 'frame_id': frameId, 'frame_age_ms': frameAgeMs, 'image_path': imagePath})}',
    );
  }
}
