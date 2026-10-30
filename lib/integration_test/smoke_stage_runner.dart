import 'dart:async';

const smokeTestTimeout = Duration(minutes: 5);

const smokeStageTimeouts = <String, Duration>{
  'test initialization': Duration(seconds: 30),
  'photo processing': Duration(minutes: 2),
  'live worker startup': Duration(seconds: 75),
  'live worker inference': Duration(minutes: 2),
  'cleanup': Duration(seconds: 30),
};

class SmokeStageTimeoutException implements Exception {
  const SmokeStageTimeoutException({
    required this.stage,
    required this.limit,
    required this.elapsed,
  });

  final String stage;
  final Duration limit;
  final Duration elapsed;

  @override
  String toString() =>
      'Smoke stage "$stage" timed out after ${elapsed.inMilliseconds} ms '
      '(limit ${limit.inMilliseconds} ms).';
}

/// Adds timestamps, cumulative elapsed time, and a bounded wait to async stages.
/// A Dart future timeout does not cancel the operation. Callers with temporary
/// resources can defer cleanup with [onLateCompletion].
class SmokeStageRunner {
  SmokeStageRunner({void Function(String message)? log}) : _log = log ?? print;

  final void Function(String message) _log;
  final Stopwatch _total = Stopwatch()..start();

  void mark(String stage, String event, {String? details}) {
    _log(_format(stage, event, Stopwatch(), details));
  }

  Future<T> run<T>(
    String stage, {
    required Duration timeout,
    required FutureOr<T> Function() operation,
    void Function()? onTimeout,
    FutureOr<void> Function()? onLateCompletion,
  }) async {
    final elapsed = Stopwatch()..start();
    _log(_format(stage, 'START', elapsed));
    final pending = Future<T>.sync(operation);
    try {
      final value = await pending.timeout(
        timeout,
        onTimeout: () {
          final error = SmokeStageTimeoutException(
            stage: stage,
            limit: timeout,
            elapsed: elapsed.elapsed,
          );
          _log(_format(stage, 'TIMEOUT', elapsed, error.toString()));
          onTimeout?.call();
          if (onLateCompletion != null) {
            unawaited(_runLateCompletion(stage, pending, onLateCompletion));
          }
          throw error;
        },
      );
      _log(_format(stage, 'PASS', elapsed));
      return value;
    } catch (error, stackTrace) {
      _log(_format(stage, 'FAIL', elapsed, '$error\n$stackTrace'));
      rethrow;
    }
  }

  /// Logs synchronous work accurately. Synchronous native calls cannot be
  /// interrupted by a Dart Future timeout; the workflow step is the hard cap.
  T runSync<T>(String stage, T Function() operation) {
    final elapsed = Stopwatch()..start();
    _log(_format(stage, 'START', elapsed));
    try {
      final value = operation();
      _log(_format(stage, 'PASS', elapsed));
      return value;
    } catch (error, stackTrace) {
      _log(_format(stage, 'FAIL', elapsed, '$error\n$stackTrace'));
      rethrow;
    }
  }

  Future<void> _runLateCompletion<T>(
    String stage,
    Future<T> pending,
    FutureOr<void> Function() cleanup,
  ) async {
    try {
      await pending;
    } catch (error, stackTrace) {
      mark(stage, 'LATE_OPERATION_ERROR', details: '$error\n$stackTrace');
    }

    try {
      await cleanup();
      mark(stage, 'LATE_CLEANUP_PASS');
    } catch (error, stackTrace) {
      mark(stage, 'LATE_CLEANUP_FAIL', details: '$error\n$stackTrace');
    }
  }

  String _format(
    String stage,
    String event,
    Stopwatch elapsed, [
    String? details,
  ]) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final suffix = details == null ? '' : ' details=$details';
    return '[$timestamp][smoke][total=${_total.elapsedMilliseconds}ms]'
        '[stage=${elapsed.elapsedMilliseconds}ms] $event $stage$suffix';
  }
}

class SmokeCleanupStack {
  SmokeCleanupStack(this._runner);

  final SmokeStageRunner _runner;
  final List<({String name, FutureOr<void> Function() release})> _entries = [];
  bool _disposed = false;

  void add(String name, FutureOr<void> Function() release) {
    if (_disposed) throw StateError('Cannot register cleanup after disposal.');
    _entries.add((name: name, release: release));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final failures = <String>[];
    for (final entry in _entries.reversed) {
      try {
        await _runner.run<void>(
          'cleanup/${entry.name}',
          timeout: smokeStageTimeouts['cleanup']!,
          operation: entry.release,
        );
      } catch (error) {
        failures.add('${entry.name}: $error');
      }
    }
    if (failures.isNotEmpty) {
      throw SmokeCleanupException(failures);
    }
  }
}

class SmokeCleanupException implements Exception {
  const SmokeCleanupException(this.failures);

  final List<String> failures;

  @override
  String toString() => 'Smoke cleanup failed: ${failures.join('; ')}';
}

/// Always releases registered resources, while retaining the primary failure.
Future<T> runWithSmokeCleanup<T>({
  required SmokeStageRunner runner,
  required SmokeCleanupStack cleanup,
  required Future<T> Function() operation,
}) async {
  T? result;
  Object? operationError;
  StackTrace? operationStack;
  try {
    result = await operation();
  } catch (error, stackTrace) {
    operationError = error;
    operationStack = stackTrace;
  }

  Object? cleanupError;
  StackTrace? cleanupStack;
  try {
    await runner.run<void>(
      'test cleanup',
      timeout: smokeStageTimeouts['cleanup']!,
      operation: cleanup.dispose,
    );
  } catch (error, stackTrace) {
    cleanupError = error;
    cleanupStack = stackTrace;
  }

  if (operationError != null) {
    if (cleanupError != null) {
      runner.mark(
        'cleanup',
        'SECONDARY_FAILURE',
        details: '$cleanupError\n$cleanupStack',
      );
    }
    Error.throwWithStackTrace(operationError, operationStack!);
  }
  if (cleanupError != null) {
    Error.throwWithStackTrace(cleanupError, cleanupStack!);
  }
  return result as T;
}
